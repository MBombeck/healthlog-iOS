import Foundation
import Observation
import WatchConnectivity
import WidgetKit

/// **v0.12 P2 — watch-side WatchConnectivity client.**
///
/// Receives the phone's `WatchSnapshot` (latest-wins application context) and
/// sends `WatchAction`s back via the durable `transferUserInfo` queue (survives
/// an unreachable phone + reboots, wakes the phone in the background). Holds a
/// tiny optimistic + acknowledgement layer (WW/F2,F3,F6) so a just-tapped dose
/// / mood reads as **pending**, then resolves to an HONEST state — saved /
/// "saved, will sync" / "couldn't reach iPhone" — driven by the phone's
/// per-action ack, never a blind green check the instant the user taps.
@MainActor
@Observable
final class WatchConnectivityClient: NSObject {
    /// The latest glance the phone pushed. `placeholder` until the first
    /// context arrives.
    private(set) var snapshot: WatchSnapshot = .placeholder

    /// `false` until the first snapshot lands — drives the "syncing…" state
    /// vs. a real empty list.
    private(set) var hasReceived = false

    /// Intake ids the user just acted on locally — dimmed/checked optimistically
    /// until the phone's next snapshot reflects the change OR a failed ack
    /// reverts them.
    private(set) var pendingIntakeIDs: Set<String> = []

    /// A mood the user *just* tapped (1…5). This is a **transient** highlight —
    /// the wrist flashes a checkmark on the tapped level, then returns to the
    /// picker so the next check-in is one tap away. Multi-log: the picker is
    /// always primary; this never locks the day. Cleared by a short timer or by
    /// the next tap.
    private(set) var moodJustLogged: Int?

    /// Optimistic wrist-tap timestamps the latest snapshot does NOT yet
    /// reflect, keyed by the originating action id. Each tap records the moment
    /// the user tapped; the displayed "N today" is the snapshot count PLUS the
    /// taps newer than the snapshot (a DELTA on top of the authoritative count,
    /// never a `max`). Keyed by id so a `failed` ack can drop its own tap. A
    /// fresh snapshot prunes the taps it now reflects (see `apply(_:)`) — which
    /// also resets the count honestly at local midnight.
    private var pendingMoodTaps: [String: Date] = [:]

    /// Today's mood count to show on the wrist ("N today"): the phone's
    /// authoritative `snapshot.moodCountToday` plus the wrist taps it doesn't
    /// yet reflect, so a fresh tap on a day that already had entries shows
    /// immediately (snapshot 2 + 1 tap → 3) and an offline burst reconciles —
    /// without undercounting and without a stale count after midnight.
    var moodCountToday: Int {
        WatchMoodCount.displayedCount(
            snapshotCount: snapshot.moodCountToday,
            pendingTaps: Array(pendingMoodTaps.values),
            snapshotGeneratedAt: snapshot.generatedAt
        )
    }

    /// Drives the transient per-tap flash timer; a new tap supersedes the old.
    private var moodFlashTask: Task<Void, Never>?

    // MARK: - WW/F2,F6 — honest per-action acknowledgement state

    /// The lifecycle of a single watch-originated write, as the watch sees it.
    enum ActionState: Equatable {
        /// Sent, no ack yet — show a calm "Sending…" / spinner.
        case pending
        /// The phone confirmed the write landed on the server (or local mirror).
        case saved
        /// The phone durably queued the write (offline / token-expiry) — show
        /// "Saved — will sync to iPhone."
        case queued
        /// The phone couldn't accept the write at all — show "Couldn't reach
        /// iPhone — tap to retry."
        case failed
    }

    /// Per-action-id state for in-flight / recently-resolved mood actions,
    /// keyed by the action's id so rapid successive logs each get their OWN
    /// pending→ack lifecycle (a 2nd tap before the 1st acks no longer overwrites
    /// the 1st's honest state). Multi-log relies on this.
    private(set) var moodActions: [String: TrackedAction] = [:]

