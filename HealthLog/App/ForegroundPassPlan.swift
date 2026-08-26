import Foundation

/// **Phase 09 / plan 09-06 — what the production foreground pass is made of.**
///
/// ``shape`` is the pass's *ordering contract*, stated as members only and
/// independent of what any member does: each inner array is one leg, legs run
/// concurrently, and the steps inside a leg run in order. ``make(container:authStore:settings:hkReadiness:)``
/// builds the real plan by walking exactly this value, so the shape a contract
/// test reads and the shape production runs cannot drift apart — a second
/// hand-written list would be a second definition that can.
///
/// Every adapter body below is the body `RootView` already had, moved rather
/// than rewritten. What changed is where they run and what may interrupt them,
/// which is orchestration; what did not change is any service.
enum ForegroundPassPlan {
    /// The legs of the foreground pass, in start order.
    ///
    /// Two legs carry a real dependency and everything else is genuinely
    /// independent:
    ///
    /// - **`medicationLoad` → `badgeRefresh`.** The badge is
    ///   `MedicationsStore.dueOrMissedCount`. Before this plan the two were
    ///   sibling tasks and a comment claimed the badge ran "AFTER the force-load
    ///   above settles"; it did not, and the badge could publish a count taken
    ///   from the pre-foreground snapshot — the stale "jetzt nehmen" the forced
    ///   load exists to prevent.
    /// - **`dashboardSummary` → `healthKitStats`.** **13-03 reversed this pair,
    ///   and the reversal is the fix for the operator's A1.** 09-06 ordered the
    ///   sweep first for W8-A1's contract: the HK sync POSTs today's totals so
    ///   the summary re-read picks up the fresh server rows. The ordering is
    ///   sound; its effect in a *bounded* pass was not. The pass is capped at
    ///   250 ms + 50 ms and `ForegroundSession.isCurrent` folds in
    ///   `!Task.isCancelled`, so once the deadline cancels the leg the next
    ///   step's guard records `.skipped`. A sweep that does real work does not
    ///   finish inside 250 ms — so the summary step ran only on the passes
    ///   where the sweep was inside its own 10 s throttle and did *nothing*.
    ///   The contract delivered freshness exactly when there was none to
    ///   deliver, and starved the revalidation the rest of the time. Foreground
    ///   dashboard revalidation was, in effect, dead in build 266.
    ///
    ///   So the freshness ordering is traded for the refresh happening at all —
    ///   a refresh that never runs cannot be fresh. The asymmetry that makes the
    ///   trade one-sided: the HealthKit sweep has other routes to the server
    ///   (`HKObserverQuery`, background delivery, the `BGProcessingTask`), and
    ///   the dashboard summary has exactly one other route — the user pulling
    ///   to refresh. The pair stays ONE leg rather than becoming two, so this
    ///   adds no concurrent child to a 250 ms budget: it is an ordering change,
    ///   not a budget change. `ForegroundCoordinator` is untouched.
    static let shape: [[ForegroundMember]] = [
        [.medicationLoad, .badgeRefresh],
        [.dashboardSummary, .healthKitStats],
        [.webDeletionReconcile],
        [.focusFilter],
        [.networkRevalidate],
        [.healthKitReadiness],
        [.moodReminder],
        [.moodRevalidate],
        [.cycleGate],
        [.outboxDrain],
        [.insightsWarm],
        [.swrCacheSweep],
        [.doctorReportSweep]
    ]

    /// Whether `shape` runs `later` strictly after `earlier` has finished — that
    /// is, whether the two sit in one leg with `earlier` ahead of `later`.
    ///
    /// Two members in two different legs are **not** ordered, however they are
    /// printed: that is the defect this plan closes, and a predicate that
    /// answered "yes" for adjacent legs would hide it.
    static func ordersStrictly(_ later: ForegroundMember, after earlier: ForegroundMember) -> Bool {
        shape.contains { leg in
            guard let earlierIndex = leg.firstIndex(of: earlier),
                  let laterIndex = leg.firstIndex(of: later) else { return false }
            return earlierIndex < laterIndex
        }
    }

