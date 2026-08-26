import Foundation
@testable import HealthLog
import Testing

/// **GH #83 / server v1.35.0 — "this score runs on a composition you chose".**
///
/// A 82 out of five self-chosen pillars is not the same statement as a 82 out
/// of eight. Wherever the number stands alone the surface has to say which of
/// the two it is, and the only honest source for that is the server's own
/// `configured` flag.
///
/// The rule these tests exist to hold is the one that is easy to break by
/// accident: **absence is not `false`.** An older server, or an older cached
/// snapshot cell, simply never said — and a surface that painted an untold flag
/// as a claim about the account would be inventing provenance. Every gate below
/// therefore asserts three states, not two: told-true, told-false, not-told.
@Suite("GH #83 — chosen-composition provenance", .serialized)
struct HealthScoreConfiguredProvenanceTests {
    private func decodeScore(_ json: String) throws -> HealthScore {
        try JSONDecoder().decode(HealthScore.self, from: Data(json.utf8))
    }

    // MARK: - The score payload

    @Test("healthScore.configured decodes beside composition")
    func decodesConfigured() throws {
        let score = try decodeScore("""
        {"score":82,"band":"green","delta":1,\
        "composition":["BLOOD_PRESSURE","SLEEP","FITNESS","LIPIDS","ACTIVITY"],"configured":true}
        """)
        #expect(score.configured == true)
        #expect(score.runsOnChosenComposition)
        #expect(score.composition?.count == 5)
    }

    @Test("an explicit false is carried as false")
    func decodesNotConfigured() throws {
        let score = try decodeScore(#"{"score":74,"band":"green","delta":null,"configured":false}"#)
        #expect(score.configured == false)
        #expect(!score.runsOnChosenComposition)
    }

    @Test("a payload that never mentions the flag stays nil — 'not told' is not 'not configured'")
    func absenceIsNotFalse() throws {
        let score = try decodeScore(#"{"score":74,"band":"yellow","delta":null}"#)
        #expect(score.configured == nil)
        // The gate the surfaces read must still be false: nothing is claimed.
        #expect(!score.runsOnChosenComposition)
    }

    @Test("a junk flag does not cost the whole score")
    func tolerantDecode() throws {
        let score = try decodeScore(#"{"score":61,"band":"yellow","delta":null,"configured":"yes"}"#)
        #expect(score.score == 61)
        #expect(score.configured == nil)
    }

    // MARK: - The daily digest (the payload behind the live Home hero)

    @Test("digest score carries the flag through, and absence stays absence")
    func digestCarriesFlag() throws {
        let configured = try JSONDecoder().decode(
            DailyDigest.Score.self,
            from: Data(#"{"value":82,"band":"green","delta":1,"configured":true}"#.utf8)
        )
        #expect(configured.runsOnChosenComposition)

        let untold = try JSONDecoder().decode(
            DailyDigest.Score.self,
            from: Data(#"{"value":82,"band":"green","delta":1}"#.utf8)
        )
        #expect(untold.configured == nil)
        #expect(!untold.runsOnChosenComposition)
    }

    // MARK: - The widget glance

    @Test("the widget glance mirrors the flag, never derives it")
    func glanceMirrors() throws {
        let told = try decodeScore(#"{"score":82,"band":"green","delta":null,"configured":true}"#)
        #expect(WidgetSnapshot.HealthScoreGlance.make(from: told)?.configured == true)

        // A rich composition alone must NOT make the glance claim provenance:
        // `configured` answers "narrower than this account's own defaults",
        // which no client can derive from a pillar list.
        let untold = try decodeScore("""
        {"score":82,"band":"green","delta":null,"composition":["SLEEP","ACTIVITY","LIPIDS"]}
        """)
        #expect(WidgetSnapshot.HealthScoreGlance.make(from: untold)?.configured == false)
    }

    @Test("a glance written by an older build decodes as 'not told'")
    func glanceBackCompatDecode() throws {
        let legacy = #"{"score":82,"band":"green","resolvedAt":760000000}"#
        let decoder = JSONDecoder()
        let glance = try decoder.decode(
            WidgetSnapshot.HealthScoreGlance.self,
            from: Data(legacy.utf8)
        )
        #expect(glance.score == 82)
        #expect(glance.configured == false)
    }

    @Test("the glance round-trips the flag through the App Group encoding")
    func glanceRoundTrip() throws {
        let glance = WidgetSnapshot.HealthScoreGlance(
            score: 82,
            band: "green",
            resolvedAt: Date(timeIntervalSince1970: 760_000_000),
            configured: true
        )
        let data = try JSONEncoder().encode(glance)
        let back = try JSONDecoder().decode(WidgetSnapshot.HealthScoreGlance.self, from: data)
        #expect(back == glance)
        #expect(back.configured)
    }
}