    /// The most-recent mood action's id, so the view can surface a single quiet
    /// "last:" footer (will-sync / not-saved) without scanning the whole map.
    private(set) var lastMoodActionID: String?

    /// Per-intake-id action state, keyed by the dose's `intakeId` so the
    /// medications list can show a spinner / retry per row.
    private(set) var intakeActions: [String: ActionState] = [:]

    /// Per-action-id state for in-flight / recently-resolved measurement
    /// quick-captures, so the wrist shows an honest sending → saved /
    /// will-sync / not-saved state instead of a blind check.
    private(set) var measurementActions: [String: ActionState] = [:]

    /// The most-recent measurement action's id, so the capture view can surface
    /// a single quiet status footer without scanning the whole map.
    private(set) var lastMeasurementActionID: String?

    /// The honest state of the MOST-RECENT measurement action, or `nil` if none.
    var lastMeasurementActionState: ActionState? {
        guard let id = lastMeasurementActionID else { return nil }
        return measurementActions[id]
    }

    /// The payload of the last measurement action (for a one-tap retry).
    struct PendingMeasurement: Equatable {
        let kind: WatchMeasurementKind
        let value: Double
        let secondary: Double?
    }

    private var lastMeasurement: PendingMeasurement?

    /// A watch-originated action plus the score/dose it carried, so a `failed`
    /// ack can offer a one-tap retry without re-deriving context.
    struct TrackedAction: Equatable {
        let id: String
        var state: ActionState
        let moodScore: Int?
    }

    private let session: WCSession?

    /// WW/F5 — actions enqueued before the session reached `.activated`.
    /// Flushed in `activationDidCompleteWith` so a very-fast first tap isn't
    /// sent against a not-yet-activated session (Apple's pre-activation
    /// `transferUserInfo` contract is unreliable).
    private var pendingSendBuffer: [WatchAction] = []

    override init() {
        session = WCSession.isSupported() ? .default : nil
        super.init()
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    /// `true` once the phone can accept writes (signed-in OR standalone — see
    /// `WatchSnapshot.signedIn`/`canLog`). The watch can't sign in itself.
    var signedIn: Bool {
        snapshot.signedIn
    }

    /// The score the user just tapped (transient flash), or `nil` once the
    /// flash has cleared. Used by the picker to flash a checkmark on that row.
    var justLoggedScore: Int? {
        moodJustLogged
    }

    /// The honest state of the MOST-RECENT mood action, or `nil` if none. Drives
    /// the quiet non-blocking footer ("Last: will sync" / "Last: not saved").
    var lastMoodActionState: ActionState? {
        guard let id = lastMoodActionID else { return nil }
        return moodActions[id]?.state
    }

    func markIntake(_ dose: WatchSnapshot.Dose, status: WatchIntakeStatus) {
        pendingIntakeIDs.insert(dose.id)
        let action = WatchAction(kind: .markIntake(intakeId: dose.id, status: status, at: Date()))
        intakeActions[dose.id] = .pending
        pendingIntakeForAck[action.id] = dose.id
        send(action)
    }

    /// Log a mood from the wrist. Multi-log: every tap mints a NEW durable
    /// action with its own id, increments the optimistic "N today" count, and
    /// flashes a transient checkmark on the tapped level — then returns to the
    /// picker. No day-level lock.
    func logMood(score: Int) {
        let tappedAt = Date()
        let action = WatchAction(kind: .logMood(score: score, at: tappedAt))
        moodActions[action.id] = TrackedAction(id: action.id, state: .pending, moodScore: score)
        lastMoodActionID = action.id
        // Record the tap as a pending DELTA on top of the snapshot count; the
        // displayed "N today" adds the taps the latest snapshot doesn't reflect.
        pendingMoodTaps[action.id] = tappedAt
        flashJustLogged(score)
        send(action)
    }

    /// Transient per-tap highlight: show the tapped score for ~1.5 s then clear,
    /// returning the picker to its resting state. A new tap supersedes the timer.
    private func flashJustLogged(_ score: Int) {
        moodJustLogged = score
        moodFlashTask?.cancel()
        moodFlashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.moodJustLogged = nil
        }
    }

