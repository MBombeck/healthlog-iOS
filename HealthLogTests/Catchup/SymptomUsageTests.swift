import Foundation
@testable import HealthLog
import Testing

/// #191 QoL — the symptoms offered by use, and a picked symptom starting on
/// its last intensity, as the web's quick entry does.
@Suite("Symptoms by use with the last intensity (#191 QoL)")
struct SymptomUsageTests {
    private static func definition(_ id: String, count: Int?, last: String? = nil) -> SymptomDefinition {
        SymptomDefinition(
            id: id,
            label: id,
            recent: count.map { SymptomRecentUse(count30d: $0, lastOccurredAt: last) }
        )
    }

    private static func event(_ id: String, _ definitionId: String, intensity: Int) -> SymptomEvent {
        SymptomEvent(
            id: id,
            definitionId: definitionId,
            occurredAt: "2026-11-20T08:00:00Z",
            intensity: intensity,
            note: nil,
            episodeId: nil
        )
    }

    @Test("most used in 30 days first, the more recent ahead on a tie, unused in server order")
    func orderByUse() {
        let list = [
            Self.definition("unusedA", count: 0),
            Self.definition("twiceOld", count: 2, last: "2026-11-01T08:00:00Z"),
            Self.definition("noSummary", count: nil),
            Self.definition("five", count: 5, last: "2026-10-30T08:00:00Z"),
            Self.definition("twiceNew", count: 2, last: "2026-11-19T08:00:00Z"),
            Self.definition("unusedB", count: 0, last: "2026-08-01T08:00:00Z")
        ]
        let ordered = SymptomUsage.orderedByUse(list).map(\.id)
        #expect(ordered == ["five", "twiceNew", "twiceOld", "unusedA", "noSummary", "unusedB"])
    }

    @Test("without any summary the server's order stays")
    func olderServerKeepsOrder() {
        let list = ["c", "a", "b"].map { Self.definition($0, count: nil) }
        #expect(SymptomUsage.orderedByUse(list).map(\.id) == ["c", "a", "b"])
    }

    @Test("the last intensity is the newest occurrence's")
    func latestIntensity() {
        let events = [
            Self.event("e3", "cough", intensity: 6),
            Self.event("e2", "cough", intensity: 2),
            Self.event("e1", "headache", intensity: 4)
        ]
        #expect(SymptomUsage.latestIntensities(events) == ["cough": 6, "headache": 4])
    }

    @Test("a pick starts on the last intensity, a chosen intensity stays")
    func pickPresets() {
        let last = ["cough": 6, "headache": 4]
        // Empty field: the pick's last intensity, marked as preset.
        let first = SymptomUsage.afterPick("cough", intensity: nil, presetFor: nil, last: last)
        #expect(first.intensity == 6)
        #expect(first.presetFor == "cough")
        // Another pick while the preset stands: the new symptom's value.
        let second = SymptomUsage.afterPick("headache", intensity: 6, presetFor: "cough", last: last)
        #expect(second.intensity == 4)
        #expect(second.presetFor == "headache")
        // A pick without history while a preset stands empties the field.
        let fresh = SymptomUsage.afterPick("nausea", intensity: 4, presetFor: "headache", last: last)
        #expect(fresh.intensity == nil)
        #expect(fresh.presetFor == nil)
        // An intensity the person chose is never overwritten.
        let chosen = SymptomUsage.afterPick("cough", intensity: 3, presetFor: nil, last: last)
        #expect(chosen.intensity == 3)
        #expect(chosen.presetFor == nil)
        // Clearing the pick drops a preset, keeps a choice.
        #expect(SymptomUsage.afterPick(nil, intensity: 6, presetFor: "cough", last: last).intensity == nil)
        #expect(SymptomUsage.afterPick(nil, intensity: 3, presetFor: nil, last: last).intensity == 3)
    }

    @Test("the definition reads `recent` and tolerates an odd or missing one")
    func decodesRecent() throws {
        let json = Data("""
        {"definitions":[
          {"id":"a","label":"Husten","sortOrder":0,"isActive":true,
           "recent":{"count30d":3,"maxIntensity30d":7,"lastOccurredAt":"2026-11-19T08:00:00.000Z"}},
          {"id":"b","label":"Kopfweh","sortOrder":1,"isActive":true,"recent":"odd"},
          {"id":"c","label":"Übelkeit","sortOrder":2,"isActive":true}
        ],"limit":30}
        """.utf8)
        let list = try JSONDecoder().decode(SymptomDefinitionList.self, from: json)
        #expect(list.definitions.count == 3)
        #expect(list.definitions[0].recent?.count30d == 3)
        #expect(list.definitions[0].recent?.lastOccurredDate != nil)
        #expect(list.definitions[1].recent == nil)
        #expect(list.definitions[2].recent == nil)
    }
}
