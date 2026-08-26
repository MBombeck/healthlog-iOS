import Foundation

// MARK: - BGTask outbox-drain wiring (Reliability M1 — audit-v0162)

extension AppContainer {
    /// **Reliability M1 (audit-v0162)** — wire the guaranteed-sync
    /// `BGProcessingTask` so it drains the encrypted Outbox on every wakeup.
    ///
    /// Before this, the only replay triggers were: an online interface edge
    /// while the process is alive (`startOutboxReplayLoop`), an app foreground
    /// (`foregroundDrainOutboxIfReachable`), and the auth-bootstrap edge. A
    /// passive widgets/watch-only user who logged a write offline and never
    /// re-opened the app could leave it queued for days (audit RELIABILITY M1).
    ///
    /// The hook is **probe-gated** on `confirmedReachable()` — a BGTask wakeup on
    /// a captive-portal Wi-Fi or against a degraded server is a no-op, so the
    /// drain stays a probe (never a poll) and never burns Outbox replay attempts
    /// against an unreachable host. The coordinator itself awaits the hook
    /// expiration-guarded, mirroring the med/mood/LA reconcile hooks. The store +
    /// AES-GCM cipher key are readable in the BGTask window by design
    /// (`completeUntilFirstUserAuthentication`, ADR-012).
    ///
    /// **Follow-up (out of scope for M1):** the widget/Live-Activity extension
    /// enqueues offline "Genommen"/mood writes into the *extension's own sandbox*
    /// Outbox (audit RELIABILITY H2). Draining the app's Outbox here does NOT
    /// reach those rows — that needs the App-Group-container migration tracked
    /// separately.
    func wireOutboxBGDrainHook(backgroundSync: BackgroundSyncCoordinator) {
        let reach = reachability
        let replay = outboxReplay
        backgroundSync.attachOutboxDrainHook(
            Self.makeReachabilityGatedOutboxDrain(
                confirmReachable: { await reach.confirmedReachable() },
                drain: { await replay.runOnce() }
            )
        )
    }

    /// **#66 P0.1 (Baustein 1)** — give the `BGAppRefreshTask` wake a route to
    /// HealthKit, so the ~28 low-urgency types (steps, sleep, mass, heart-rate …)
    /// get pulled toward the server between the rare `BGProcessingTask` grants —
    /// the structural fix for #66 ("reaches the server only in the foreground").
    ///
    /// **Phase 07 / plan 07-07** gave the AppRefresh wake its own budget: it used
    /// to announce itself as `.background`, which resolved a ~30-second grant to
    /// the `BGProcessingTask` budget (eight pages per type, first history walk
    /// permitted) — the exact opposite of what
    /// `HealthSyncBudget.required(for: .appRefresh)` demands.
    ///
    /// **Phase 07 / plan 07-09** made this one hook the coordinator's *only*
    /// HealthKit route, for all four of its triggers rather than AppRefresh
    /// alone. The coordinator names the trigger and passes its own
    /// `BGTask.expirationHandler` flag; this closure resolves the plan. Nothing
    /// else in the coordinator reaches an importer, which is what ended the
    /// interim double-run (`.appRefresh` used to arrive here *and* the wake
    /// separately ran the workout pass and the outbox drain).
    func wireBGRefreshCollectionHook(backgroundSync: BackgroundSyncCoordinator) {
        backgroundSync.attachHealthSyncRoute { [weak self] trigger, isExpired in
            await self?.runHealthSyncPass(trigger, isExpired: isExpired) ?? []
        }
    }

    /// Pure, unit-testable factory for the probe-gated drain closure: the drain
    /// runs iff the reachability probe confirms the server actually answers.
    /// Split out from ``wireOutboxBGDrainHook(backgroundSync:)`` so the gating
    /// can be pinned without a live `Reachability`/`OutboxReplayService`.
    static func makeReachabilityGatedOutboxDrain(
        confirmReachable: @escaping @Sendable () async -> Bool,
        drain: @escaping @Sendable () async -> Void
    ) -> @Sendable () async -> Void {
        {
            guard await confirmReachable() else { return }
            await drain()
        }
    }
}
