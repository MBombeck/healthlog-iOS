import Foundation
@testable import HealthLog
import Testing

/// W5-3 (v0.12 W5a) — pins the pure period-over-period delta math behind the
/// per-metric Insights page caption: the temporal-midpoint window split, the
/// signed-percentage formatting, the polarity→sentiment rules, and the
/// self-suppression contract (nil → the caption renders nothing). Pure
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
            points: [point(10, daysAgo: 3), point(12, daysAgo: 1)],
            polarity: .neutral
        )
        #expect(result == nil)
    }

    @Test("Empty series → nil")
    func emptySeries() {
        #expect(MetricRangeDelta.resolve(points: [], polarity: .neutral) == nil)
    }

    @Test("A prior-half mean of zero → nil (no meaningful percentage)")
    func zeroPriorMean() {
        // Prior half straddles zero to a 0 mean; current half positive.
        let result = MetricRangeDelta.resolve(
            points: [
                point(-5, daysAgo: 10), point(5, daysAgo: 9), // prior mean 0
                point(4, daysAgo: 2), point(6, daysAgo: 1)
            ],
            polarity: .neutral
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
            ],
            polarity: .neutral
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
            ],
            polarity: .neutral
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
            ],
            polarity: .higherIsBetter
        ))
        #expect(result.percent == 0)
        #expect(result.symbol == "minus")
        #expect(result.sentiment == .neutral)
    }

    // MARK: - Sentiment rules (polarity-aware, mirrors web)

    @Test("higherIsBetter: a rise is favourable, a fall adverse")
    func higherIsBetterSentiment() {
        #expect(MetricRangeDelta.sentiment(percent: 5, polarity: .higherIsBetter) == .favourable)
        #expect(MetricRangeDelta.sentiment(percent: -5, polarity: .higherIsBetter) == .adverse)
    }

    @Test("lowerIsBetter: a fall is favourable, a rise adverse")
    func lowerIsBetterSentiment() {
        #expect(MetricRangeDelta.sentiment(percent: -5, polarity: .lowerIsBetter) == .favourable)
        #expect(MetricRangeDelta.sentiment(percent: 5, polarity: .lowerIsBetter) == .adverse)
    }

    @Test("neutral polarity (incl. target-band metrics) is always neutral")
    func neutralSentiment() {
        #expect(MetricRangeDelta.sentiment(percent: 8, polarity: .neutral) == .neutral)
        #expect(MetricRangeDelta.sentiment(percent: -8, polarity: .neutral) == .neutral)
    }

    @Test("A near-zero delta is neutral regardless of polarity")
    func nearZeroNeutral() {
        #expect(MetricRangeDelta.sentiment(percent: 0.02, polarity: .higherIsBetter) == .neutral)
        #expect(MetricRangeDelta.sentiment(percent: -0.02, polarity: .lowerIsBetter) == .neutral)
    }

    @Test("Sentiment propagates into the resolved result")
    func resolvedSentiment() throws {
        // weight (lowerIsBetter) drops 10% → favourable.
        let result = try #require(MetricRangeDelta.resolve(
            points: [
                point(80, daysAgo: 30), point(80, daysAgo: 29),
                point(72, daysAgo: 2), point(72, daysAgo: 1)
            ],
            polarity: .lowerIsBetter
        ))
        #expect(result.sentiment == .favourable)
    }
}
