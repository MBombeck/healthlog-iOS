import Foundation
@testable import HealthLog
import Testing

/// #136 (server v1.43, #116 item 6) — mood patterns from the server, rendered
/// only. Fixture shape: `MoodPattern` / `MoodAggregates.patterns` in
/// `docs/api/openapi.yaml` at `MBombeck/HealthLog` tag `v1.43.0`
/// (`2f5c4659f`); the sentences mirror the web's `insights.mood.patterns.*`.
@Suite("#136 — mood patterns from the server")
struct MoodPatternsV143Tests {
    private let decoder = JSONDecoder.hlDefault
    private let german = Locale(identifier: "de_DE")

    private static let insightsV143 = """
    { "betterDays": [],
      "patterns": [
        { "id": "weekend", "kind": "weekend", "strength": "strong", "direction": "higher",
          "values": { "subject": 7.4, "comparison": 6.1, "delta": 1.3 },
          "sampleSize": { "subject": 30, "comparison": 74 } },
        { "id": "best_weekday", "kind": "best_weekday", "strength": "moderate", "direction": "higher",
          "values": { "subject": 7.8, "comparison": 6.4, "delta": 1.4, "weekday": 5 },
          "sampleSize": { "subject": 15, "comparison": 89 } },
        { "id": "delayed_tag:alcohol", "kind": "delayed_tag", "strength": "weak", "direction": "lower",
          "values": { "subject": 5.2, "comparison": 6.6, "delta": -1.4, "tagKey": "alcohol", "tagLabel": "Alkohol" },
          "sampleSize": { "subject": 9, "comparison": 80 } },
        { "id": "lunar", "kind": "lunar_phase", "strength": "strong", "direction": "higher",
          "values": { "subject": 7, "comparison": 6, "delta": 1 }, "sampleSize": { "subject": 8, "comparison": 8 } },
        { "id": "broken" }
      ] }
    """

    private func response(_ json: String) throws -> MoodRelationsResponse {
        try decoder.decode(MoodRelationsResponse.self, from: Data(json.utf8))
    }

    @Test("A v1.43 answer carries its patterns in order; an unreadable row is dropped on its own")
    func decodesPatterns() throws {
        let patterns = try #require(try response(Self.insightsV143).patterns)
        #expect(patterns.map(\.id) == ["weekend", "best_weekday", "delayed_tag:alcohol", "lunar"])
        #expect(patterns[0].kind == .weekend && patterns[0].strength == .strong && patterns[0].direction == .higher)
        #expect(patterns[1].values.weekday == 5)
        #expect(patterns[2].values.tagLabel == "Alkohol")
        #expect(patterns[2].sampleSize == MoodPattern.SampleSize(subject: 9, comparison: 80))
        #expect(patterns[3].kind == .unknown, "an unknown kind decodes, the presentation skips it")
    }

    @Test("Older server: no patterns at all; an empty list is the server's \"none found\"")
    func olderAndEmpty() throws {
        #expect(try response(#"{ "betterDays": [] }"#).patterns == nil)
        #expect(try response(#"{ "betterDays": [], "patterns": [] }"#).patterns == [])
        #expect(try response(#"{ "betterDays": [], "patterns": null }"#).patterns == nil)
        #expect(try response(#"{ "betterDays": [], "patterns": "soon" }"#).patterns == nil)
    }

    @Test("The patterns survive the SWR cache round trip")
    func roundTrip() throws {
        let decoded = try response(Self.insightsV143)
        let again = try decoder.decode(MoodRelationsResponse.self, from: JSONEncoder.hlDefault.encode(decoded))
        #expect(again.patterns == decoded.patterns)
    }

    @Test("One card per phrasable entry, in the order delivered; the unknown kind is skipped")
    func cards() throws {
        let patterns = try #require(try response(Self.insightsV143).patterns)
        let cards = MoodPatternPresentation.cards(for: patterns, locale: german)
        #expect(cards.map(\.id) == ["weekend", "best_weekday", "delayed_tag:alcohol"])
        #expect(cards[0].basedOn == String(localized: "mood.patterns.days \(30) \(74)"))
        #expect(cards[0].strength == String(localized: "mood.patterns.strength.strong"))
        // 1.4 B2 — strength and basis share the chip; no sentence under the row.
        #expect(cards[0].chip == "\(String(localized: "mood.patterns.strength.strong")), \(cards[0].basedOn)")
        #expect(cards[0].chip.contains("30") && cards[0].chip.contains("74"))
    }

    @Test("The sentence carries the server's two averages, the weekday and the tag, nothing computed")
    func sentences() throws {
        let patterns = try #require(try response(Self.insightsV143).patterns)
        let weekend = try #require(MoodPatternPresentation.sentence(for: patterns[0], locale: german))
        #expect(weekend == String(localized: "mood.patterns.weekendHigher \("7,4") \("6,1")"))
        let best = try #require(MoodPatternPresentation.sentence(for: patterns[1], locale: german))
        #expect(best.contains("Samstag"), "weekday 5 is Saturday (0 = Monday)")
        let tag = try #require(MoodPatternPresentation.sentence(for: patterns[2], locale: german))
        #expect(tag == String(localized: "mood.patterns.delayedTagLower \("Alkohol") \("5,2") \("6,6")"))
    }

    @Test("The analysis keeps contiguous section indices with and without the patterns")
    func sectionIndices() {
        #expect(MoodPatternSection.recentSectionIndex(hasPatterns: false) == 5)
        #expect(MoodPatternSection.recentSectionIndex(hasPatterns: true) == 6)
    }

    @Test("Entries the app cannot phrase are skipped: direction none, a lower best weekday, a tag without a name")
    func unphrasable() {
        let values = MoodPattern.Values(subject: 6, comparison: 5, delta: 1)
        let size = MoodPattern.SampleSize(subject: 8, comparison: 8)
        let none = MoodPattern(id: "notes", kind: .notes, strength: .weak, direction: .none, values: values, sampleSize: size)
        let lowerBest = MoodPattern(
            id: "best_weekday", kind: .bestWeekday, strength: .weak, direction: .lower,
            values: MoodPattern.Values(subject: 5, comparison: 6, delta: -1, weekday: 2), sampleSize: size
        )
        let namelessTag = MoodPattern(
            id: "delayed_tag:x",
            kind: .delayedTag,
            strength: .weak,
            direction: .higher,
            values: values,
            sampleSize: size
        )
        let unknownStrength = MoodPattern(
            id: "notes",
            kind: .notes,
            strength: .unknown,
            direction: .higher,
            values: values,
            sampleSize: size
        )
        #expect(MoodPatternPresentation.cards(for: [none, lowerBest, namelessTag]).isEmpty)
        #expect(MoodPatternPresentation.card(for: unknownStrength)?.strength == nil)
        #expect(MoodPatternPresentation.weekdayName(7, locale: german) == nil)
        #expect(MoodPatternPresentation.weekdayName(0, locale: german) == "Montag")
    }
}