    /// How many legs mention `member`. Exactly one, always: a member that appears
    /// twice runs twice per pass.
    static func legCount(mentioning member: ForegroundMember) -> Int {
        shape.filter { $0.contains(member) }.count
    }

    // MARK: - 14-05 (D-09-06-A) — the window accounting

    /// The members A7-M1's coarse 8-second throttle admits, and therefore the
    /// members its stamp is a claim ABOUT. Everything else in the pass is gated
    /// on authentication or on nothing at all, and is unaffected by the window.
    ///
    /// This is the `admits(_:)` table's `runsCheapMembers` arms, named once so
    /// the gate and the accounting cannot drift apart.
    static let throttledMembers: Set<ForegroundMember> = [
        .healthKitReadiness,
        .moodRevalidate,
        .cycleGate,
        .badgeRefresh,
        .moodReminder,
        .medicationLoad
    ]

    /// **Did this pass actually spend the window it stamped?**
    ///
    /// D-09-06-A in one predicate. The gate is read — and stamped — when the
    /// plan is built, which is before a member has run; a pass that is then
    /// cancelled or truncated at member zero burns eight seconds on work it
    /// never did, and the next foreground inside the window is refused the
    /// members it was owed. That is foreground-shaped data shortfall, and it is
    /// the foreground half of the operator's J3.
    ///
    /// The rule is deliberately the simplest one that is true: the window was
    /// spent if **at least one throttled member reached a terminal, non-skipped
    /// outcome**. `.finished`, `.cancelled` and `.failed` all count — a member
    /// that returned from its work has done that work, however the pass ended —
    /// and `.skipped` does not, because a skipped member never started. A `nil`
    /// report is a pass that never ran at all, which spends nothing.
    ///
    /// What this rule does NOT do is weaken the throttle: a completed pass has
    /// six terminal throttled members and stamps the window exactly as today.
    static func passSpentTheThrottleWindow(_ report: ForegroundPassReport?) -> Bool {
        guard let report else { return false }
        let terminal = report.members(in: .finished)
            + report.members(in: .cancelled)
            + report.members(in: .failed)
        return terminal.contains { throttledMembers.contains($0) }
    }

    /// The plan for one `.active` transition.
    ///
    /// Every gate is evaluated **once**, here, synchronously on the main actor —
    /// which is exactly where `RootView.handle(scenePhase:)` evaluated them
    /// before. A7-M1's coarse throttle in particular has to stay a single read,
    /// so its six members remain all-or-nothing per window.
    @MainActor
    static func make(
        container: AppContainer,
        authStore: AuthStore,
        settings: SettingsStore,
        hkReadiness: HKReadinessStore
    ) -> ForegroundPlan {
        // 14-05 (D-09-06-A) — the coarse gate is still read ONCE, here, and
        // still stamps the window at build time so two foregrounds a few
        // milliseconds apart cannot both be admitted. What is new is that the
        // stamp it replaced comes back with it, so the pass can hand the window
        // over if it turns out to have spent nothing.
        let cheap = container.beginForegroundCheapMembers()
        let builder = Builder(
            container: container,
            authStore: authStore,
            settings: settings,
            hkReadiness: hkReadiness,
            isAuthenticated: authStore.phase.isAuthenticatedAccount,
            isStandalone: container.syncModeStore.isStandalone,
            hasPendingWebDeletion: authStore.hasPendingWebDeletion,
            runsCheapMembers: cheap.runs
        )
        let plan = builder.plan()
        guard cheap.runs else {
            // Nothing was stamped (a refused read does not re-arm the window),
            // so there is nothing to hand back.
            return plan
        }
        let previousStamp = cheap.previousStamp
        return ForegroundPlan(legs: plan.legs) { [weak container] report in
            guard !passSpentTheThrottleWindow(report) else { return }
            await MainActor.run {
                container?.restoreForegroundCheapThrottle(to: previousStamp)
            }
        }
    }

    /// `scenephase.revalidate` is the project-guide budget for the *existing*
    /// revalidation chain, and this is that chain. It stays a leg interval so it
    /// keeps measuring what it always measured; `foreground.pass` is the bounded
    /// coordinator boundary and is a different span now, exactly as 09-01's
    /// evidence note predicted it would become.
    fileprivate static func interval(for members: [ForegroundMember]) -> HLPerfSignpost.Interval? {
        members.contains(.healthKitStats) ? .scenePhaseRevalidate : nil
    }

