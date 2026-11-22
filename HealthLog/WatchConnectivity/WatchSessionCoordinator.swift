import CryptoKit
import Foundation
import WatchConnectivity

// MARK: - Phone-side WatchConnectivity coordinator

///
/// **watchOS companion.** Owns the iPhone end of the WC session.
/// Pushes the latest `WatchSnapshot` to the watch (latest-wins application
/// context) and receives `WatchAction`s the watch sends (durable
/// `transferUserInfo`, or a live `sendMessage` when foregrounded), funnelling
/// each onto the live `AppContainer` stores via injected closures. The stores
/// own the server-first / Outbox / idempotency path — this coordinator adds
/// no parallel write path and holds no token.
///
/// WC delegate callbacks arrive on a background queue, so the protocol
/// methods are `nonisolated` and hop to the `@MainActor` body via `Task`.
@MainActor
@Observable
final class WatchSessionCoordinator: NSObject {
    /// Perform a medication intake transition. Wired by `AppContainer` to
    /// `MedicationsStore.markIntakeQuick` (handles real + synth ids). Returns
    /// the honest outcome so the coordinator can ack the watch (WW/F2).
    /// #9 — `at` is when the wrist was tapped; a durable transfer can arrive
    /// hours later.
    var onMarkIntake: ((_ intakeId: String, _ status: WatchIntakeStatus, _ at: Date) async -> WatchAckOutcome)?

    /// Quick-log a mood. Wired by `AppContainer` to `MoodStore.logReturningOutcome`.
    /// Returns the honest outcome so the coordinator can ack the watch (WW/F2).
    var onLogMood: ((_ score: Int, _ at: Date) async -> WatchAckOutcome)?

    /// Quick-capture a manual measurement. Wired by `AppContainer` to
    /// `MeasurementsStore.captureReturningOutcome` (the SAME path the app's
    /// `MeasureSheet` uses). Returns the honest outcome so the coordinator can
    /// ack the watch.
    var onLogMeasurement: ((
        _ kind: WatchMeasurementKind,
        _ value: Double,
        _ secondary: Double?,
        _ at: Date
    ) async -> WatchAckOutcome)?

    /// #9 — the ``WatchOwnerHash`` of the signed-in account, `nil` while
    /// signed out. Stamped into every snapshot and checked on every action.
    var ownerHashProvider: (() -> String?)?

    /// Build the current snapshot on demand (activation / reachability /
    /// watch-state changes re-derive + push without waiting for a store
    /// mutation). `nil` from the closure means "nothing trustworthy to send
    /// yet" (see ``WatchSnapshotPushGate``): the watch keeps what it has.
    var snapshotProvider: (() -> WatchSnapshot?)?

    /// Supply the latest server health score
    /// + the newest measurement (formatted via the live unit prefs) to enrich
    /// the snapshot the watch-face score-ring + latest-measurement complications
    /// read. Wired by `AppContainer` AFTER the score / measurement / settings
    /// stores exist (the watch wiring runs earlier in init), and read lazily on
    /// every push so a later store load is honoured. `nil` ⇒ the corresponding
    /// glance is absent (complication shows its em-dash placeholder).
    var scoreProvider: (() -> WatchSnapshot.HealthScoreGlance?)?
    var latestMeasurementProvider: (() -> WatchSnapshot.LatestMeasurement?)?
    /// The account's glucose unit, which the wrist enters glucose in.
    /// `nil` ⇒ mg/dL (wired after the settings store exists).
    var glucoseUnitProvider: (() -> GlucoseUnit)?

    private let session: WCSession?
    /// Route through the central `HLLog` (LogSanitizer-backed)
    /// instead of a raw `os.Logger`. The WC channel carries med-snapshot PHI,
    /// so a future debug log here would otherwise leak verbatim; `HLLog.watch`
    /// funnels every line through `LogSanitizer.redact()` like the rest of the app.
    private let log = HLLog.watch

    /// WW/F7 — coalesce a burst of snapshot re-pushes (e.g. "mark all taken"
    /// fans N store-change fires) into a single `updateApplicationContext` on
    /// the next runloop tick. `updateApplicationContext` is latest-wins, so
    /// collapsing the burst keeps the wire + battery cost to one push while
    /// still delivering the freshest state. Set while a coalesced push is
    /// pending; cleared when it fires.
    private var pushCoalesced = false
    /// Remembers the outcome per watch action id.
    private let replayGuard = WatchActionReplayGuard()

    /// The last snapshot the coordinator *attempted* to push, recorded before
    /// the session-activation guard so it reflects the intent even when the WC
    /// session is not yet activated (the case in unit tests + on a device with
    /// no paired watch). Used by `WatchLogoutResetTests` to pin that the logout
    /// cascade pushes the PHI-free placeholder. Not a functional dependency of
    /// the push itself.
    private(set) var lastPushedSnapshot: WatchSnapshot?

    /// Whether the medication store has delivered a today list since sign-in.
    /// The list arrives after the medications, and a snapshot built in that
    /// gap shows zero doses (``WatchSnapshotPushGate``).
    var hasSeenTodayIntakes = false

    override init() {
        session = WCSession.isSupported() ? .default : nil
        super.init()
    }

