import Foundation
@testable import HealthLog
import Testing

/// Registering a container: a count outside 1 to 1000 is a visible range
/// error and keeps saving locked, instead of being lifted or clamped
/// without a word.
@Suite("Supply editor holds the unit count to its range")
struct MedicationSupplyEditorRangeTests {
    private let german = Locale(identifier: "de_DE")

    @Test("registering 0 or 1001 units is out of range, says so and cannot be saved", arguments: ["0", "1001"])
    func registerOutOfRange(text: String) {
        let range = MedicationSupplyEditorSheet.unitsRange(isEditing: false)
        let state = HLNumberEntry.state(of: text, range: range, fractionDigits: 0 ... 2, locale: german)
        #expect(state == .outOfRange)
        #expect(HLNumberEntry.message(for: state, range: range, fractionDigits: 0 ... 2, locale: german) != nil)
        #expect(!MedicationSupplyEditorSheet.canSave(units: state.value))
    }

    @Test("registering 1 or 1000 units can be saved")
    func registerInRange() {
        let range = MedicationSupplyEditorSheet.unitsRange(isEditing: false)
        for text in ["1", "1000"] {
            let state = HLNumberEntry.state(of: text, range: range, fractionDigits: 0 ... 2, locale: german)
            #expect(MedicationSupplyEditorSheet.canSave(units: state.value))
        }
    }

    @Test("a correction may reach zero")
    func correctToZero() {
        let range = MedicationSupplyEditorSheet.unitsRange(isEditing: true)
        let state = HLNumberEntry.state(of: "0", range: range, fractionDigits: 0 ... 2, locale: german)
        #expect(state == .valid(0))
    }
}