    /// The gates, read once, and the adapters they admit.
    private struct Builder {
        let container: AppContainer
        let authStore: AuthStore
        let settings: SettingsStore
        let hkReadiness: HKReadinessStore
        let isAuthenticated: Bool
        let isStandalone: Bool
        let hasPendingWebDeletion: Bool
        /// A7-M1 — the coarse foreground throttle, consulted once so its six
        /// members stay atomic per window.
        let runsCheapMembers: Bool

        /// Walks ``ForegroundPassPlan/shape`` once, admitting each member and
        /// dropping any leg that came out empty. The adapter table is built once
        /// per pass rather than per member, which is also what keeps the gate and
        /// the adapter two separate, individually readable decisions.
        func plan() -> ForegroundPlan {
            let adapters = adapters
            let legs = ForegroundPassPlan.shape.compactMap { members -> ForegroundLeg? in
                let steps = members.compactMap { member -> ForegroundStep? in
                    guard admits(member), let work = adapters[member] else { return nil }
                    return ForegroundStep(member, work)
                }
                guard !steps.isEmpty else { return nil }
                return ForegroundLeg(steps, interval: ForegroundPassPlan.interval(for: members))
            }
            return ForegroundPlan(legs: legs)
        }

        /// Whether this foreground admits `member` at all. Every clause is one of
        /// the `guard`s the corresponding `RootView` helper opened with, or one
        /// of the two `if` blocks that wrapped it — read once, in
        /// ``ForegroundPassPlan/make(container:authStore:settings:hkReadiness:)``.
        private func admits(_ member: ForegroundMember) -> Bool {
            switch member {
            case .focusFilter, .swrCacheSweep, .doctorReportSweep:
                true
            case .webDeletionReconcile:
                hasPendingWebDeletion
            case .healthKitReadiness, .moodRevalidate, .cycleGate:
                runsCheapMembers
            case .badgeRefresh, .moodReminder:
                runsCheapMembers && isAuthenticated
            case .medicationLoad:
                runsCheapMembers && isAuthenticated && !isStandalone
            case .networkRevalidate, .outboxDrain, .healthKitStats, .dashboardSummary, .insightsWarm:
                isAuthenticated
            }
        }

        /// The whole adapter table. A dictionary rather than a fifteen-armed
        /// switch: the arms carry no logic — the gates are in ``admits(_:)`` —
        /// so a `switch` here would only be a branch count.
        private var adapters: [ForegroundMember: ForegroundWork] {
            [
                .webDeletionReconcile: webDeletionReconcile,
                .focusFilter: Builder.focusFilterReconcile,
                .networkRevalidate: networkRevalidate,
                .healthKitReadiness: healthKitReadinessRefresh,
                .medicationLoad: medicationLoad,
                .badgeRefresh: badgeRefresh,
                .moodReminder: moodReminderReconcile,
                .moodRevalidate: moodRevalidate,
                .cycleGate: cycleGateRefresh,
                .outboxDrain: outboxDrain,
                .healthKitStats: healthKitStats,
                .dashboardSummary: dashboardSummary,
                .insightsWarm: insightsWarm,
                .swrCacheSweep: swrCacheSweep,
                .doctorReportSweep: Builder.doctorReportSweep
            ]
        }

        // MARK: The adapters, verbatim from `RootView`

        /// Privacy H3 (audit-v0162) — MFA web-deletion return detection. A
        /// 401/404 on `/api/auth/me` means the account is gone, so the full
        /// `.accountDeleted` local wipe runs and no PHI survives. No-op unless
        /// `DeleteAccountScreen` armed the flag.
        private var webDeletionReconcile: ForegroundWork {
            { [authStore] _ in await authStore.reconcilePendingWebDeletion() }
        }

        /// W-FOCUS-FILTER — the system calls the intent's `perform()` when a
        /// Focus turns ON, but only sets `current = nil` (no `perform`) when it
        /// turns OFF. This clears the persisted "active" config the moment the
        /// Focus stops reporting it, so routine reminders resume promptly.
        private static let focusFilterReconcile: ForegroundWork = { _ in
            let activeFilter = try? await HealthLogFocusFilterIntent.current
            guard activeFilter == nil, FocusFilterConfigStore.current().isActive else { return }
            FocusFilterConfigStore.clear()
        }

