import Foundation

public extension AppContainer {
    /// v0.12 W8-8 — single coalesced entry point for the network-touching
    /// foreground revalidation. Routes the feature-flags refresh + APNs push
    /// re-registration through `foregroundNetworkThrottle` so rapid foreground
    /// bounces don't each fire a network request. `RootView` calls this once per
    /// `.active` transition instead of spawning two independent network Tasks.
    ///
    /// A non-forced call inside the throttle window is a no-op; a genuine
    /// re-foreground after the window runs both members concurrently. The caller
    /// supplies the `authenticated` gate (RootView owns `authStore`). Both
    /// members additionally dedup downstream (identical APNs token → no POST;
    /// SWR single-flight on flags), so the throttle is a request-suppression
    /// layer, not a correctness gate.
    @MainActor
    func foregroundNetworkRevalidate(authenticated: Bool, force: Bool = false) async {
        guard authenticated else { return }
        guard foregroundNetworkThrottle.shouldRun(force: force) else { return }
        // #30 — keep the server module map fresh on foreground. Fail-open + the
        // gate recompute drives CycleGate to re-resolve against the new map.
        async let modules: Void = refreshModuleGate()
        async let flags: Void = featureFlagsStore.refresh()
        // CCH-03 — refresh the Coach unread signal on foreground so a proactive
        // nudge minted while backgrounded lights the dot on return. Gated +
        // SWR-deduped inside the store (coach-off / offline → no call).
        async let nudge: Void = refreshCoachNudge()
        // audit-v0162 M-7 — re-probe `GET /api/version` so the derived-intake
        // synthesis gate tracks the server the app is actually pointed at (a
        // self-hoster upgrading mid-session, a fresh install whose verdict is
        // still unknown). Fail-quiet: an offline foreground keeps the persisted
        // last-known verdict rather than reverting to the unknown default.
        async let slots: Void = refreshMedicationSlotGate()
        // #30 — the proactive cadence suggestions are inline-sourced (routed from
        // a live coach turn into `coachCadenceSuggestionsStore`), so there is no
        // foreground refresh leg — the dead `GET /api/coach/reminder-suggestions`
        // (always 404) was retired.
        #if canImport(UserNotifications) && canImport(UIKit)
            async let push: Void = notifications.registerForRemoteNotificationsIfAuthorized()
            _ = await (modules, flags, nudge, slots, push)
        #else
            _ = await (modules, flags, nudge, slots)
        #endif
    }

    /// audit-v0162 M-7 — refresh the "does this server materialise today's dose
    /// slots?" verdict from the public `GET /api/version` endpoint.
    ///
    /// Fail-quiet by design: offline / unreachable / undecodable leaves the
    /// persisted last-known verdict in place. The gate's own unknown-state
    /// default (no synthesis) only applies before the very first successful
    /// probe on an installation — see ``MedicationSlotMaterializationGate``.
    @MainActor
    func refreshMedicationSlotGate() async {
        guard let info = try? await api.fetchServerVersion() else { return }
        medicationSlotGate.apply(info)
    }

    /// **AUD-8 H-1** — foreground / cold-launch SWR-cache maintenance sweep.
    ///
    /// The persistent SWR cache (`Application Support/HealthLog/Cache/cache.sqlite`)
    /// was bounded ONLY by `sweepOlderThan(30 d)` invoked from the BGProcessing
    /// task — which never fires for a user with Background-App-Refresh disabled
    /// (or a rarely-opened / low-power app), so it grew unbounded and risked the
    /// ≤100 ms cache-paint budget. This runs the age-sweep AND the hard
    /// row-count cap from a foreground entry point so the cache stays bounded
    /// independent of the BGTask. Throttled to once an hour and dispatched
    /// `.detached(.utility)` so it never touches the foreground hot path.
    @MainActor
    func sweepSWRCacheOnForeground(force: Bool = false) {
        guard swrCacheSweepThrottle.shouldRun(force: force) else { return }
        let coordinator = swr
        Task.detached(priority: .utility) {
            let dropped = await coordinator.foregroundMaintenanceSweep()
            if dropped > 0 {
                // Pure row count — operator-grade, no PII.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.cache.info("Foreground SWR cache sweep — dropped=\(dropped, privacy: .public)")
            }
        }
    }

