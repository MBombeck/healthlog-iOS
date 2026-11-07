@testable import HealthLog
import Testing

/// **POLISH-B B8 (1.5, VERDICTS 6.4 and 9).** The server judges mood with
/// `tiles.directions["MOOD"]` of the dashboard snapshot (v1.43, `up-good`).
/// The mood card's trend glyph takes its colour from that verdict, the same
/// rule as the arrows on Today; without a verdict it stays one quiet colour.
@MainActor
@Suite("POLISH-B B8 — the mood trend glyph follows the server's verdict")
struct MoodVerdictGlyphTests {
    @Test("rising mood with up-good is favourable, falling adverse, steady quiet")
    func upGood() {
        #expect(MoodHeroSummary.glyphRole(direction: .up, verdict: .upGood) == .statusOK)
        #expect(MoodHeroSummary.glyphRole(direction: .down, verdict: .upGood) == .statusBad)
        #expect(MoodHeroSummary.glyphRole(direction: .stable, verdict: .upGood) == .textSecondary)
    }

    @Test("no verdict, an unknown verdict word or no trend: the quiet colour as in 1.4")
    func noVerdict() {
        #expect(MoodHeroSummary.glyphRole(direction: .up, verdict: nil) == .textSecondary)
        #expect(MoodHeroSummary.glyphRole(direction: .down, verdict: .unknown) == .textSecondary)
        #expect(MoodHeroSummary.glyphRole(direction: nil, verdict: .upGood) == .textSecondary)
        #expect(MoodHeroSummary.spokenVerdict(direction: .up, verdict: nil) == nil)
    }

    @Test("VoiceOver hears the verdict only when the glyph is coloured")
    func spoken() {
        #expect(MoodHeroSummary.spokenVerdict(direction: .up, verdict: .upGood) == TrendSentiment.positive.spokenClause)
        #expect(MoodHeroSummary.spokenVerdict(direction: .down, verdict: .upGood) == TrendSentiment.negative.spokenClause)
        #expect(MoodHeroSummary.spokenVerdict(direction: .stable, verdict: .upGood) == nil)
    }
}
