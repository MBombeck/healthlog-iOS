import Foundation
@testable import HealthLog
import Testing

/// v0.14.1 — pure-resolver locks for the mood-relations card views. No SwiftUI
/// render pass: these pin the signed-delta formatting, the metric channel
/// label/symbol map, the direction captions, and the confidence band words so
/// the honest, association-not-cause framing can never silently drift.
@Suite("MoodRelations view resolvers")
struct MoodRelationsViewResolverTests {
    // MARK: - Signed delta string

    @Test("Positive delta gets a + sign, negative a proper minus, one fraction digit")
    func deltaString() {
        #expect(MoodInfluenceRowView.deltaString(0.7).hasPrefix("+"))
        #expect(MoodInfluenceRowView.deltaString(-0.4).hasPrefix("\u{2212}")) // − U+2212
        // One fraction digit retained.
        #expect(MoodInfluenceRowView.deltaString(2.0).contains("2"))
    }

    // MARK: - Confidence band words

    @Test("Confidence band resolves to a distinct non-empty word per level")
    func confidenceLabels() {
        let high = MoodConfidencePill.label(for: .high)
        let medium = MoodConfidencePill.label(for: .medium)
        let low = MoodConfidencePill.label(for: .low)
        #expect(!high.isEmpty)
        #expect(!medium.isEmpty)
        #expect(!low.isEmpty)
        #expect(Set([high, medium, low]).count == 3)
    }

    // MARK: - Metric channel resolution

    @Test("Known better-days metric keys resolve to a label + an SF Symbol")
    func metricResolution() {
        for key in ["sleep", "steps", "pulse", "weight", "bloodPressureSystolic"] {
            #expect(!MoodBetterDayRowView.metricLabel(for: key).isEmpty)
            let symbol = MoodBetterDayRowView.metricSymbol(for: key)
            #expect(!symbol.isEmpty)
            #expect(symbol != "tag")
        }
    }

    @Test("An unknown metric key falls back to a de-snaked label + a neutral chart glyph")
    func metricFallback() {
        #expect(MoodBetterDayRowView.metricLabel(for: "FUTURE_CHANNEL").contains("future"))
        #expect(MoodBetterDayRowView.metricSymbol(for: "FUTURE_CHANNEL") == "chart.xyaxis.line")
    }

    // MARK: - Direction captions (descriptive, never causal)

    @Test("Direction caption is association-framed up vs down and the two differ")
    func directionCaptions() {
        let up = BetterDayFactor(source: .tag, key: "x", direction: .up, n: 9, confidence: .medium, delta: 0.6)
        let down = BetterDayFactor(source: .tag, key: "y", direction: .down, n: 9, confidence: .low, delta: -0.6)
        let upCaption = MoodBetterDayRowView.directionCaption(for: up)
        let downCaption = MoodBetterDayRowView.directionCaption(for: down)
        #expect(!upCaption.isEmpty)
        #expect(upCaption != downCaption)
        // No causal verbs — descriptive "tends to go with" framing only.
        #expect(!upCaption.lowercased().contains("improve"))
        #expect(!upCaption.lowercased().contains("verbessert"))
    }
}
