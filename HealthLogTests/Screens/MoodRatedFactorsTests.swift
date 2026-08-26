import Foundation
@testable import HealthLog
import Testing

/// v0.14.1 §7 — Mood v2 rated factors (server v1.12.0 ingestion contract).
/// Covers the additive `MoodTag.kind`/`scale`/`inverse` decode, the RATED
/// detection the picker branches on, the client-side scale clamp, and the
/// `MoodEntryPatch` wire encoding (omit empty `ratedFactors`).
@Suite("Mood v2 rated factors")
struct MoodRatedFactorsTests {
    // MARK: - Catalog decode (additive, backward compatible)

    @Test("A tag without the v2 fields decodes as a BINARY tag")
    func legacyTagDecodesAsBinary() throws {
        let json = #"{ "key": "happy", "labelKey": "mood.tag.happy", "icon": "Smile" }"#
        let tag = try JSONDecoder().decode(MoodTagDTO.self, from: Data(json.utf8))
        #expect(tag.kind == .binary)
        #expect(!tag.isRated)
        #expect(tag.scaleMin == 1)
        #expect(tag.scaleMax == 5)
        #expect(!tag.inverse)
    }

    @Test("A RATED factor decodes its kind + scale + inverse")
    func ratedFactorDecodes() throws {
        let json = """
        { "key": "factor_stress", "labelKey": "mood.tag.factorStress", "icon": "Zap",
          "kind": "RATED", "scaleMin": 1, "scaleMax": 5, "inverse": true }
        """
        let tag = try JSONDecoder().decode(MoodTagDTO.self, from: Data(json.utf8))
        #expect(tag.kind == .rated)
        #expect(tag.isRated)
        #expect(tag.scaleMin == 1)
        #expect(tag.scaleMax == 5)
        #expect(tag.inverse)
    }

    @Test("A two-point factor (conflict) decodes scale 1..2")
    func twoPointFactorDecodes() throws {
        let json = """
        { "key": "factor_conflict", "labelKey": "mood.tag.factorConflict", "icon": "Swords",
          "kind": "RATED", "scaleMin": 1, "scaleMax": 2, "inverse": true }
        """
        let tag = try JSONDecoder().decode(MoodTagDTO.self, from: Data(json.utf8))
        #expect(tag.scaleMin == 1)
        #expect(tag.scaleMax == 2)
    }

    // MARK: - Catalog filtering (picker shows only BINARY)

    @Test("Catalog separates BINARY tags from RATED factors")
    func catalogSplitsByKind() {
        let binary = MoodTagDTO(key: "happy", labelKey: "k", icon: nil)
        let rated = MoodTagDTO(key: "factor_work", labelKey: "k", icon: nil, kind: .rated)
        let cat = MoodTagCategoryDTO(key: "factors", labelKey: "k", icon: nil, tags: [binary, rated])
        #expect(cat.tags.filter { !$0.isRated }.map(\.key) == ["happy"])
        #expect(cat.tags.filter(\.isRated).map(\.key) == ["factor_work"])
    }

    // MARK: - Wire encoding (MoodEntryPatch)

    @Test("Patch omits ratedFactors when nil")
    func patchOmitsNilRatedFactors() throws {
        let patch = MoodEntryPatch(score: 4, ratedFactors: nil)
        let data = try JSONEncoder().encode(patch)
        let str = String(bytes: data, encoding: .utf8) ?? ""
        #expect(!str.contains("ratedFactors"))
    }

    @Test("Patch omits ratedFactors when empty")
    func patchOmitsEmptyRatedFactors() throws {
        let patch = MoodEntryPatch(score: 4, ratedFactors: [])
        let data = try JSONEncoder().encode(patch)
        let str = String(bytes: data, encoding: .utf8) ?? ""
        #expect(!str.contains("ratedFactors"))
    }