    /// Retry the last failed mood log (WW/F6 retry affordance) — re-mints a
    /// fresh action (new id) for the same score.
    func retryMood() {
        guard let id = lastMoodActionID,
              let last = moodActions[id], last.state == .failed,
              let score = last.moodScore else { return }
        // The failed attempt didn't land, so don't double-count: the new
        // `logMood` mints a fresh pending tap, so drop the failed one's tap +
        // action first.
        pendingMoodTaps.removeValue(forKey: id)
        moodActions[id] = nil
        logMood(score: score)
    }

    /// Quick-capture a manual measurement from the wrist. Mints a durable
    /// action with its own id, tracked pending→ack so the capture view shows an
    /// honest state. `secondary` is the BP diastolic (nil for scalar kinds).
    func logMeasurement(kind: WatchMeasurementKind, value: Double, secondary: Double? = nil) {
        let action = WatchAction(kind: .logMeasurement(kind: kind, value: value, secondary: secondary, at: Date()))
        measurementActions[action.id] = .pending
        lastMeasurementActionID = action.id
        lastMeasurement = PendingMeasurement(kind: kind, value: value, secondary: secondary)
        pendingMeasurementForAck.insert(action.id)
        send(action)
    }

    /// Retry the last failed measurement quick-capture — re-mints a fresh
    /// action (new id) for the same kind + value.
    func retryMeasurement() {
        guard let id = lastMeasurementActionID,
              measurementActions[id] == .failed,
              let last = lastMeasurement else { return }
        measurementActions[id] = nil
        logMeasurement(kind: last.kind, value: last.value, secondary: last.secondary)
    }

    // MARK: - Send

    private func send(_ action: WatchAction) {
        guard let session else { return }
        // WW/F5 — buffer until the session is activated, then flush in order.
        guard session.activationState == .activated else {
            pendingSendBuffer.append(action)
            return
        }
        transmit(action)
    }

    private func transmit(_ action: WatchAction) {
        guard let session else { return }
        // **Exactly-once durable delivery.** `transferUserInfo` queues the
        // action and delivers it once, in FIFO order, surviving an unreachable
        // phone + reboots, waking the phone app in the background to process it.
        //
        // We deliberately do NOT use a live `sendMessage` "fast path" with a
        // `transferUserInfo` fallback: `sendMessage`'s error handler can fire
        // even when the message WAS delivered (lost ack), so the fallback would
        // double-deliver — and the phone mints a fresh idempotency key per
        // delivery, which for a medication mark is a double-dose hazard. A
        // single durable transfer removes that window at the source. A med
        // intake / mood log doesn't need sub-second latency; reliability wins.
        session.transferUserInfo(WatchTransport.encode(action: action))
    }

    /// Flush any actions buffered before activation (WW/F5).
    private func flushPendingSends() {
        guard !pendingSendBuffer.isEmpty else { return }
        let buffered = pendingSendBuffer
        pendingSendBuffer.removeAll()
        for action in buffered {
            transmit(action)
        }
    }

    // MARK: - Apply

