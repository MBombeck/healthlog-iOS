import Foundation
@testable import HealthLog
import Testing

/// The two text lines of the GLP-1 journal rows and the severity status of a
/// side-effect row.
@Suite("GLP-1 row lines")
struct EP1GLP1RowLinesTests {
    private let day = Date(timeIntervalSince1970: 1_790_000_000)

    private var received: String {
        String(format: String(localized: "Received %@"), HLDateFormat.date(day, style: .abbreviated))
    }

    @Test("A pen with a brand: brand as title, strength, date and note in one detail line")
    func penWithBrand() {
        let lines = PenInventoryView.rowLines(
            manufacturer: "Ozempic",
            doseStrength: "1 mg",
            dispensedAt: day,
            notes: "Kühlschrank"
        )
        #expect(lines.title == "Ozempic")
        #expect(lines.detail == "1 mg, \(received), Kühlschrank")
    }

    @Test("A pen without a brand takes its strength as title, never an empty one")
    func penWithoutBrand() {
        let lines = PenInventoryView.rowLines(manufacturer: "", doseStrength: "2,4 mg", dispensedAt: day, notes: nil)
        #expect(lines.title == "2,4 mg")
        #expect(lines.detail == received)
    }

    @Test("A note's line breaks do not end the one detail line")
    func penNoteLineBreaks() {
        let lines = PenInventoryView.rowLines(manufacturer: "Wegovy", doseStrength: "", dispensedAt: day, notes: "a\nb")
        #expect(lines.detail == "\(received), a b")
    }

    @Test("Each known severity has a status, the tone rising with it", arguments: [
        (1, HLBadge.Tone.info),
        (2, HLBadge.Tone.warning),
        (3, HLBadge.Tone.critical),
    ])
    func severityStatus(severity: Int, tone: HLBadge.Tone) {
        let status = SideEffectsLogbookSection.severityStatus(severity)
        #expect(status == HLRowStatus(SideEffectsLogbookSection.severityLabel(severity), tone: tone))
    }

    @Test("An unknown severity shows no status")
    func unknownSeverity() {
        #expect(SideEffectsLogbookSection.severityStatus(0) == nil)
    }
}
