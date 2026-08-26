import Foundation
import Observation

/// W-SYNCVIS — the visible sync lifecycle phase driving the footer caption.
///
/// The pre-b178 footer was invisible on fast networks: the syncing line only
/// rendered while `isLoading` was `true` (often < 300 ms for the GET) and the
/// "Daten übermittelt ✓" beat only armed on a real `>0 → 0` outbox drain — a
/// read-only pull-to-refresh therefore never showed anything. The phase
/// machine makes every handshake perceivable:
///
/// `.idle → .syncing (held ≥ minimumSyncingHold) → .done (held doneHold) → .idle`
///
/// Errors short-circuit `.syncing → .idle` directly — no fake confirmation.
public enum SyncPhase: Equatable, Sendable {
    /// Quiet resting state — the footer shows "Zuletzt synchronisiert HH:MM".
    case idle
    /// A handshake is in flight — "Synchronisiere…", held for a minimum beat
    /// even when the GET returns instantly.
    case syncing
    /// The handshake landed — short "Daten übermittelt ✓" beat, ALSO for
    /// read-only syncs (the pull really did talk to the server).
    case done
}

/// `@Observable` wrapper over `SyncStateRepository`. Holds the most
/// recent `GET /api/sync/state` snapshot so the Settings screen +
/// the sync-mode coordinator can read the server's view of the
/// per-user state without re-issuing the network read.
///
/// **Sync handshake contract (server v1.4.30):**
///   - Every successful call bumps `User.lastSyncedAt` server-side.
///   - The returned `lastSyncedAt` is the value BEFORE the bump — the
///     caller learns the previous checkpoint cleanly.
///   - `serverNow` lets the iOS client detect clock skew (warn the
///     user when the device clock drifted more than ~5 min).
///
/// **State semantics:** the store keeps the entire DTO. UI surfaces
/// (Settings → Daten → Server-Status, Onboarding → Pair-fresh-server)
/// read selectively into the slot they care about.
@MainActor
@Observable
public final class SyncStateStore {
    public private(set) var state: ServerSyncStateDTO?
    public private(set) var isLoading: Bool = false
    public private(set) var error: HLError?
    public private(set) var lastHandshakeAt: Date?

    // MARK: - b178 W-SYNCVIS — perceivable handshake phases

    /// The current sync lifecycle phase (see ``SyncPhase``). Every
    /// `handshake()` walks `.syncing → .done → .idle` with minimum hold
    /// times so the footer caption is actually visible to the user.
    public private(set) var phase: SyncPhase = .idle

    // MARK: - b177 W-SYNCPROGRESS — honest sync-progress quantities

    /// Queued outbox writes waiting for replay (offline edits, retriable
    /// uploads). Fed live by `bindOutbox` — every enqueue/dequeue broadcast
    /// updates the count, so the footer's "N ausstehend" counts down as the
    /// replay drains. ZERO invention: this IS the persisted backlog (§4.5).
    public private(set) var pendingOutboxCount: Int = 0

    /// Distinct SWR keys currently mid-revalidation (the pull-to-refresh
    /// fan-out). Fed live by `bindRevalidations`. Together with the outbox
    /// backlog this is the quantity behind "Wird synchronisiert… N ausstehend".
    public private(set) var activeRevalidationCount: Int = 0

    /// The aggregate the in-flight caption shows. Both addends are real,
    /// countable units of outstanding work — no percentages, no estimates.
    public var pendingSyncCount: Int {
        pendingOutboxCount + activeRevalidationCount
    }

    /// `true` for a short beat after the outbox backlog drained to zero —
    /// drives the "Daten übermittelt ✓" confirmation in the footer. Only an
    /// actual `>0 → 0` outbox transition arms it (uploads really landed);
    /// read-only revalidations never claim "übermittelt".
    public private(set) var showsDrainConfirmation: Bool = false

    // MARK: - audit-v0162 H1 (Opt 2) — honest dead-letter (DLQ) failure state

