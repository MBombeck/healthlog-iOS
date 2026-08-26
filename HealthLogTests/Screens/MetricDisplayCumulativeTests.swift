import Foundation
@testable import HealthLog
import Testing

/// **V0.5.4-BF-3 regression guard.** Cumulative kinds (Steps; future
/// active-energy / flights / distance / time-in-daylight tiles when their
/// `MetricKind` cases land) must display today's day-cumulative sum on
/// the tile value, not the latest single sample. Operator-reported v0.5.3
/// bug: "Schritte zeigt nicht den Tagesgesamtwert" — `latest.primaryValue`
/// on a HK setup that emits per-sample step rows landed as the most
/// recent batch's count, not the full day's cumulative.
@Suite("MetricDisplay — V0.5.4-BF-3 cumulative day-sum")
struct MetricDisplayCumulativeTests {
    /// Anchor "today" at noon so we have headroom for samples earlier in
    /// the day without crossing a calendar boundary at test time.
    private static let now: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 17
        components.hour = 12
        components.minute = 0
        return Calendar.current.date(from: components) ?? .now
    }()

    private static func stepSample(at: Date, value: Double) -> HealthLog.Measurement {
        HealthLog.Measurement(
            id: UUID().uuidString,
            kind: .steps,
            recordedAt: at,
            value: .scalar(value),
            source: .appleHealth
        )
    }

    private static func metric() -> DashboardMetric {
        DashboardMetric(
            id: "steps",
            kind: .steps,
            title: "Schritte",
            latestValue: nil,
            secondaryValue: nil,
            unit: "Schritte",
            trend: .up,
            sparkline: [],
            updatedAt: nil
        )
    }

    @Test("isCumulative is true for .steps")
    func stepsIsCumulative() {
        #expect(MetricKind.steps.isCumulative == true)
    }

    @Test("isCumulative is false for non-cumulative kinds (weight, BP, pulse, sleep)")
    func nonCumulativeKindsReturnFalse() {
        #expect(MetricKind.weight.isCumulative == false)
        #expect(MetricKind.bloodPressure.isCumulative == false)
        #expect(MetricKind.pulse.isCumulative == false)
        #expect(MetricKind.sleep.isCumulative == false)
        #expect(MetricKind.bodyFat.isCumulative == false)
    }

    @Test("cumulativeTodaySum sums every same-day sample")
    func sumsSameDaySamples() {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Self.now)
        let samples = [
            Self.stepSample(at: dayStart.addingTimeInterval(3 * 3600), value: 2400),
            Self.stepSample(at: dayStart.addingTimeInterval(7 * 3600), value: 3200),
            Self.stepSample(at: dayStart.addingTimeInterval(11 * 3600), value: 2600)
        ]
        let sum = MetricDisplay.cumulativeTodaySum(samples: samples, now: Self.now, calendar: calendar)
        #expect(sum == 8200)
    }

    @Test("cumulativeTodaySum ignores yesterday's samples")
    func ignoresYesterdaySamples() {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Self.now)
        let yesterdayNoon = dayStart.addingTimeInterval(-12 * 3600)
        let todayMorning = dayStart.addingTimeInterval(3 * 3600)
        let samples = [
            Self.stepSample(at: yesterdayNoon, value: 12345),
            Self.stepSample(at: todayMorning, value: 4321)
        ]
        let sum = MetricDisplay.cumulativeTodaySum(samples: samples, now: Self.now, calendar: calendar)
        #expect(sum == 4321)
    }

    @Test("cumulativeTodaySum returns nil when no same-day sample exists")
    func returnsNilWhenNoTodaySample() {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Self.now)
        let twoDaysAgo = dayStart.addingTimeInterval(-2 * 86400)
        let samples = [Self.stepSample(at: twoDaysAgo, value: 5000)]
        let sum = MetricDisplay.cumulativeTodaySum(samples: samples, now: Self.now, calendar: calendar)
        #expect(sum == nil)
    }

    @Test("MetricDisplay shows today's day-cumulative for .steps tile")
    func tileValueIsTodayCumulative() {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Self.now)
        let samples = [
            Self.stepSample(at: dayStart.addingTimeInterval(2 * 3600), value: 2100),
            Self.stepSample(at: dayStart.addingTimeInterval(8 * 3600), value: 3900)
        ]
        // "latest" by recordedAt is the second sample (3_900). Pre-BF-3
        // the tile rendered 3_900. Post-BF-3 it must render the day total
        // 6_000.
        guard let latest = samples.max(by: { $0.recordedAt < $1.recordedAt }) else {
            Issue.record("test fixture has no samples")
            return
        }
        let dataState: MetricDataState = .ready(latest: latest, samples: samples)
        let display = MetricDisplay(metric: Self.metric(), dataState: dataState, now: Self.now, calendar: calendar)
        // Schritte uses `.groupedInteger` formatting via the descriptor.
        // Strip every locale-grouping separator (NB-space, narrow NB-space,
        // dot, comma, regular space) so the test is locale-agnostic — the
        // bug we are guarding against is "tile renders 3900 instead of
        // 6000" and that's a digit-sequence check, not a glyph check.
        let digits = display.valueText
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "\u{202F}", with: "")
        #expect(digits == "6000", "Expected digit-sequence 6000, got \(display.valueText) (digits: \(digits))")
    }

    @Test("MetricDisplay falls back to latest.primaryValue when no today sample")
    func fallsBackToLatestWhenNoToday() {
        let calendar = Calendar.current
        let twoDaysAgo = calendar.startOfDay(for: Self.now).addingTimeInterval(-2 * 86400 + 3600)
        let onlyOldSample = Self.stepSample(at: twoDaysAgo, value: 7777)
        let dataState: MetricDataState = .ready(latest: onlyOldSample, samples: [onlyOldSample])
        let display = MetricDisplay(metric: Self.metric(), dataState: dataState, now: Self.now, calendar: calendar)
        #expect(
            display.valueText.contains("7777")
                || display.valueText.contains("7,777")
                || display.valueText.contains("7.777")
        )
    }

    @Test("Non-cumulative kind .weight still uses latest.primaryValue (no day-sum)")
    func weightTileUnchanged() {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Self.now)
        let s1 = HealthLog.Measurement(
            id: "1",
            kind: .weight,
            recordedAt: dayStart.addingTimeInterval(3 * 3600),
            value: .scalar(72.0),
            source: .manual
        )
        let s2 = HealthLog.Measurement(
            id: "2",
            kind: .weight,
            recordedAt: dayStart.addingTimeInterval(9 * 3600),
            value: .scalar(72.4),
            source: .manual
        )
        let dataState: MetricDataState = .ready(latest: s2, samples: [s1, s2])
        let metric = DashboardMetric(
            id: "weight",
            kind: .weight,
            title: "Gewicht",
            latestValue: nil,
            secondaryValue: nil,
            unit: "kg",
            trend: .flat,
            sparkline: [],
            updatedAt: nil
        )
        let display = MetricDisplay(metric: metric, dataState: dataState, now: Self.now, calendar: calendar)
        // Latest weight is 72.4 — the day-sum (144.4) would be nonsensical
        // for a non-cumulative metric. Pin that we don't accidentally
        // route weight through the sum path.
        #expect(display.valueText.contains("72") && !display.valueText.contains("144"))
    }
}
