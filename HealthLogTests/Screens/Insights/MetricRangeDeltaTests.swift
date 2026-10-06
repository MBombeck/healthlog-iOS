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
            sentiment: nil
        )
        #expect(result == nil)
    }

    @Test("Empty series → nil")
    func emptySeries() {
        #expect(MetricRangeDelta.resolve(points: [], sentiment: nil) == nil)
    }

    @Test("A prior-half mean of zero → nil (no meaningful percentage)")
    func zeroPriorMean() {
        // Prior half straddles zero to a 0 mean; current half positive.
        let result = MetricRangeDelta.resolve(
            points: [
                point(-5, daysAgo: 10), point(5, daysAgo: 9), // prior mean 0
                point(4, daysAgo: 2), point(6, daysAgo: 1)
            ],
            sentiment: nil
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
            sentiment: nil
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
            sentiment: nil
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
            sentiment: nil
        ))
        #expect(result.percent == 0)
        #expect(result.symbol == "minus")
        #expect(result.sentiment == .neutral)
    }

    // MARK: - Sentiment rules (#115 · 1.3 — the server's verdict or none)

    @Test("no server verdict: a rise or a fall is never tinted good or bad")
    func noVerdictIsNeutral() {
        #expect(MetricRangeDelta.sentiment(percent: 5, server: nil) == .neutral)
        #expect(MetricRangeDelta.sentiment(percent: -5, server: nil) == .neutral)
    }

    @Test("server up-good: a rise is favourable, a fall adverse")
    func upGoodVerdict() {
        #expect(MetricRangeDelta.sentiment(percent: 5, server: .upGood) == .favourable)
        #expect(MetricRangeDelta.sentiment(percent: -5, server: .upGood) == .adverse)
    }

    @Test("server up-bad: a fall is favourable, a rise adverse")
    func upBadVerdict() {
        #expect(MetricRangeDelta.sentiment(percent: -5, server: .upBad) == .favourable)
        #expect(MetricRangeDelta.sentiment(percent: 5, server: .upBad) == .adverse)
    }

    @Test("server hold: level is progress, a move either way is neutral")
    func holdVerdict() {
        #expect(MetricRangeDelta.sentiment(percent: 0.02, server: .hold) == .favourable)
        #expect(MetricRangeDelta.sentiment(percent: 8, server: .hold) == .neutral)
        #expect(MetricRangeDelta.sentiment(percent: -8, server: .hold) == .neutral)
    }

    @Test("a weight loss without a server verdict is not called favourable any more")
    func weightLossWithoutVerdictIsNeutral() throws {
        // Before #115 the caption read weight as lower-is-better for everyone,
        // so someone below their target saw a loss coloured as progress.
        let result = try #require(MetricRangeDelta.resolve(
            points: [
                point(80, daysAgo: 30), point(80, daysAgo: 29),
                point(72, daysAgo: 2), point(72, daysAgo: 1)
            ],
            sentiment: nil
        ))
        #expect(result.sentiment == .neutral)
        let belowTarget = try #require(MetricRangeDelta.resolve(
            points: [
                point(80, daysAgo: 30), point(80, daysAgo: 29),
                point(72, daysAgo: 2), point(72, daysAgo: 1)
            ],
            sentiment: .upGood
        ))
        #expect(belowTarget.sentiment == .adverse)
    }
}