    /// Cumulative count of writes that were dead-lettered (retry budget
    /// exhausted AND aged past the window) since the last clear. These rows
    /// dropped out of the pending backlog WITHOUT being delivered, so the
    /// footer must NEVER read the drained-success beat for that drop.
    public private(set) var failedDropCount: Int = 0

    /// `true` while there are un-acknowledged dead-lettered writes — drives the
    /// honest "N Einträge konnten nicht übermittelt werden" footer state and
    /// HARD-suppresses the drain-confirmation success beat (a DLQ drop is not a
    /// drain). Sticky until a real drain, a re-submit, or logout clears it.
    public private(set) var showsFailedDrop: Bool = false

    /// Localized, count-aware footer caption for the dead-letter failure state
    /// (informal "du"). `nil` when there is nothing to surface. The footer
    /// primitive renders this verbatim.
    public var failedDropCaption: String? {
        guard showsFailedDrop, failedDropCount > 0 else { return nil }
        return String(
            format: String(localized: "sync.footer.failed_drop"),
            failedDropCount
        )
    }

    // MARK: - Phase 07 / plan 07-07 — named HealthKit sync truth

    /// The most recent orchestrated HealthKit pass, as a privacy-safe snapshot.
    ///
    /// Deliberately fed into the store the app already has rather than a new
    /// banner: there is one place that answers "what is the state of syncing",
    /// and a second one would be a second thing to keep true. The snapshot type
    /// cannot carry a health value, an owner id, or a server URL — see
    /// ``HealthSyncPassSnapshot``.
    public private(set) var lastHealthSyncPass: HealthSyncPassSnapshot?

    /// Cumulative count of capability results that refused because no account
    /// could be admitted, since launch.
    ///
    /// Its own counter because it is the one refusal that means the *app* is
    /// mis-composed rather than that the world is: it says every admission-gated
    /// importer declined while every toggle read "on". A non-zero value here on
    /// a signed-in device is a defect, not a condition.
    public private(set) var healthSyncAdmissionRefusalCount: Int = 0

    /// Items the last pass named as still owed (held pages, pending doses,
    /// queued rows). Zero is the only value that means "nothing outstanding".
    public var healthSyncHeldItemCount: Int {
        lastHealthSyncPass?.heldItemCount ?? 0
    }

    /// `true` only when the last pass reached every planned capability and none
    /// of them owes work. A durable retry row is progress, not completion.
    public var healthSyncLastPassWasComplete: Bool {
        lastHealthSyncPass?.isComplete ?? false
    }

    /// What the product may say about background scheduling. Sourced from the
    /// Phase-07 contract so a surface cannot invent a cadence.
    public var healthSyncSchedulingClaim: String {
        HealthSyncSchedulingTruth.claim
    }

    /// Records one finished orchestrated pass.
    ///
    /// Never touches ``phase`` or ``showsDrainConfirmation``: a HealthKit pass is
    /// not the server handshake those model, and a background wake that pulled
    /// nothing must not flash "Daten übermittelt ✓".
    public func noteHealthSyncPass(_ snapshot: HealthSyncPassSnapshot) {
        lastHealthSyncPass = snapshot
        healthSyncAdmissionRefusalCount += snapshot.capabilitiesRefusedForMissingAdmission.count
    }

    /// How long the drain confirmation stays up. Injectable for tests.
    private let drainConfirmationHold: Duration

    /// Clock behind the phase holds — injectable so the phase machine is
    /// deterministic under test (stub clock, no wall-time sleeps).
    private let clock: any Clock<Duration>
    /// Minimum time `.syncing` stays visible, even when the GET is instant.
    private let minimumSyncingHold: Duration
    /// How long the `.done` ("Daten übermittelt ✓") beat stays visible.
    private let doneHold: Duration