        /// v0.12 W8-8 — the coalesced network-touching foreground entry point
        /// (module map, feature flags, coach nudge, slot gate, APNs
        /// re-registration), self-gated inside an 8 s window.
        private var networkRevalidate: ForegroundWork {
            { [container] _ in await container.foregroundNetworkRevalidate(authenticated: true) }
        }

        /// The user may have changed Health permissions in Settings while the app
        /// was backgrounded. Cheap status query.
        private var healthKitReadinessRefresh: ForegroundWork {
            { [hkReadiness] _ in await hkReadiness.refresh() }
        }

        /// b181 W-B181 (DOUBLE-DOSE SAFETY) — force-revalidate the medications
        /// store so a dose taken on the WEB or a second device reaches the in-app
        /// dose list, the Live Activity and the widgets **before** the badge
        /// recompute reads `dueOrMissedCount`. That "before" is now a leg
        /// ordering rather than a comment. Standalone has no server to
        /// revalidate against.
        ///
        /// **14-06 — this goes through the store's own throttle now.** It used to
        /// call `load(force: true)` directly, which walked around
        /// `loadOnForeground()` — the entry point the store documents for exactly
        /// this caller (`MedicationsStore.swift:163-171`) and whose comment says
        /// why it exists: a `scenePhase == .active` flap (notification-centre
        /// peek, app-switcher scrub, Control-Centre pull) fires repeatedly, and
        /// each event used to run "3 SWR force-revalidate fetches + a compliance
        /// fan-out". `MedicationsScreen` already routes its own foreground hook
        /// through the throttle; the pass was the one caller that did not, so the
        /// coalescing the throttle exists to provide was defeated by its most
        /// frequent client.
        ///
        /// This is a fan-out reduction, not an ordering change: no leg moves, no
        /// leg splits, no budget value moves, and `ForegroundCoordinator` is not
        /// touched. 13-03's `[.dashboardSummary, .healthKitStats]` reversal is
        /// neither read nor written here. A genuine resume past the 3 s window
        /// still forces exactly as before.
        private var medicationLoad: ForegroundWork {
            { [container] _ in await container.medicationsStore.loadOnForeground() }
        }

        /// v0.6.1.3 Y4.1 — recompute the App-Badge against the live
        /// `MedicationsStore.dueOrMissedCount`. Published through the session, so
        /// a pass whose account has already been superseded cannot put the
        /// previous user's dose count on the icon.
        private var badgeRefresh: ForegroundWork {
            { [container] session in
                #if canImport(UserNotifications) && canImport(UIKit)
                    await session.publish {
                        await container.notifications.refreshBadge(from: container.medicationsStore)
                    }
                #endif
            }
        }

        /// v0.10.0 W-Mood-B + AUDIT-G A1-B1 — cold-read the server-canonical
        /// mood-reminder hour, then re-arm or cancel the iOS-local evening
        /// reminder. Best-effort and fail-open: a failed read leaves the local
        /// mirror in place.
        private var moodReminderReconcile: ForegroundWork {
            { [container, settings] _ in
                let enabled = await MainActor.run { settings.profile?.moodReminderEnabled ?? false }
                if enabled { await ForegroundPassPlan.hydrateMoodReminderHour(container: container) }
                await container.notifications.reconcileMoodReminder(
                    enabled: enabled,
                    hour: MoodReminderPrefStore.hour()
                )
            }
        }

        /// v0.14.3 E3 — revalidate the Stimmung card. The store's 60 s gate keeps
        /// it cheap and the `.moodEntries` SWR row serves cache-first.
        private var moodRevalidate: ForegroundWork {
            { [container] _ in await container.moodStore.revalidateIfStale() }
        }

        /// v0.14.8 C4 — re-resolve the cycle gate and drive the C2 importer
        /// lifecycle to match. Dormant behind `FeatureFlag.cycleTracking`.
        private var cycleGateRefresh: ForegroundWork {
            { [container] _ in await container.cycleStore.refreshGateLifecycle() }
        }

