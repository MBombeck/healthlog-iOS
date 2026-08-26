import Foundation
@testable import HealthLog
import Testing

/// F2 (PB5 review): `MetricDisplay` is the single projection driving the
/// value-text + secondary-line rendering for every dashboard card.
///
/// These tests pin the projection contract directly so cards stay aligned.
@Suite("MetricDisplay — layout-agnostic dataState projection")
struct MetricDisplayTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeMetric(
        kind: MetricKind,
        latest: Double? = nil,
        secondary: Double? = nil
    ) -> DashboardMetric {
        DashboardMetric(
            id: kind.rawValue,
            kind: kind,
            title: kind.rawValue,
            latestValue: latest,
            secondaryValue: secondary,
            unit: "",
            trend: .flat,
            sparkline: [],
            updatedAt: nil
        )
    }

    private func sample(kind: MetricKind, value: Double, daysAgo: Int = 1) -> HealthLog.Measurement {
        HealthLog.Measurement(
            id: UUID().uuidString,
            kind: kind,
            recordedAt: now.addingTimeInterval(-Double(daysAgo) * 86400),
            value: .scalar(value),
            source: .manual
        )
    }

    // MARK: - .ready states — happy paths

    @Test("ready scalar → value formatted, no secondary line, not empty")
    func readyScalarPulse() {
        let metric = makeMetric(kind: .pulse, latest: 64)
        let latest = sample(kind: .pulse, value: 64)
        let display = MetricDisplay(metric: metric, dataState: .ready(latest: latest, samples: [latest]), now: now)
        #expect(display.valueText == "64")
        #expect(display.secondaryLine == nil)
        #expect(display.isEmptyForDisplay == false)
    }

    @Test("ready BP composite → systolic/diastolic, no secondary line")
    func readyBPCompositeWired() {
        let metric = makeMetric(kind: .bloodPressure, latest: 124, secondary: 81)
        let latest = HealthLog.Measurement(
            id: "bp",
            kind: .bloodPressure,
            recordedAt: now,
            value: .bloodPressure(systolic: 124, diastolic: 81),
            source: .manual
        )
        let display = MetricDisplay(metric: metric, dataState: .ready(latest: latest, samples: [latest]), now: now)
        #expect(display.valueText == "124/81")
        #expect(display.secondaryLine == nil)
        #expect(display.isEmptyForDisplay == false)
    }

    @Test("ready BP composite missing diastolic → em-dash + Noch keine Daten")
    func readyBPCompositeHalfLoaded() {
        // The dashboard summary endpoint can deliver only the systolic half
        // while the diastolic peer is still in flight. PA4 #8 — the
        // composite should render the placeholder until both peers land.
        let metric = makeMetric(kind: .bloodPressure, latest: 124, secondary: nil)
        let onlySys = HealthLog.Measurement(
            id: "bp",
            kind: .bloodPressure,
            recordedAt: now,
            value: .bloodPressure(systolic: 124, diastolic: 0),
            source: .manual
        )
        let display = MetricDisplay(metric: metric, dataState: .ready(latest: onlySys, samples: [onlySys]), now: now)
        #expect(display.valueText == "—")
        #expect(display.secondaryLine == String(localized: "No data yet"))
        #expect(display.isEmptyForDisplay == true)
    }

    @Test("ready scalar with stale sample → visible recency line (AUDIT-HOME M5)")
    func readyScalarStaleCarriesRecencyLine() {
        let metric = makeMetric(kind: .weight, latest: 72.4)
        // Calendar-precise (not seconds-based) so a DST boundary inside the
        // window can't shave the day-count to 20.
        let latestAt = Calendar.current.date(byAdding: .day, value: -21, to: now) ?? now
        let latest = HealthLog.Measurement(
            id: "stale-weight",
            kind: .weight,
            recordedAt: latestAt,
            value: .scalar(72.4),
            source: .manual
        )
        let display = MetricDisplay(metric: metric, dataState: .ready(latest: latest, samples: [latest]), now: now)
        #expect(display.isEmptyForDisplay == false)
        #expect(
            display.secondaryLine?.contains("21") == true,
            "Stale ready value should carry a 21-day recency hint, got \(display.secondaryLine ?? "nil")"
        )
    }

    @Test("ready scalar just under the 7-day threshold → no recency line")
    func readyScalarFreshEnoughStaysClean() {
        let metric = makeMetric(kind: .weight, latest: 72.4)
        let latest = sample(kind: .weight, value: 72.4, daysAgo: MetricDisplay.recencyHintThresholdDays - 1)
        let display = MetricDisplay(metric: metric, dataState: .ready(latest: latest, samples: [latest]), now: now)
        #expect(display.secondaryLine == nil)
    }

    @Test("recencyLine clamps clock-skewed future timestamps to nil (F7 guard)")
    func recencyLineFutureClockClamps() {
        let futureAt = now.addingTimeInterval(86400 * 2)
        #expect(MetricDisplay.recencyLine(latestAt: futureAt, now: now) == nil)
    }

    // MARK: - .empty states — three reasons

    @Test("empty .noData → em-dash + Noch keine Daten")
    func emptyNoData() {
        let metric = makeMetric(kind: .weight)
        let display = MetricDisplay(metric: metric, dataState: .empty(reason: .noData))
        #expect(display.valueText == "—")
        #expect(display.secondaryLine == String(localized: "No data yet"))
        #expect(display.isEmptyForDisplay == true)
    }

    @Test("empty .outsideRange → em-dash + Letzte Messung vor X Tagen")
    func emptyOutsideRange() {
        let metric = makeMetric(kind: .weight)
        let latestAt = Date.now.addingTimeInterval(-86400 * 60) // 60 days ago
        let display = MetricDisplay(metric: metric, dataState: .empty(reason: .outsideRange(latestAt: latestAt)))
        #expect(display.valueText == "—")
        #expect(
            display.secondaryLine?.contains("60") == true,
            "Secondary line should mention 60 days, got \(display.secondaryLine ?? "nil")"
        )
        #expect(display.isEmptyForDisplay == true)
    }

    @Test("empty .outsideRange clamps negative day-count to 0 (F7)")
    func emptyOutsideRangeFutureClock() {
        // Defensive: HK background-delivery race / manual entry can yield a
        // future timestamp. The label must never read "vor -2 Tagen".
        let metric = makeMetric(kind: .weight)
        let futureAt = Date.now.addingTimeInterval(86400 * 2) // 2 days in the future
        let display = MetricDisplay(metric: metric, dataState: .empty(reason: .outsideRange(latestAt: futureAt)))
        #expect(display.valueText == "—")
        #expect(display.secondaryLine?.contains("-") == false, "Day count must not be negative, got \(display.secondaryLine ?? "nil")")
    }

    @Test("empty .sourceFiltered → em-dash + Keine Messungen für die gewählte Quelle")
    func emptySourceFiltered() {
        let metric = makeMetric(kind: .weight)
        let display = MetricDisplay(metric: metric, dataState: .empty(reason: .sourceFiltered))
        #expect(display.valueText == "—")
        #expect(display.secondaryLine == String(localized: "No measurements for the selected source"))
        #expect(display.isEmptyForDisplay == true)
    }

    // MARK: - .unknown / .loading — first-paint fallthrough

    @Test("unknown with summary value → falls back to formattedPrimary")
    func unknownFallsBackToSummary() {
        let metric = makeMetric(kind: .pulse, latest: 72)
        let display = MetricDisplay(metric: metric, dataState: .unknown)
        #expect(display.valueText == "72")
        #expect(display.secondaryLine == nil)
        #expect(display.isEmptyForDisplay == false)
    }

    @Test("loading with no summary value → em-dash, marked empty")
    func loadingNoSummary() {
        let metric = makeMetric(kind: .pulse, latest: nil)
        let display = MetricDisplay(metric: metric, dataState: .loading)
        #expect(display.valueText == "—")
        #expect(display.isEmptyForDisplay == true)
    }

    @Test("unknown BP composite missing diastolic → em-dash even with sys present")
    func unknownBPHalfLoaded() {
        let metric = makeMetric(kind: .bloodPressure, latest: 124, secondary: nil)
        let display = MetricDisplay(metric: metric, dataState: .unknown)
        #expect(display.valueText == "—")
        #expect(display.isEmptyForDisplay == true)
    }
}