    @ObservationIgnored private var outboxObservationTask: Task<Void, Never>?
    @ObservationIgnored private var revalidationObservationTask: Task<Void, Never>?
    @ObservationIgnored private var drainConfirmationTask: Task<Void, Never>?
    @ObservationIgnored private var phaseDecayTask: Task<Void, Never>?
    /// Generation counter guarding overlapping handshakes: a stale GET or a
    /// stale `.done`-decay must never clobber the phase of a newer handshake.
    @ObservationIgnored private var handshakeGeneration: UInt64 = 0

    private let repo: SyncStateRepository

    public init(
        repo: SyncStateRepository,
        drainConfirmationHold: Duration = .seconds(2.5),
        clock: any Clock<Duration> = ContinuousClock(),
        minimumSyncingHold: Duration = .milliseconds(600),
        doneHold: Duration = .seconds(1.5)
    ) {
        self.repo = repo
        self.drainConfirmationHold = drainConfirmationHold
        self.clock = clock
        self.minimumSyncingHold = minimumSyncingHold
        self.doneHold = doneHold
    }

    deinit {
        outboxObservationTask?.cancel()
        revalidationObservationTask?.cancel()
        drainConfirmationTask?.cancel()
        phaseDecayTask?.cancel()
    }

    /// Binds the live outbox backlog count. `OutboxQueue.changes` yields the
    /// full snapshot on registration + every enqueue/remove, so the count is
    /// authoritative from the first event on.
    public func bindOutbox(_ outbox: OutboxQueue) {
        outboxObservationTask?.cancel()
        outboxObservationTask = Task { [weak self] in
            for await ops in await outbox.changes {
                guard let self else { return }
                noteOutboxPending(ops.count)
            }
        }
    }

    /// Binds the live in-flight SWR revalidation count (pull-to-refresh
    /// fan-out visibility).
    public func bindRevalidations(_ swr: SWRCoordinator) {
        revalidationObservationTask?.cancel()
        revalidationObservationTask = Task { [weak self] in
            for await count in await swr.inflightCounts {
                guard let self else { return }
                noteActiveRevalidations(count)
            }
        }
    }

    /// Count seam for `bindRevalidations` (and tests).
    public func noteActiveRevalidations(_ count: Int) {
        activeRevalidationCount = count
    }

    /// Pure count-transition hook (also the unit-test seam). A `>0 → 0`
    /// transition arms the short "Daten übermittelt ✓" beat; any new backlog
    /// disarms it immediately.
    public func noteOutboxPending(_ count: Int) {
        let previous = pendingOutboxCount
        pendingOutboxCount = count
        if count == 0, previous > 0 {
            // audit-v0162 H1 (Opt 2) — a `>0 → 0` drop that was caused by a
            // dead-letter DROP (not a real drain) must NOT flash success. When a
            // DLQ failure is live, suppress the confirmation entirely; otherwise
            // a genuine drain also CLEARS a stale failure banner.
            if showsFailedDrop {
                drainConfirmationTask?.cancel()
                showsDrainConfirmation = false
            } else {
                armDrainConfirmation()
            }
        } else if count > 0 {
            drainConfirmationTask?.cancel()
            showsDrainConfirmation = false
        }
    }

    /// **audit-v0162 H1 (Opt 2) — surface an honest DLQ failure.** Called by the
    /// replay service (via the composition root) with the number of writes NEWLY
    /// dead-lettered in a pass. Arms the honest failed state and HARD-disarms the
    /// drain-confirmation beat so the footer can never read the drop as success,
    /// regardless of the order the outbox-count broadcast and this call arrive.
    public func noteDeadLettered(_ count: Int) {
        guard count > 0 else { return }
        failedDropCount += count
        showsFailedDrop = true
        drainConfirmationTask?.cancel()
        showsDrainConfirmation = false
    }

    /// Clear the dead-letter failure state — e.g. after the user re-submits the
    /// stuck writes from a diagnostics surface, or the writes finally drain.
    public func clearFailedDrop() {
        failedDropCount = 0
        showsFailedDrop = false
    }

    private func armDrainConfirmation() {
        showsDrainConfirmation = true
        drainConfirmationTask?.cancel()
        let hold = drainConfirmationHold
        drainConfirmationTask = Task { [weak self] in
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled else { return }
            self?.showsDrainConfirmation = false
        }
    }

