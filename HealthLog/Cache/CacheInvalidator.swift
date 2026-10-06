import Foundation

/// Mutation → keys matrix. Mirrors the web `CacheInvalidator` from server
/// doc-pack `13-state-management.md` §4. Stores call this AFTER their
/// optimistic-write returns successfully so the next observer pass re-fetches
/// the affected keys.
///
/// **Test invariant:** every mutation in `MutationKind` returns a non-empty
/// set of keys. Stream Bravo/Charlie/Delta/Foxtrot/Golf wire mutation
/// call-sites; the matrix here is the contract they bind to.
public enum MutationKind: Sendable, Hashable {
    case measurementChange(kind: MetricKind)
    case moodEntryChange
    case medicationChange
    case medicationIntakeChange
    case insightsFeedback
    case settingsChange
}

public extension MutationKind {
    /// Keys that should be invalidated after this mutation succeeds.
    ///
    /// **#115 1.5** — the day-anchored keys (`.dashboardSummary(day:)`,
    /// `.medicationsTodayIntakes(day:)`) are cut in the ACCOUNT zone, the same
    /// zone `DashboardStore.dashboardSummaryKey` / `MedicationsStore
    /// .todayIntakesKey` read them in (``ProfileDay``, fed from `/me`). This
    /// matrix used to anchor on the device zone, so for anyone whose phone and
    /// account disagree it invalidated a day row nobody reads — around
    /// midnight, the live row survived a write and served the old compliance
    /// ring.
    var affectedKeys: [CacheKey] {
        affectedKeys(profileTimeZone: ProfileDay.timeZone)
    }

    /// ``affectedKeys`` with the zone and clock pinned (the unit-test seam).
    func affectedKeys(profileTimeZone: TimeZone, now: Date = .now) -> [CacheKey] {
        let day = MedicationDayKey.string(for: now, timeZone: profileTimeZone)
        let dashboardSummaryKey = CacheKey.dashboardSummary(day: day)
        return switch self {
        case let .measurementChange(kind):
            // Invalidate all measurement-series buckets for this kind +
            // measurements-recent + dashboard summary + comprehensive insights.
            [
                .measurementsRecent(limit: 50),
                .measurementSeries(kind: kind, days: 7),
                .measurementSeries(kind: kind, days: 30),
                .measurementSeries(kind: kind, days: 90),
                .measurementSeries(kind: kind, days: 365),
                // audit-v0162 M-3/M-4 — the authoritative measurement-write
                // invalidation runs in `MeasurementsRepository+Writes`
                // (`invalidateAfterWrite`), which already drops these; mirror them
                // here so this cross-cutting contract matrix does not under-report
                // the affected set (the dead-`moodEntryChange` lesson).
                .measurementAvailability,
                .measurementsRecentKind(type: kind.availabilitySummaryKey ?? kind.rawValue, limit: 400),
                dashboardSummaryKey,
                .healthScore,
                .insightsComprehensive,
                .insightsCards,
                .metricInsights(kind: kind, locale: "de"),
                .metricInsights(kind: kind, locale: "en")
            ]
        case .moodEntryChange:
            [
                .moodEntries(days: 7),
                .moodEntries(days: 30),
                .moodEntries(days: 90),
                // audit-v0162 M-2 — `MoodStore.load()` observes the 365-day
                // window (`MoodStore.swift`), yet this arm previously listed only
                // 7/30/90 — so even once a caller existed the row the store reads
                // was never dropped. Include 365 so a mood write actually
                // invalidates the served slice. `MoodRepository` is now the live
                // caller (M-2), so this arm is no longer dead.
                .moodEntries(days: 365),
                .moodInsights,
                .moodDailySeries,
                dashboardSummaryKey,
                .insightsComprehensive,
                .insightsCards,
                .healthScore
            ]
        case .medicationChange:
            [
                .medicationsList,
                // v0.14.1 INV-med-cadence-phantom (BUG 2): the today-intakes key
                // is day-anchored (profile-tz `yyyy-MM-dd`); #115 1.5 — this
                // matrix now cuts it in the same profile zone.
                .medicationsTodayIntakes(day: day),
                // v0.5.5.3 (2026-05-21): keep the invalidation key arity in
                // lock-step with the compliance fetch window, otherwise
                // mutations would never sweep the cached row.
                // #13 (2026-06-11): references the shared
                // `CacheKey.complianceWindowDays` constant directly (182 =
                // the 26-week picker maximum) so the lock-step can no
                // longer drift.
                .medicationsCompliance(days: CacheKey.complianceWindowDays),
                dashboardSummaryKey
            ]
        case .medicationIntakeChange:
            [
                .medicationsTodayIntakes(day: day),
                .medicationsCompliance(days: CacheKey.complianceWindowDays),
                dashboardSummaryKey,
                .healthScore
            ]
        case .insightsFeedback:
            [.insightsCards]
        case .settingsChange:
            [.userProfile, dashboardSummaryKey]
        }
    }
}

/// Apply a mutation: pure pass-through to the coordinator. Lives as a tiny
/// facade so call-sites read like `await invalidator.apply(.medicationIntakeChange)`
/// rather than reaching directly into the coordinator.
public struct CacheInvalidator: Sendable {
    private let coordinator: SWRCoordinator

    public init(coordinator: SWRCoordinator) {
        self.coordinator = coordinator
    }

    public func apply(_ mutation: MutationKind) async {
        await coordinator.invalidate(mutation.affectedKeys)
    }
}
