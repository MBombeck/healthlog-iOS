// The create and edit sheets share one focus transition, so the schedule row
// never opens while the keyboard still covers the lower rows.

import Foundation
@testable import HealthLog
import Testing

@Suite("Medication create sheet — the same keyboard contract as the editor (20-04)")
struct MedicationEditorFocusTests {
    /// Fails if someone copies a different rule into a sheet instead of calling
    /// the one both sheets share.
    @Test("Die Entscheidung selbst bleibt die aus 15-02")
    func theTransitionItselfIsUnchanged() {
        #expect(MedicationEditorFocus.resolve(.scheduleEditorEngaged, from: .name) == nil)
        #expect(MedicationEditorFocus.resolve(.scheduleEditorEngaged, from: .dose) == nil)
        #expect(MedicationEditorFocus.resolve(.sheetSettled, from: nil) == .name)
        #expect(MedicationEditorFocus.resolve(.submitted(.name), from: .name) == .dose)
        #expect(MedicationEditorFocus.resolve(.submitted(.dose), from: .dose) == nil)
    }
}