    @Test("Patch encodes ratedFactors when present")
    func patchEncodesRatedFactors() throws {
        let patch = MoodEntryPatch(
            score: 4,
            ratedFactors: [RatedFactorInput(key: "factor_work", rating: 4)]
        )
        let data = try JSONEncoder().encode(patch)
        let str = String(bytes: data, encoding: .utf8) ?? ""
        #expect(str.contains("ratedFactors"))
        #expect(str.contains("factor_work"))
        #expect(str.contains("\"rating\":4"))
    }

    // MARK: - Client clamp (avoid the server's out_of_range 422)

    @Test("A rating above a factor's scale clamps to its max")
    func clampToMax() {
        let conflict = MoodTagDTO(
            key: "factor_conflict", labelKey: "k", icon: nil,
            kind: .rated, scaleMin: 1, scaleMax: 2, inverse: true
        )
        let raw = 5
        let clamped = min(max(raw, conflict.scaleMin), conflict.scaleMax)
        #expect(clamped == 2)
    }

    @Test("A rating below a factor's scale clamps to its min")
    func clampToMin() {
        let work = MoodTagDTO(key: "factor_work", labelKey: "k", icon: nil, kind: .rated)
        let raw = 0
        let clamped = min(max(raw, work.scaleMin), work.scaleMax)
        #expect(clamped == 1)
    }

    // MARK: - v0.14.5 §R2 slider polarity mapping (RIGHT = good, always)

    @Test("Non-inverse: RIGHT (position 1) maps to the HIGH raw rating")
    func nonInverseRightIsHigh() {
        let s = MoodRatedFactorScale(scaleMin: 1, scaleMax: 5, inverse: false)
        #expect(s.rating(forPosition: 1.0, twoState: false) == 5) // good = high
        #expect(s.rating(forPosition: 0.0, twoState: false) == 1) // bad = low
        #expect(s.rating(forPosition: 0.5, twoState: false) == 3) // mid
    }

    @Test("Inverse: RIGHT (position 1, good) maps to the LOW raw rating")
    func inverseRightIsLow() {
        let s = MoodRatedFactorScale(scaleMin: 1, scaleMax: 5, inverse: true)
        #expect(s.rating(forPosition: 1.0, twoState: false) == 1) // good = low raw
        #expect(s.rating(forPosition: 0.0, twoState: false) == 5) // bad = high raw
    }

    @Test("position(forRating:) round-trips with both polarities")
    func positionRoundTrips() {
        let nonInv = MoodRatedFactorScale(scaleMin: 1, scaleMax: 5, inverse: false)
        #expect(nonInv.position(forRating: 5) == 1.0)
        #expect(nonInv.position(forRating: 1) == 0.0)
        let inv = MoodRatedFactorScale(scaleMin: 1, scaleMax: 5, inverse: true)
        #expect(inv.position(forRating: 1) == 1.0) // low raw = good = right
        #expect(inv.position(forRating: 5) == 0.0)
    }

    @Test("scaleMax == 2 two-state snaps to the endpoints")
    func twoStateSnaps() {
        let s = MoodRatedFactorScale(scaleMin: 1, scaleMax: 2, inverse: true)
        // good (right) → low raw (1) because inverse
        #expect(s.rating(forPosition: 1.0, twoState: true) == 1)
        #expect(s.rating(forPosition: 0.51, twoState: true) == 1)
        // bad (left) → high raw (2)
        #expect(s.rating(forPosition: 0.49, twoState: true) == 2)
        #expect(s.rating(forPosition: 0.0, twoState: true) == 2)
    }

    @Test("Mapping clamps to the factor's scale")
    func mappingClamps() {
        let s = MoodRatedFactorScale(scaleMin: 1, scaleMax: 2, inverse: false)
        #expect(s.rating(forPosition: 2.0, twoState: false) == 2) // over-range pos
        #expect(s.rating(forPosition: -1.0, twoState: false) == 1) // under-range pos
    }