    /// #30 — reload the server module map + recompute the cycle gate against it.
    /// Fail-open inside `ModuleGate.load()` (a network failure leaves the
    /// last-known map / all-on default in place).
    @MainActor
    private func refreshModuleGate() async {
        await moduleGate.load()
        cycleGate.refresh()
    }

    /// CCH-03 — refresh the Coach unread signal. Gated on the `coach` module
    /// (off → the store clears any stale dot, no call) and the cheap GET
    /// fail-quiets on a network error, so the same coalesced foreground path
    /// drives it. `online: true` lets the store attempt the request; an offline
    /// foreground just logs + keeps the last-known dot (matching the flags
    /// refresh, which also doesn't pre-probe reachability).
    @MainActor
    private func refreshCoachNudge() async {
        await coachNudgeStore.refresh(
            coachEnabled: moduleGate.isEnabled(.coach),
            online: true
        )
    }

    /// A7-M1 — coarse foreground throttle gate for the three "cheap but
    /// unconditional" members (HK-readiness refresh, App-Badge recompute,
    /// mood-reminder re-arm). `RootView` consults this once per `.active` so a
    /// rapid app-switcher bounce is a no-op; a genuine re-foreground after the
    /// window runs them. `force` is reserved for an explicit re-foreground after
    /// a real pause (kept symmetrical with the other throttle entry points).
    @MainActor
    func shouldRunForegroundCheapMembers(force: Bool = false) -> Bool {
        foregroundCheapThrottle.shouldRun(force: force)
    }

    /// **14-05 (D-09-06-A) — read the gate, and remember what the stamp was.**
    ///
    /// Identical to ``shouldRunForegroundCheapMembers(force:)`` in every
    /// observable way — one read, one stamp, the six members stay atomic per
    /// window — plus the stamp it replaced, so a pass that turns out to have
    /// spent nothing can hand the window back. Keeping the stamp AT BUILD TIME
    /// is deliberate: two foregrounds a few milliseconds apart must not both be
    /// admitted, and only a synchronous read-and-stamp can promise that.
    @MainActor
    func beginForegroundCheapMembers(force: Bool = false) -> (runs: Bool, previousStamp: Date?) {
        let previous = foregroundCheapThrottle.lastRunAt
        return (foregroundCheapThrottle.shouldRun(force: force), previous)
    }

    /// **14-05 (D-09-06-A) — give the window back to whoever will spend it.**
    ///
    /// Called once, from the pass's own settle hook, when the report shows that
    /// no throttled member reached a terminal outcome. A completed pass never
    /// reaches here and its stamp stands exactly as it does today.
    @MainActor
    func restoreForegroundCheapThrottle(to stamp: Date?) {
        foregroundCheapThrottle.restore(stamp)
    }

    /// A7-M2 — probe-gated foreground outbox re-drain.
    ///
    /// The replay loop is edge-triggered on an `NWPath` `false→true` transition
    /// that also passes `confirmedReachable()` (battery-safe, no polling). The
    /// gap: if the network came up *while backgrounded* (no fresh edge) and the
    /// last edge saw `confirmedReachable() == false` (captive portal / failing
    /// server), the outbox can stall with no re-drain until the next interface
    /// flip. This adds a single foreground `runOnce()` **gated on a confirmed
    /// reachability probe** — so it stays a probe, never a timer/poll. A
    /// foreground on a network that is genuinely up drains once; an offline or
    /// captive foreground is a no-op (the probe fails closed).
    @MainActor
    func foregroundDrainOutboxIfReachable() async {
        guard await reachability.confirmedReachable() else { return }
        await outboxReplay.runOnce()
    }

