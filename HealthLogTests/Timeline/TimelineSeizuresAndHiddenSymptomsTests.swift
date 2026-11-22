import Foundation
@testable import HealthLog
import Testing

/// The `seizures` lane (server v1.48.0, #182 A4) and the hidden mark for
/// a symptom the person switched off (#165, `isActive: false`).
@Suite("Timeline: seizure lane and hidden symptoms")
@MainActor
struct TimelineSeizuresAndHiddenSymptomsTests {
    private struct Envelope: Decodable {
        let data: TimelineRead
    }

    private static let body = #"""
    {"data":{"zoom":"quarter","range":{"from":"2026-08-19","to":"2026-11-17","dataFrom":null},
      "lanes":[
        {"key":"illness","items":[]},
        {"key":"seizures","items":[
          {"id":"seizure-day:2026-10-02","kind":"seizureDay","start":"2026-10-02","end":null,"open":false,"label":"Fokal, Absence","sub":"3","href":"/seizures"},
          {"id":"seizure-day:2026-10-09","kind":"seizureDay","start":"2026-10-09","end":null,"open":false,"label":"","sub":"1","href":"/seizures"}
        ]}
      ],
      "bucket":"week","series":[]},"error":null}
    """#

    @Test("The seizure lane decodes with its day items, after illness")
    func decodesSeizureLane() throws {
        let read = try JSONDecoder.hlDefault.decode(Envelope.self, from: Data(Self.body.utf8)).data
        let items = read.items(of: .seizures)
        #expect(items.map(\.kind) == [.seizureDay, .seizureDay])
        #expect(items.first?.sub == "3")
        let order = TimelineLaneTrack.order
        let illness = try #require(order.firstIndex(of: .illness))
        #expect(order.firstIndex(of: .seizures) == illness + 1, "the server's lane order")
    }

    @Test("A seizure day reads its types and its count; without a type only the count")
    func seizureDayWords() {
        let typed = TimelineWording.seizureDayWords(label: "Fokal, Absence", sub: "3")
        #expect(typed.contains("Fokal, Absence"))
        #expect(typed.contains("3"))
        let bare = TimelineWording.seizureDayWords(label: "", sub: "1")
        #expect(bare.contains("1"))
        #expect(!TimelineWording.seizureDayWords(label: "", sub: nil).isEmpty)
    }

    @Test("A hidden symptom is marked in the menu and listed after the current ones")
    func hiddenSymptomMarked() {
        let current = TimelineSymptomOption(key: "symptom:a", definitionId: "a", label: "Kopfschmerz", isActive: true)
        let hidden = TimelineSymptomOption(key: "symptom:b", definitionId: "b", label: "Schwindel", isActive: false)
        #expect(TimelineChoicesMenu.symptomTitle(current) == "Kopfschmerz")
        let marked = TimelineChoicesMenu.symptomTitle(hidden)
        #expect(marked != "Schwindel")
        #expect(marked.contains("Schwindel"))
        #expect(TimelineChoicesMenu.symptomOptions([hidden, current]).map(\.key) == ["symptom:a", "symptom:b"])
    }
}