    /// Set the delegate + activate. Call once, after the closures are wired,
    /// so a queued inbound action can't race ahead of a nil handler.
    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    /// Push the latest snapshot to the watch. No-op until the session is
    /// activated. A failed push is logged + swallowed — it must never break
    /// the app (the next change re-pushes).
    func push(_ snapshot: WatchSnapshot) {
        lastPushedSnapshot = snapshot
        guard let session, session.activationState == .activated else { return }
        do {
            try session.updateApplicationContext(WatchTransport.encode(snapshot: snapshot))
        } catch {
            log.error("watch context push failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// **Privacy H4 — clear the watch on phone logout / account
    /// deletion.** Push the PHI-free ``WatchSnapshot/placeholder`` so the
    /// previous user's medication names, doses, mood and latest measurement stop
    /// rendering in the watch app and its complications after a phone-side sign-
    /// out. Called from `performFullLocalLogout` on EVERY logout reason.
    ///
    /// `updateApplicationContext` is latest-wins and is delivered to the
    /// counterpart even while the watch app is not running (applied at its next
    /// launch/wake), so the cleared snapshot reliably reaches the watch. The
    /// watch mirrors it into its App Group file and treats a cleared snapshot as
    /// "wipe the local file" (`WatchConnectivityClient.apply`), then reloads its
    /// complication timelines to the empty glance. Best-effort — the underlying
    /// `push` swallows WC failures so the logout cascade always proceeds.
    func pushLogoutReset() {
        hasSeenTodayIntakes = false
        push(.placeholder)
    }

    /// Re-derive the current snapshot and push it **immediately** (used by
    /// activation / reachability / watch-state callbacks where there's no burst
    /// to coalesce and we want the freshest paint at once).
    func pushCurrent() {
        guard let provider = snapshotProvider, let snapshot = provider() else { return }
        push(snapshot)
    }

    /// WW/F7 — coalesced re-push for the high-frequency store-change path
    /// (`onIntakesDidChange` / `onEntriesDidChange`). A burst within one
    /// runloop tick collapses to a single push.
    func pushCurrentCoalesced() {
        guard !pushCoalesced else { return }
        pushCoalesced = true
        Task { @MainActor [weak self] in
            self?.pushCoalesced = false
            self?.pushCurrent()
        }
    }

    private func handle(_ action: WatchAction) async {
        // At-least-once transport: a redelivered action is
        // answered with the outcome it already got, never handled twice.
        if let prior = replayGuard.priorOutcome(for: action.id) {
            log.info("watch action redelivered — answered from memory")
            sendAck(WatchAck(id: action.id, outcome: prior))
            return
        }
        let outcome = await outcome(of: action)
        // WW/F2 — ack the watch so it shows honest state (saved / will-sync /
        // couldn't-save) instead of a blind optimistic check. Durable so it
        // survives an unreachable watch.
        replayGuard.remember(action.id, outcome: outcome)
        sendAck(WatchAck(id: action.id, outcome: outcome))
    }

    /// What the phone did with `action`. #9 — an action tapped on another
    /// account's snapshot is not written into this one; the wrist shows
    /// "couldn't save". The tap time is what the entry records.
    func outcome(of action: WatchAction) async -> WatchAckOutcome {
        if let tappedFor = action.ownerHash, tappedFor != ownerHashProvider?() {
            log.warning("watch action for another account — dropped")
            return .failed
        }
        let at = min(action.tappedAt, Date())
        return switch action.kind {
        case let .markIntake(intakeId, status, _):
            await onMarkIntake?(intakeId, status, at) ?? .failed
        case let .logMood(score, _):
            await onLogMood?(score, at) ?? .failed
        case let .logMeasurement(kind, value, secondary, _):
            await onLogMeasurement?(kind, value, secondary, at) ?? .failed
        }
    }

    /// Send a phone→watch acknowledgement. Durable `transferUserInfo`; failure
    /// is logged + swallowed (the watch falls back to the snapshot truth).
    private func sendAck(_ ack: WatchAck) {
        guard let session, session.activationState == .activated else {
            log.warning("watch ack dropped — session not activated")
            return
        }
        session.transferUserInfo(WatchTransport.encode(ack: ack))
    }
}

extension WatchSessionCoordinator: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in self.pushCurrent() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate so the session keeps serving the (possibly re-paired)
        // watch — Apple's documented requirement on iOS.
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let action = WatchTransport.decodeAction(userInfo) else { return }
        Task { @MainActor in await self.handle(action) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let action = WatchTransport.decodeAction(message) else { return }
        Task { @MainActor in await self.handle(action) }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.pushCurrent() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.pushCurrent() }
    }
}

// MARK: - Push gate

/// Whether the phone may push a snapshot built from the medication store now.
///
/// A process woken in the background (HealthKit delivery, silent push, a watch
/// action) has not loaded the store yet. A snapshot built from it carries zero
/// doses, a fresh `generatedAt` and `signedIn: true`, which the watch reads as
/// "all done today". Signed out there is nothing to protect: the placeholder is
/// the truth.
enum WatchSnapshotPushGate {
    static func allowsPush(signedIn: Bool, hasLoadedMedications: Bool, hasLoadedTodayList: Bool) -> Bool {
        !signedIn || (hasLoadedMedications && hasLoadedTodayList)
    }
}

// MARK: - Owner hash

/// **#9 — which account a watch action was tapped for.** An opaque hash of
/// the user id, so the watch never holds the id itself. Stable per account,
/// different across accounts, and meaningless off the phone.
enum WatchOwnerHash {
    static func of(userID: String?) -> String? {
        guard let id = userID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(("hl.watch.owner|" + id).utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