    /// v0.12 W8-4 — wire the BGTask cache-sweep hook. Both SQLite caches grow
    /// monotonically for engaged users (`sweepOlderThan` was defined + tested
    /// but never invoked). The SWR snapshot cache keeps 30 days; the
    /// HK-daily-stats cache keeps 90 (server-state is authoritative beyond
    /// that). `swr` (SWRCoordinator) + the protocol-typed `dailyStats` are both
    /// `Sendable`, so they cross into the `@Sendable` hook by value. Best-
    /// effort: each passthrough swallows + logs its own errors so the BGTask
    /// never fails on cache maintenance.
    internal static func wireCacheSweepHook(
        backgroundSync: BackgroundSyncCoordinator,
        swr: SWRCoordinator,
        dailyStats: HealthKitDailyStatsSyncing?
    ) {
        backgroundSync.attachCacheSweepHook { [weak swr, weak dailyStats] in
            // AUD-8 H-1 — age-sweep AND the hard row-count cap, so a power user's
            // SQLite stays bounded even on the BGTask path.
            let swrDropped = await swr?.foregroundMaintenanceSweep() ?? 0
            let statsDropped = await dailyStats?.sweepCacheOlderThan(90 * 24 * 60 * 60, now: .now) ?? 0
            // Pure row counts — operator-grade, no PII.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.cache.info(
                "BGTask cache sweep — swr=\(swrDropped, privacy: .public) dailyStats=\(statsDropped, privacy: .public)"
            )
        }
    }

    /// **b181 W-B181 (DOUBLE-DOSE SAFETY)** — wire the BGTask med-reconcile hook.
    /// On every guaranteed-sync wakeup the coordinator force-revalidates the
    /// medications store so a dose taken on the WEB / a second device falls into
    /// the store even without an app foreground, driving the store's
    /// `onIntakesDidChange` chain (Live Activity end/refresh + med widget
    /// timeline reload). The store is `@MainActor`, so the `@Sendable` hook hops
    /// onto the main actor for the load; the weak capture means a torn-down
    /// container is a harmless no-op. Best-effort — a failed load is swallowed by
    /// the store (sets `error`, keeps last-known) and never fails the BGTask.
    internal static func wireMedicationReconcileHook(
        backgroundSync: BackgroundSyncCoordinator,
        medicationsStore: MedicationsStore
    ) {
        backgroundSync.attachMedicationReconcileHook { [weak medicationsStore] in
            // Await the load INLINE on the main actor (no fire-and-forget Task)
            // so the BGTask does not call `setTaskCompleted` before the
            // reconcile lands — the whole point of the guaranteed-sync wakeup.
            await medicationsStore?.load(force: true)
        }
    }

    /// **v0.15.5 AUD-1 F4 (mood-reminder reliability)** — wire the BGTask
    /// mood-reminder re-arm hook. On every guaranteed-sync wakeup the
    /// coordinator re-runs `NotificationService.reconcileMoodReminder` with the
    /// live toggle + "logged today?" signal + the chosen hour, so the local
    /// evening mood reminder is re-armed even when the app is never foregrounded.
    /// Without this the non-repeating `mood-reminder-local` trigger fired once
    /// and then went silent until the next app-open (`scenePhase .active`). The
    /// stores are `@MainActor`, so the `@Sendable` hook hops onto the main actor
    /// for the read + re-arm; the weak captures make a torn-down container a
    /// harmless no-op. Best-effort — `reconcileMoodReminder` never throws and a
    /// hiccup must not fail the BGTask.
    internal static func wireMoodReminderBackgroundRearm(
        backgroundSync: BackgroundSyncCoordinator,
        moodStore: MoodStore,
        notifications: NotificationService,
        settingsStore: SettingsStore
    ) {
        backgroundSync.attachMoodReconcileHook { [weak moodStore, weak notifications, weak settingsStore] in
            // Hop to the main actor and AWAIT the re-arm inline so the BGTask
            // does not call `setTaskCompleted` before the pending mood request
            // is enqueued — the same guaranteed-sync contract the med hook uses.
            await Self.reconcileMoodReminderForBackground(
                moodStore: moodStore,
                notifications: notifications,
                settingsStore: settingsStore
            )
        }
    }

    /// `@MainActor` helper for ``wireMoodReminderBackgroundRearm`` so the weak
    /// stores can be read + the re-arm awaited on the main actor without a
    /// `MainActor.run` closure straddling the `@Sendable` hook boundary.
    @MainActor
    private static func reconcileMoodReminderForBackground(
        moodStore: MoodStore?,
        notifications: NotificationService?,
        settingsStore: SettingsStore?
    ) async {
        // v0.14.1 H2 — repeating trigger; the "logged today" suppression is a
        // foreground `willPresent` concern, so `moodStore` is only liveness-
        // checked here, not read for a re-arm input.
        guard moodStore != nil, let notifications, let settingsStore else { return }
        let enabled = settingsStore.profile?.moodReminderEnabled ?? false
        await notifications.reconcileMoodReminder(
            enabled: enabled,
            hour: MoodReminderPrefStore.hour()
        )
    }
}