    /// Live measurement counts (live + tombstoned).
    public var liveMeasurementCount: Int {
        state?.measurements.liveCount ?? 0
    }

    public var tombstonedMeasurementCount: Int {
        state?.measurements.tombstonedCount ?? 0
    }

    /// The previous checkpoint server-side (the value PRE this
    /// session's bump). `nil` when the user has never synced.
    public var previousCheckpoint: Date? {
        state?.lastSyncedAt
    }

    /// Clock-skew in seconds — positive means the device is ahead of
    /// the server. Caller decides what tolerance is "warn".
    public func clockSkewSeconds(now: Date = .now) -> TimeInterval? {
        state?.clockSkewSeconds(now: now)
    }

    /// Performs the sync handshake. Bumps `User.lastSyncedAt` server-
    /// side as a side-effect — call site decides when to invoke.
    ///
    /// b178 W-SYNCVIS phase contract: `.syncing` is held at least
    /// `minimumSyncingHold` (the minimum beat runs PARALLEL to the GET, so a
    /// slow network never pays it twice), success then shows `.done` for
    /// `doneHold` — also for read-only pulls — before decaying to `.idle`.
    /// Errors drop straight to `.idle`: no minimum hold, no fake confirmation.
    public func handshake() async {
        handshakeGeneration &+= 1
        let generation = handshakeGeneration
        phaseDecayTask?.cancel()
        isLoading = true
        error = nil
        phase = .syncing
        defer {
            // Only the newest handshake may settle the flag — a stale defer
            // must not blank the spinner of an overlapping newer run.
            if generation == handshakeGeneration { isLoading = false }
        }

        let clock = clock
        let minimumHold = minimumSyncingHold
        async let minimumBeat: Void? = try? clock.sleep(for: minimumHold)

        do {
            let snapshot = try await repo.handshake()
            await minimumBeat
            guard generation == handshakeGeneration else { return }
            state = snapshot
            lastHandshakeAt = Date()
            phase = .done
            scheduleDoneDecay(generation: generation)
        } catch let err as HLError {
            guard generation == handshakeGeneration else { return }
            error = err
            phase = .idle
        } catch {
            guard generation == handshakeGeneration else { return }
            self.error = .unknown(String(describing: error))
            phase = .idle
        }
    }

    /// Decays `.done → .idle` after `doneHold`. Generation-guarded: when a
    /// newer handshake started in the meantime, the stale decay is a no-op
    /// (on top of the cancellation `handshake()` already performs).
    private func scheduleDoneDecay(generation: UInt64) {
        phaseDecayTask?.cancel()
        let clock = clock
        let hold = doneHold
        phaseDecayTask = Task { [weak self] in
            try? await clock.sleep(for: hold)
            guard !Task.isCancelled, let self else { return }
            guard handshakeGeneration == generation else { return }
            phase = .idle
        }
    }

    public func clearOnLogout() {
        state = nil
        error = nil
        lastHandshakeAt = nil
        // b177 W-SYNCPROGRESS — a logout-driven outbox wipe must not flash
        // "Daten übermittelt ✓"; the live counts re-settle via the streams.
        drainConfirmationTask?.cancel()
        showsDrainConfirmation = false
        // audit-v0162 H1 (Opt 2) — a logout must not carry a stale DLQ failure
        // banner into the next session.
        failedDropCount = 0
        showsFailedDrop = false
        // b178 W-SYNCVIS — drop the phase machine too; the generation bump
        // neutralizes any still-in-flight handshake or pending decay.
        handshakeGeneration &+= 1
        phaseDecayTask?.cancel()
        phase = .idle
        // Phase 07 / plan 07-07 — the previous account's HealthKit pass is not
        // this session's truth, and its refusal counter is not either.
        lastHealthSyncPass = nil
        healthSyncAdmissionRefusalCount = 0
    }
}