    private func apply(_ snapshot: WatchSnapshot) {
        self.snapshot = snapshot
        hasReceived = true
        // WW/F3 + multi-log reconcile — the phone's `moodCountToday` is the
        // authoritative count, and "N today" is rendered as snapshot + the
        // wrist taps the snapshot doesn't yet reflect. Prune the pending taps
        // this fresh snapshot now reflects (those generated at-or-before the
        // snapshot's `generatedAt`): a snapshot that already includes a tap
        // drops it from the delta (no double-count of an offline burst), and a
        // post-midnight snapshot (newer `generatedAt`, count 0) drops the
        // previous evening's taps so "N today" honestly follows the reset.
        pendingMoodTaps = pendingMoodTaps.filter { $0.value > snapshot.generatedAt }
        // Clear optimistic intake ids the snapshot now shows as taken (the
        // phone's truth caught up). Pending-but-not-yet-reflected ids survive.
        let takenIDs = Set(snapshot.doses.filter(\.isTaken).map(\.id))
        for id in pendingIntakeIDs.intersection(takenIDs) {
            pendingIntakeIDs.remove(id)
            // Snapshot reflects the dose as taken — clear the optimistic action
            // unless it explicitly failed. Keeping `.queued` here stranded the
            // wrist on "will sync" even after the value synced (WC2 Medium).
            if intakeActions[id] != .failed {
                intakeActions[id] = nil
            }
        }
        // Persist for the complication + refresh its timeline so the watch
        // face reflects the new next-dose / compliance immediately.
        //
        // Privacy H4 (audit-v0162) — a cleared (logout) snapshot carries no PHI;
        // treat it as "wipe the local file" so the previous user's medication
        // names / doses / mood / measurement do not persist at rest on the wrist.
        // Either way the complication timelines reload to reflect the empty state.
        let store = WatchSnapshotStore()
        if snapshot.isCleared {
            store.clear()
        } else {
            store.write(snapshot)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// WW/F2 — apply a phone ack to the matching action's state.
    private func apply(_ ack: WatchAck) {
        let state: ActionState = switch ack.outcome {
        case .saved: .saved
        case .queued: .queued
        case .failed: .failed
        }

        if moodActions[ack.id] != nil {
            moodActions[ack.id]?.state = state
            if state == .failed {
                // The write didn't land — drop this tap from the pending delta
                // so the "N today" subhead doesn't over-report; the failed
                // footer offers retry. The transient flash clears on its timer.
                pendingMoodTaps.removeValue(forKey: ack.id)
            }
        }

        // An intake ack is keyed by action id, not intake id; we tracked the
        // intake by its dose id, so resolve via the doses we hold pending.
        // The phone echoes the action id, but the watch keyed `intakeActions`
        // by dose id — so resolve a failed intake by reverting its optimistic
        // pending mark. (Saved/queued keep the optimistic check; the snapshot
        // confirms saved, the queued state persists until sync.)
        if let intakeID = pendingIntakeForAck[ack.id] {
            intakeActions[intakeID] = state
            if state == .failed {
                pendingIntakeIDs.remove(intakeID)
            }
            // The ack resolved this action — drop its id→dose mapping so the
            // map doesn't grow unbounded across a long watch session.
            pendingIntakeForAck.removeValue(forKey: ack.id)
        }

        // A measurement ack is keyed directly by action id (no secondary id
        // mapping needed — the capture view tracks the last action).
        if pendingMeasurementForAck.contains(ack.id) {
            measurementActions[ack.id] = state
            pendingMeasurementForAck.remove(ack.id)
        }
    }

    /// Map action id → dose id for intake acks (mirrors the send site).
    private var pendingIntakeForAck: [String: String] = [:]

    /// Action ids for in-flight measurement quick-captures (mirrors the send
    /// site) — used to route an ack onto `measurementActions`.
    private var pendingMeasurementForAck: Set<String> = []
}

extension WatchConnectivityClient: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        // Pick up the last context the phone pushed while the watch app was
        // not running, so the first paint isn't the placeholder. Decode in the
        // nonisolated callback (the dict isn't Sendable) and hop the Sendable
        // `WatchSnapshot` value across.
        let decoded = WatchTransport.decodeSnapshot(session.receivedApplicationContext)
        let activated = activationState == .activated
        Task { @MainActor in
            if let decoded { self.apply(decoded) }
            // WW/F5 — drain any taps the user made before activation completed.
            if activated { self.flushPendingSends() }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let snapshot = WatchTransport.decodeSnapshot(applicationContext) else { return }
        Task { @MainActor in self.apply(snapshot) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        // WW/F2 — the phone's per-action acknowledgement arrives here (durable).
        guard let ack = WatchTransport.decodeAck(userInfo) else { return }
        Task { @MainActor in self.apply(ack) }
    }
}