    @Test("Untouched factor is omitted from the payload")
    func untouchedOmitted() {
        let work = MoodTagDTO(key: "factor_work", labelKey: "k", icon: nil, kind: .rated)
        let ratings: [String: Int] = [:] // work untouched ⇒ absent
        let payload: [RatedFactorInput] = [work].compactMap { f in
            guard let raw = ratings[f.key] else { return nil }
            return RatedFactorInput(key: f.key, rating: min(max(raw, f.scaleMin), f.scaleMax))
        }
        #expect(payload.isEmpty)
    }

    // MARK: - v1.13.0 — interim client hide-sets retired; server GET is authoritative

    @Test("Every BINARY tag the server returns is now visible (no client hide layer)")
    func binaryTagsNoLongerClientHidden() {
        // v1.13.0: the effective `GET /api/mood/tags` already omits hidden /
        // inactive tags, so the client applies NO curated hide. Any BINARY tag
        // the server still returns is meant to render.
        let tags = [
            MoodTagDTO(key: "slept_well", labelKey: "k", icon: nil),
            MoodTagDTO(key: "content", labelKey: "k", icon: nil),
            MoodTagDTO(key: "happy", labelKey: "k", icon: nil),
            MoodTagDTO(key: "nap", labelKey: "k", icon: nil)
        ]
        let visible = tags.filter(MoodTagPicker.isVisibleBinary).map(\.key)
        #expect(visible == ["slept_well", "content", "happy", "nap"])
    }

    @Test("A RATED factor is never a visible binary tile")
    func ratedNotVisibleBinary() {
        let rated = MoodTagDTO(key: "factor_sleep_quality", labelKey: "k", icon: nil, kind: .rated)
        #expect(!MoodTagPicker.isVisibleBinary(rated))
    }

    // MARK: - v0.14.7 — rated-factor READ-BACK decode + qualitative mapping

    @Test("MoodEntry decodes the server ratedFactors read field")
    func moodEntryDecodesRatedFactors() throws {
        let json = """
        { "id": "m1", "mood": "GUT", "tags": [], "tagKeys": ["family"],
          "moodLoggedAt": "2026-06-05T08:00:00Z", "source": "MANUAL",
          "ratedFactors": [ { "key": "factor_work", "rating": 2 },
                            { "key": "factor_sadness", "rating": 5 } ] }
        """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let entry = try dec.decode(MoodEntry.self, from: Data(json.utf8))
        #expect(entry.ratedFactors.count == 2)
        #expect(entry.ratedFactors.first?.key == "factor_work")
        #expect(entry.ratedFactors.first?.rating == 2)
        #expect(entry.tagKeys == ["family"])
    }

    @Test("MoodEntry tolerates a response without ratedFactors (pre-v2)")
    func moodEntryDecodesWithoutRatedFactors() throws {
        let json = """
        { "id": "m2", "mood": "OKAY", "tags": [], "tagKeys": [],
          "moodLoggedAt": "2026-06-05T08:00:00Z" }
        """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let entry = try dec.decode(MoodEntry.self, from: Data(json.utf8))
        #expect(entry.ratedFactors.isEmpty)
    }

    @Test("Non-inverse factor: a low rating reads as a bad quality")
    func qualityNonInverseLowIsBad() {
        let work = MoodTagDTO(key: "factor_work", labelKey: "k", icon: nil, kind: .rated)
        #expect(MoodRatedQuality.resolve(rating: 1, factor: work) == .bad)
        #expect(MoodRatedQuality.resolve(rating: 3, factor: work) == .mid)
        #expect(MoodRatedQuality.resolve(rating: 5, factor: work) == .good)
    }

    @Test("Inverse factor (sadness): a HIGH rating reads as a bad quality")
    func qualityInverseHighIsBad() {
        let sadness = MoodTagDTO(
            key: "factor_sadness", labelKey: "k", icon: nil,
            kind: .rated, scaleMin: 1, scaleMax: 5, inverse: true
        )
        // High sadness raw = worse day = bad quality.
        #expect(MoodRatedQuality.resolve(rating: 5, factor: sadness) == .bad)
        #expect(MoodRatedQuality.resolve(rating: 1, factor: sadness) == .good)
    }
}
