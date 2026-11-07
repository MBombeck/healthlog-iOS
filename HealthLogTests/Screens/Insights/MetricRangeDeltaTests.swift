import Foundation
@testable import HealthLog
import Testing

/// W5-3 (v0.12 W5a) — pins the pure period-over-period delta math behind the
/// per-metric Insights page caption: the temporal-midpoint window split, the
/// signed-percentage formatting, the server's change with its verdict (1.5
/// VERDICTS), and the self-suppression contract (nil → the caption renders nothing). Pure
/// `nonisolated static` logic, no SwiftUI host.
@Suite("Metric range delta")
struct MetricRangeDeltaTests {
    /// Build a point `daysAgo` days before a fixed reference instant so the
    /// resolver's midpoint split is deterministic.
    private func point(_ value: Double, daysAgo: Double) -> SeriesPoint {
        let reference = Date(timeIntervalSince1970: 1_700_000_000)
        return SeriesPoint(
            id: "\(daysAgo)-\(value)",
            at: reference.addingTimeInterval(-daysAgo * 86400),
            value: value,
            secondary: nil
        )
    }

    // MARK: - Self-suppression (no coherent prior window)

    @Test("Fewer than four points → nil (self-suppress)")
    func tooFewPoints() {
        let result = MetricRangeDelta.resolve(
            points: [point(10, daysAgo: 3), point(12, daysAgo: 1)]
        )
        #expect(result == nil)
    }

    @Test("Empty series → nil")
    func emptySeries() {
        #expect(MetricRangeDelta.resolve(points: []) == nil)
    }

    @Test("A prior-half mean of zero → nil (no meaningful percentage)")
    func zeroPriorMean() {
        // Prior half straddles zero to a 0 mean; current half positive.
        let result = MetricRangeDelta.resolve(
            points: [
                point(-5, daysAgo: 10), point(5, daysAgo: 9), // prior mean 0
                point(4, daysAgo: 2), point(6, daysAgo: 1)
            ]
        )
        #expect(result == nil)
    }

    // MARK: - Sign + magnitude

    @Test("A rise renders +pct with an up arrow")
    func positiveDelta() throws {
        // Prior mean 100, current mean 110 → +10%.
        let result = try #require(MetricRangeDelta.resolve(
            points: [
                point(100, daysAgo: 30), point(100, daysAgo: 29),
                point(110, daysAgo: 2), point(110, daysAgo: 1)
            ]
        ))
        #expect(result.percent == 10)
        #expect(result.symbol == "arrow.up")
        #expect(result.deltaText.hasPrefix("+"))
        #expect(result.deltaText.contains("10"))
    }

    @Test("A fall renders a minus-sign pct with a down arrow")
    func negativeDelta() throws {
        // Prior mean 80, current mean 72 → -10%.
        let result = try #require(MetricRangeDelta.resolve(
            points: [
                point(80, daysAgo: 30), point(80, daysAgo: 29),
                point(72, daysAgo: 2), point(72, daysAgo: 1)
            ]
        ))
        #expect(result.percent == -10)
        #expect(result.symbol == "arrow.down")
        // Uses the typographic minus (U+2212), not ASCII hyphen.
        #expect(result.deltaText.contains("\u{2212}"))
    }

    @Test("An equal prior/current mean reads as flat (neutral, minus glyph)")
    func flatDelta() throws {
        let result = try #require(MetricRangeDelta.resolve(
            points: [
                point(50, daysAgo: 30), point(50, daysAgo: 29),
                point(50, daysAgo: 2), point(50, daysAgo: 1)
            ]
        ))
        #expect(result.percent == 0)
        #expect(result.symbol == "minus")
        #expect(result.sentiment == .neutral)
    }

    // MARK: - Colour (1.5 VERDICTS — the server's change and verdict, or neutral)

    @Test("The own comparison (server before v1.43) is never tinted good or bad")
    func ownComparisonIsNeutral() throws {
        for values in [[80.0, 80, 72, 72], [72.0, 72, 80, 80]] {
            let result = try #require(MetricRangeDelta.resolve(points: [
                point(values[0], daysAgo: 30), point(values[1], daysAgo: 29),
                point(values[2], daysAgo: 2), point(values[3], daysAgo: 1)
            ]))
            #expect(result.sentiment == .neutral)
            #expect(result.percent != nil)
        }
    }

    @Test("The server's change shows its own delta in the unit, not a percentage")
    func serverChangeValue() throws {
        let result = try #require(MetricRangeDelta.resolve(serverDelta: -0.6, unit: "kg", sentiment: .positive))
        #expect(result.deltaText == "\u{2212}" + 0.6.formatted(.number.precision(.fractionLength(0 ... 1))) + " kg")
        #expect(result.symbol == "arrow.down")
        #expect(result.percent == nil)
        #expect(result.sentiment == .favourable)
        let flat = try #require(MetricRangeDelta.resolve(serverDelta: 0.01, unit: "kg", sentiment: .neutral))
        #expect(flat.symbol == "minus")
        #expect(flat.sentiment == .neutral)
        #expect(MetricRangeDelta.resolve(serverDelta: .nan, unit: "kg", sentiment: .positive) == nil)
    }

    @Test("The server's verdict colours: negative adverse, positive favourable, neutral and unknown nothing")
    func serverChangeColour() throws {
        func sentiment(_ verdict: TrendSentiment) throws -> MetricRangeDelta.Sentiment {
            try #require(MetricRangeDelta.resolve(serverDelta: 4, unit: "bpm", sentiment: verdict)).sentiment
        }
        #expect(try sentiment(.negative) == .adverse)
        #expect(try sentiment(.positive) == .favourable)
        #expect(try sentiment(.neutral) == .neutral)
        #expect(try sentiment(.unknown) == .neutral)
    }

    @Test("Rising steps are no longer amber: a positive verdict on a rise reads favourable")
    func risingStepsNotAmber() throws {
        let steps = try #require(MetricRangeDelta.resolve(.server(delta: 1200, unit: "", sentiment: .positive)))
        #expect(steps.sentiment == .favourable)
        #expect(steps.symbol == "arrow.up")
        #expect(HeroDeltaChip.colorRole(for: .positive) == .statusOK)
        #expect(HeroDeltaChip.colorRole(for: nil) == .textSecondary)
        #expect(HeroDeltaChip.colorRole(for: .neutral) == .textSecondary)
        #expect(HeroDeltaChip.colorRole(for: .negative) == .statusBad)
    }
}
