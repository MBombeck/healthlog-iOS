import Foundation

// MARK: - W1 Fix 3 — single ChartDetailStore factory

public extension AppContainer {
    /// Canonical `ChartDetailStore` constructor for every drill-in surface
    /// (Dashboard, Charts, Trends, Insights tiles).
    ///
    /// **Why this exists (W1 Fix 3).** The store was built at four call-sites
    /// that drifted: only the Dashboard threaded `liveTodayStepsProvider` +
    /// `preLoadHook`, so opening a `.steps` chart from Trends/Insights/Charts
    /// showed the *frozen* server snapshot for today's bar instead of the live
    /// HK total, and the AI-consent gate / HK pre-load wiring was re-spelled
    /// (and could silently fall out of sync) at each site. Routing all four
    /// through one factory means consent + pre-load + live-steps can never
    /// diverge by entry point again.
    ///
    /// The matched-geometry namespace stays a *screen-level* concern — it is a
    /// `ChartDetailScreen` parameter, not a store input, and only the Dashboard
    /// owns a namespace source — so it is wired at the call-site, not here.
    func makeChartDetailStore(kind: MetricKind) -> ChartDetailStore {
        ChartDetailStore(
            kind: kind,
            measurementsRepo: measurementsRepo,
            insightsRepo: metricInsightsRepo,
            // PB1 H1 — chart-detail "Befunde" respects the same AI-consent
            // gate as the Insights tab.
            consentGate: makeAIConsentGate(),
            // v0.6.2.x bug-c10 — cumulative kinds (Steps) POST today's fresh
            // HK day-total before the series fan-out so the chart never paints
            // a stale day-total. `nil` for spot kinds keeps the round-trip
            // scoped.
            preLoadHook: makeChartDetailPreLoadHook(for: kind),
            // v0.6.2.x bug-c10-ios-direct — resolve today's HK-direct step
            // total from the live store so the chart-detail today-bar + hero
            // can override the (frozen) server snapshot. Honored only for
            // `.steps` inside the store.
            liveTodayStepsProvider: { [weak self] in self?.liveHealthKitTodayStore.todayStepCount },
            // v0.14 DATA — user height (cm) from the server profile, for the
            // derived `.bmi` series (BMI = weight_kg / height_m²). Read live so a
            // later settings hydration is honoured; only consulted for `.bmi`.
            heightCmProvider: { [weak self] in self?.settingsStore.profile?.heightCm.map(Double.init) }
        )
    }

    /// v0.14 DATA — point the medications store's due-derive at the server-
    /// profile IANA timezone. Read live via a provider so a later SWR profile
    /// emission is honoured without re-wiring; falls back to `.current` until the
    /// profile carries a valid zone. Lives here (not the composition-root file)
    /// to keep `AppContainer.swift` under the file_length gate.
    static func wireMedicationDueTimeZone(
        medicationsStore: MedicationsStore,
        dashboardStore: DashboardStore,
        dailyBriefingStore: DailyBriefingStore,
        settingsStore: SettingsStore,
        measurementsRepo: MeasurementsRepository,
        profileTimeZoneBox: ProfileTimeZoneBox
    ) {
        let resolve: () -> TimeZone = { [weak settingsStore] in
            settingsStore?.resolvedProfileTimeZone ?? .current
        }
        medicationsStore.profileTimeZoneProvider = resolve
        // v0.14.8 INV-home-compliance-slot — anchor the `.dashboardSummary` SWR
        // key on the SAME profile zone so the Home compliance ring's cache rolls
        // over at the same midnight the medication "today" bucket does. Without
        // this the day-N `summary.compliance` snapshot would be SWR-served on
        // day N+1 and render a phantom "2 von 2 genommen".
        dashboardStore.profileTimeZoneProvider = resolve

        // AUD-3 D-3 — bridge the SAME profile zone to the off-main-actor
        // `MeasurementsRepository` so its `.dashboardSummary` write-invalidation
        // day-key matches the day-key `DashboardStore` READS. The repo's provider
        // is `@Sendable`, so it reads the lock-protected box rather than reaching
        // into the `@MainActor` `SettingsStore`. Seed the box with the current
        // value and keep it fresh on every profile-timezone change.
        profileTimeZoneBox.update(settingsStore.resolvedProfileTimeZone)
        settingsStore.onProfileTimeZoneChange = { [weak profileTimeZoneBox] zone in
            profileTimeZoneBox?.update(zone)
        }
        // BH-final-diff M4 — anchor the Daily Briefing day-key on the SAME profile
        // zone (via the Sendable box) so the cached briefing rolls over at the
        // profile midnight, consistent with dashboard/compliance. Reading the box
        // keeps the provider `@Sendable` (no `@MainActor` SettingsStore capture).
        dailyBriefingStore.profileTimeZoneProvider = { [profileTimeZoneBox] in
            profileTimeZoneBox.current
        }
        Task {
            await measurementsRepo.setProfileTimeZoneProvider { [profileTimeZoneBox] in
                profileTimeZoneBox.current
            }
        }
    }

    /// Pre-load hook for `makeChartDetailStore(kind:)` — POSTs today's fresh HK
    /// day-total for cumulative kinds before the store's `series`/`recent`
    /// fan-out reads the server, `nil` for spot kinds. Explicitly-typed (not an
    /// inline ternary) to keep the Swift 6 closure-Sendable inference happy.
    private func makeChartDetailPreLoadHook(for kind: MetricKind) -> (@Sendable () async -> Void)? {
        guard kind.isCumulative else { return nil }
        return { [weak self] in
            await self?.refreshHealthKitDailyStatsForToday()
        }
    }
}
