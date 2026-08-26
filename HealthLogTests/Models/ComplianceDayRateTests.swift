import Foundation
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif
import Testing

/// **M4 (AUDIT-bugs b198)** — a day with zero scheduled doses is NOT 100 %
/// compliant. The old `rate` returned `1` for a 0/0 day, inflating every
/// rolling mean / heatmap aggregate and painting a false 100 % sparkline spike.
/// `rate` now returns `0` for a no-dose day, and the new `scheduledRate` returns
/// `nil` so averaging consumers exclude unscheduled days from the denominator.
@Suite("ComplianceDay.rate — no-dose day semantics (M4)")
struct ComplianceDayRateTests {
    private let day = Date(timeIntervalSince1970: 1_714_550_400)

    @Test("0 scheduled / 0 taken → rate 0 (not the old inflating 1)")
    func zeroScheduledRateIsZero() {
        let d = ComplianceDay(date: day, scheduled: 0, taken: 0)
        #expect(d.rate == 0)
    }

    @Test("0 scheduled → scheduledRate is nil (excluded from rolling means)")
    func zeroScheduledScheduledRateIsNil() {
        let d = ComplianceDay(date: day, scheduled: 0, taken: 0)
        #expect(d.scheduledRate == nil)
    }

    @Test("Full adherence → rate 1, scheduledRate 1")
    func fullAdherence() {
        let d = ComplianceDay(date: day, scheduled: 2, taken: 2)
        #expect(d.rate == 1)
        #expect(d.scheduledRate == 1)
    }

    @Test("Partial adherence → rate and scheduledRate agree")
    func partialAdherence() {
        let d = ComplianceDay(date: day, scheduled: 4, taken: 1)
        #expect(d.rate == 0.25)
        #expect(d.scheduledRate == 0.25)
    }

    @Test("Rolling mean over scheduledRate excludes a no-dose day (no inflation)")
    func rollingMeanExcludesNoDoseDay() {
        // Two real 50 % days + one no-dose day. The correct mean is 0.5, not
        // the pre-M4 (0.5 + 0.5 + 1.0) / 3 = 0.667 inflation.
        let days = [
            ComplianceDay(date: day, scheduled: 2, taken: 1),
            ComplianceDay(date: day.addingTimeInterval(86400), scheduled: 2, taken: 1),
            ComplianceDay(date: day.addingTimeInterval(2 * 86400), scheduled: 0, taken: 0)
        ]
        let rates = days.compactMap(\.scheduledRate)
        #expect(rates.count == 2)
        let mean = rates.reduce(0, +) / Double(rates.count)
        #expect(mean == 0.5)
    }

    /// QA-b198 Correctness-M-1 — the Insights aux-chart 30-day fallback mean
    /// (`InsightsAuxChartDetailScreen.aggregateRate30`) used `\.rate`, which
    /// folds a 0/0 no-dose day in as 0 and DEFLATES the aggregate (the mirror
    /// image of the M4 inflation). Pin both readings on the same data so the
    /// difference — and the reason the fallback now uses `scheduledRate` — is
    /// locked: `\.rate` deflates to 0.333, `scheduledRate` reports the true 0.5.
    @Test("Aux-chart fallback: scheduledRate avoids the no-dose deflation \\.rate causes")
    func auxFallbackMeanExcludesNoDoseDeflation() {
        let days = [
            ComplianceDay(date: day, scheduled: 2, taken: 1),
            ComplianceDay(date: day.addingTimeInterval(86400), scheduled: 2, taken: 1),
            ComplianceDay(date: day.addingTimeInterval(2 * 86400), scheduled: 0, taken: 0)
        ]
        let buggyMean = days.map(\.rate).reduce(0, +) / Double(days.count)
        #expect(abs(buggyMean - 1.0 / 3.0) < 1e-9) // (0.5 + 0.5 + 0) / 3 — deflated

        let fixedRates = days.compactMap(\.scheduledRate)
        let fixedMean = fixedRates.reduce(0, +) / Double(fixedRates.count)
        #expect(fixedMean == 0.5) // the true adherence over scheduled days
    }
}
