import Foundation
@testable import HealthLog
import Testing

/// Build 7 / item 7.4 — the tolerant decode contract for the parity fields the
/// server `format=ios` payload gained in v1.18.0 B5 (`category`, `points`,
/// `target`, `current`, `isHidden`) plus the not-yet-emitted `format`. Uses the
/// canonical `JSONDecoder.hlDefault` (camelCase + ISO8601) — the same decoder
/// the `AchievementsRepository` runs — so a schema-drift bug can't slip past.
@Suite("Achievement — tolerant decoding of parity fields")
struct AchievementDecodingTests {
    private var decoder: JSONDecoder {
        .hlDefault
    }

    /// A current-server ios row carrying every field.
    private let fullFixture = #"""
    {
      "id": "bp-50",
      "key": "bp-50",
      "title": "Vitalwerte-Profi",
      "description": "Erfasse 50 Blutdruck-Messungen.",
      "iconName": "Heart",
      "unlocked": false,
      "unlockedAt": null,
      "progress": 0.42,
      "category": "vitals",
      "points": 90,
      "target": 50,
      "current": 21,
      "isHidden": false
    }
    """#

    @Test("decodes every parity field from a current-server row")
    func decodesFullRow() throws {
        let a = try decoder.decode(Achievement.self, from: Data(fullFixture.utf8))
        #expect(a.id == "bp-50")
        #expect(a.category == "vitals")
        #expect(a.points == 90)
        #expect(a.target == 50)
        #expect(a.current == 21)
        #expect(a.isHidden == false)
        #expect(a.unlockedAt == nil)
        #expect(abs(a.progress - 0.42) < 0.0001)
    }

    /// A pre-B5 server row — none of the parity fields are present.
    private let legacyFixture = #"""
    {
      "id": "weight-1",
      "key": "weight-1",
      "title": "Erste Messung",
      "description": "Erfasse deine erste Messung.",
      "iconName": "Scale",
      "unlocked": true,
      "unlockedAt": "2026-05-27T08:30:00.000Z",
      "progress": 1
    }
    """#

    @Test("a pre-parity row (no category/current/target/format/isHidden) still decodes")
    func decodesLegacyRow() throws {
        let a = try decoder.decode(Achievement.self, from: Data(legacyFixture.utf8))
        #expect(a.id == "weight-1")
        #expect(a.unlocked == true)
        #expect(a.unlockedAt != nil)
        #expect(a.category == nil)
        #expect(a.current == nil)
        #expect(a.target == nil)
        #expect(a.format == nil)
        // isHidden defaults false when the field is absent.
        #expect(a.isHidden == false)
    }

    @Test("an unknown format token degrades to nil, not a decode failure")
    func toleratesUnknownFormat() throws {
        let fixture = #"""
        { "id": "x", "key": "x", "title": "t", "description": "d",
          "unlocked": false, "progress": 0.5, "format": "lightyears" }
        """#
        let a = try decoder.decode(Achievement.self, from: Data(fixture.utf8))
        #expect(a.format == nil)
        #expect(a.id == "x")
    }

    @Test("a known format token decodes")
    func decodesKnownFormat() throws {
        let fixture = #"""
        { "id": "x", "key": "x", "title": "t", "description": "d",
          "unlocked": false, "progress": 0.5, "format": "days",
          "current": 12, "target": 30 }
        """#
        let a = try decoder.decode(Achievement.self, from: Data(fixture.utf8))
        #expect(a.format == .days)
        #expect(a.current == 12)
        #expect(a.target == 30)
    }

    @Test("isHidden=true marks the hidden placeholder")
    func isHiddenFieldDrivesPlaceholder() throws {
        let fixture = #"""
        { "id": "secret-1", "key": "secret-1", "title": "achievements.hiddenCard.title",
          "description": "achievements.hiddenCard.description", "iconName": "Sparkles",
          "unlocked": false, "progress": 0, "isHidden": true }
        """#
        let a = try decoder.decode(Achievement.self, from: Data(fixture.utf8))
        #expect(a.isHidden == true)
        #expect(a.isHiddenPlaceholder == true)
    }

    @Test("HelpCircle icon still marks a hidden placeholder when isHidden is absent (pre-B5 fallback)")
    func helpCircleFallbackPlaceholder() throws {
        let fixture = #"""
        { "id": "secret-2", "key": "secret-2", "title": "achievements.hiddenCard.title",
          "description": "achievements.hiddenCard.description", "iconName": "HelpCircle",
          "unlocked": false, "progress": 0 }
        """#
        let a = try decoder.decode(Achievement.self, from: Data(fixture.utf8))
        #expect(a.isHidden == false)
        #expect(a.isHiddenPlaceholder == true)
    }

    @Test("a missing points field leaves the field nil (resolvingPoints can hydrate it later)")
    func missingPointsIsNil() throws {
        let a = try decoder.decode(Achievement.self, from: Data(legacyFixture.utf8))
        #expect(a.points == nil)
    }

    @Test("a whole ios array decodes with mixed current/legacy rows")
    func decodesMixedArray() throws {
        let array = "[\(fullFixture),\(legacyFixture)]"
        let list = try decoder.decode([Achievement].self, from: Data(array.utf8))
        #expect(list.count == 2)
        #expect(list[0].points == 90)
        #expect(list[1].points == nil)
    }

    @Test("resolvingPoints preserves the parity fields it copies")
    func resolvingPointsCarriesParityFields() throws {
        let a = try decoder.decode(Achievement.self, from: Data(fullFixture.utf8))
        // points already present → resolvingPoints is a no-op, fields intact.
        let resolved = a.resolvingPoints()
        #expect(resolved.category == "vitals")
        #expect(resolved.current == 21)
        #expect(resolved.target == 50)
    }
}