        /// A7-M2 — probe-gated foreground outbox re-drain. Stays a probe, never a
        /// poll: an offline or captive foreground is a no-op.
        private var outboxDrain: ForegroundWork {
            { [container] _ in await container.foregroundDrainOutboxIfReachable() }
        }

        /// The foreground HealthKit route — one `HealthSyncTrigger.foreground`
        /// pass per genuine foreground, self-throttled inside the container.
        /// Receiving is READING, so it gates on "has the auth sheet ever run",
        /// never on the write-derived state (#66 follow-up).
        private var healthKitStats: ForegroundWork {
            { [container, hkReadiness] _ in
                let everAsked = await MainActor.run { hkReadiness.hasEverRequestedAuthorization }
                guard everAsked else { return }
                await container.refreshHealthKitDailyStatsForToday()
            }
        }

        /// W8-A1 — foreground dashboard-summary revalidation, TTL-gated inside
        /// the store. Published through the session for the same reason the badge
        /// is: it is user-visible state.
        ///
        /// 13-03 — first in its leg now, ahead of the HealthKit sweep. See the
        /// rationale on ``ForegroundPassPlan/shape``. What this buys inside a
        /// 250 ms budget, stated honestly: the SWR cache emission lands and the
        /// skeleton comes down, and the network revalidation *starts*. Whether
        /// that revalidation completes inside the bound is a budget question,
        /// and the truncated-pass half of it is D-09-06-A — Phase 14's, not
        /// this plan's.
        private var dashboardSummary: ForegroundWork {
            { [container] session in
                await session.publish { await container.dashboardStore.refresh() }
            }
        }

        /// W3 (v0.11 #22) — warm the daily Insights caches. `warmAndAwait()`
        /// rather than `warm()`: the fire-and-forget variant spawns a task the
        /// pass could neither cancel nor drain, which is the shape this plan
        /// removes. The service's own re-entry guard and backend gate are
        /// unchanged, so a warm already in flight is still a no-op.
        private var insightsWarm: ForegroundWork {
            { [container] _ in await container.insightsPrefetch.warmAndAwait() }
        }

        /// AUD-8 H-1 — keep the persistent SWR cache bounded from a foreground
        /// entry point. Throttled to once an hour and dispatched off the main
        /// actor inside the call.
        private var swrCacheSweep: ForegroundWork {
            { [container] _ in await container.sweepSWRCacheOnForeground() }
        }

        /// v0.7.0 W-SEC-M-1 — sweep doctor-report PDF/FHIR residue older than
        /// 24 h from `temporaryDirectory`. The walk is a blocking file operation,
        /// so it keeps its utility-priority executor; the pass awaits it rather
        /// than abandoning it, and skips it outright once cancelled.
        private static let doctorReportSweep: ForegroundWork = { _ in
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) { _ = DoctorReportTmpSweeper.sweep() }.value
        }
    }

    /// AUDIT-G A1-B1 (v0.11) — refresh the `MoodReminderPrefStore` mirror from
    /// the server-canonical `GET /api/auth/me/notification-prefs` hour. Only
    /// writes when the server actually surfaced a value; a drifted/older server
    /// (`nil`) leaves the existing mirror untouched.
    private static func hydrateMoodReminderHour(container: AppContainer) async {
        let repo = NotificationsRepository(api: container.api)
        do {
            let prefs = try await repo.authNotificationPrefs()
            if let hour = prefs.moodReminderHour {
                MoodReminderPrefStore.setHour(hour)
            }
        } catch {
            HLLog.notifications.warning(
                "Mood-Reminder-Stunde cold-read fehlgeschlagen — lokaler Mirror bleibt. err=\(error.localizedDescription)"
            )
        }
    }
}

/// The shape every foreground adapter has.
typealias ForegroundWork = @Sendable (ForegroundSession) async throws -> Void

extension AuthStore.Phase {
    /// Whether this phase carries a live server account — the gate every
    /// `guard case .authenticated = authStore.phase` in the old foreground
    /// handler was spelling out longhand.
    var isAuthenticatedAccount: Bool {
        if case .authenticated = self { return true }
        return false
    }
}
