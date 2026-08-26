import Foundation
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Locks the `MetricSeriesProjection` contract — the kind-aware sample-to-
/// sparkline projection that landed in v0.5.4.3 HP-2 as the fourth fix for
/// the persistent operator-reported BP + Puls "tile renders value without
/// chart" regression.
///
/// **Why this suite exists when prior suites already covered BP hydration:**
/// the prior `DashboardStoreSparklineHydrationTests` ran the full
/// `refreshMetricStates` path against `MockURLProtocol`-wired wire-rows that
/// always paired correctly (identical timestamps on the two BP halves). The
/// real operator-device demo data did NOT — the unpaired DIA half (`systolic
/// == 0`) polluted the hydrated sparkline. This suite tests the projection
/// itself with mixed paired/unpaired inputs so the regression cannot slip
/// past the gate again on a future change.
@Suite("MetricSeriesProjection — kind-aware sample-to-sparkline projection")
struct MetricSeriesProjectionTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ secondsOffset: Double) -> Date {
        now.addingTimeInterval(secondsOffset)
    }

    private func bp(s: Double, d: Double, at date: Date) -> HealthLog.Measurement {
        HealthLog.Measurement(
            id: UUID().uuidString,
            kind: .bloodPressure,
            recordedAt: date,
            value: .bloodPressure(systolic: s, diastolic: d),
            source: .manual
        )
    }

    private func pulse(_ bpm: Double, at date: Date) -> HealthLog.Measurement {
        HealthLog.Measurement(
            id: UUID().uuidString,
            kind: .pulse,
            recordedAt: date,
            value: .scalar(bpm),
            source: .manual
        )
    }

    private func weight(_ kg: Double, at date: Date) -> HealthLog.Measurement {
        HealthLog.Measurement(
            id: UUID().uuidString,
            kind: .weight,
            recordedAt: date,
            value: .scalar(kg),
            source: .manual
        )
    }

    // MARK: - systolicOnly

    @Test("systolicOnly returns systolic components sorted ascending")
    func systolicOnlySorts() {
        let samples = [
            bp(s: 126, d: 82, at: at(-100)),
            bp(s: 122, d: 79, at: at(-200)),
            bp(s: 124, d: 81, at: at(-300))
        ]
        let result = MetricSeriesProjection.systolicOnly(samples)
        // Sorted asc by recordedAt → oldest first → 124, 122, 126.
        #expect(result == [124, 122, 126])
    }

    @Test("systolicOnly drops unpaired-DIA artifacts (systolic == 0)")
    func systolicOnlyDropsUnpairedDIA() {
        // The operator-real-device-bug fixture: when MeasurementAggregator
        // can't pair a BP_SYS with its BP_DIA peer (e.g. millisecond drift on
        // the two timestamps after a JSON round-trip), the unpaired DIA half
        // arrives as `.bloodPressure(systolic: 0, diastolic: d)`. Prior to
        // HP-2, `primaryComponent` returned 0 for these, polluting the
        // sparkline as `[124, 0, 122, 0]`.
        let samples = [
            bp(s: 124, d: 81, at: at(-300)),
            bp(s: 0, d: 79, at: at(-200)), // unpaired DIA — must be dropped
            bp(s: 126, d: 82, at: at(-100))
        ]
        let result = MetricSeriesProjection.systolicOnly(samples)
        #expect(result == [124, 126], "Unpaired-DIA row with systolic == 0 must be dropped")
    }

    @Test("systolicOnly handles all-unpaired input by returning empty")
    func systolicOnlyAllUnpaired() {
        let samples = [
            bp(s: 0, d: 79, at: at(-200)),
            bp(s: 0, d: 82, at: at(-100))
        ]
        let result = MetricSeriesProjection.systolicOnly(samples)
        #expect(result.isEmpty, "All-unpaired input must yield empty array (renders no-chart placeholder)")
    }

    @Test("systolicOnly handles empty input")
    func systolicOnlyEmpty() {
        #expect(MetricSeriesProjection.systolicOnly([]).isEmpty)
    }

    // MARK: - heartRate

    @Test("heartRate returns pulse values sorted ascending")
    func heartRateSorts() {
        let samples = [
            pulse(74, at: at(-100)),
            pulse(67, at: at(-300)),
            pulse(75, at: at(-200))
        ]
        let result = MetricSeriesProjection.heartRate(samples)
        // Sorted asc by recordedAt → 67 (oldest), 75, 74 (newest).
        #expect(result == [67, 75, 74])
    }

    @Test("heartRate filters non-positive defensive values")
    func heartRateFiltersNonPositive() {
        let samples = [
            pulse(74, at: at(-100)),
            pulse(0, at: at(-200)), // defensive — should never happen but guard anyway
            pulse(-1, at: at(-300)), // same
            pulse(67, at: at(-400))
        ]
        let result = MetricSeriesProjection.heartRate(samples)
        #expect(result == [67, 74], "Non-positive pulse readings must be filtered")
    }

    // MARK: - Dedup contract

    @Test("dedupAndSort collapses same-timestamp duplicates (last-wins)")
    func dedupSameTimestamp() {
        // SWR stale-then-fresh race can briefly surface the same reading
        // twice during revalidation. Dedup-by-recordedAt collapses the
        // duplicate before the chart sees it.
        let date = at(-100)
        let samples = [
            pulse(70, at: date),
            pulse(72, at: date), // same timestamp — replaces
            pulse(74, at: at(-50))
        ]
        let result = MetricSeriesProjection.dedupAndSort(samples)
        #expect(result.count == 2, "Same-timestamp rows must collapse to one")
        // Last-wins → 72 + 74.
        #expect(result.map(\.value.primaryComponent) == [72, 74])
    }

    // MARK: - project (dispatch)

    @Test("project dispatches BP through systolicOnly")
    func projectBPRoutesToSystolicOnly() {
        let samples = [
            bp(s: 0, d: 79, at: at(-200)), // unpaired — must be dropped
            bp(s: 124, d: 81, at: at(-300)),
            bp(s: 126, d: 82, at: at(-100))
        ]
        let projected = MetricSeriesProjection.project(samples, kind: .bloodPressure)
        let direct = MetricSeriesProjection.systolicOnly(samples)
        #expect(projected == direct, "project(_:kind: .bloodPressure) must equal systolicOnly")
        #expect(projected == [124, 126])
    }

    @Test("project dispatches pulse + restingHeartRate through heartRate")
    func projectHeartRatesRoutesToHeartRate() {
        let samples = [
            pulse(74, at: at(-100)),
            pulse(67, at: at(-200))
        ]
        #expect(MetricSeriesProjection.project(samples, kind: .pulse) == [67, 74])
        #expect(MetricSeriesProjection.project(samples, kind: .restingHeartRate) == [67, 74])
    }

    @Test("project default kind routes through primaryComponent")
    func projectDefaultKindRoutesToDefault() {
        let samples = [
            weight(72.4, at: at(-100)),
            weight(72.0, at: at(-200))
        ]
        let projected = MetricSeriesProjection.project(samples, kind: .weight)
        #expect(projected == [72.0, 72.4])
    }

    // MARK: - Regression guards

    @Test("BP projection over realistic demo-tenant fixture renders 4-point chart")
    func demoTenantBPFixtureRenders() {
        // Mirrors the live demo.healthlog.dev BP payload (2026-05-18 capture):
        // 4 paired readings spanning 3 days. The chart must paint with all 4.
        let samples = [
            bp(s: 124, d: 81, at: at(-86400 * 3)),
            bp(s: 113, d: 79, at: at(-86400 * 2)),
            bp(s: 126, d: 82, at: at(-86400)),
            bp(s: 122, d: 76, at: at(-3600))
        ]
        let result = MetricSeriesProjection.systolicOnly(samples)
        #expect(result == [124, 113, 126, 122], "Demo-tenant BP must yield 4-point sparkline")
    }

    @Test("Pulse projection over realistic demo-tenant fixture renders 4-point chart")
    func demoTenantPulseFixtureRenders() {
        let samples = [
            pulse(69, at: at(-86400 * 3)),
            pulse(67, at: at(-86400 * 2)),
            pulse(75, at: at(-86400)),
            pulse(74, at: at(-3600))
        ]
        let result = MetricSeriesProjection.heartRate(samples)
        #expect(result == [69, 67, 75, 74])
    }
}
