// 15-02 (B3) — the keyboard sits on the schedule options.
//
// The operator's B3 is "das Dropdown für den Zeitplan öffnet sich, während die
// Tastatur noch die unteren Zeilen verdeckt". The editor mounts its cadence
// section with no focus handling whatsoever (`EditMedicationSheet.swift`: the
// `@FocusState` at :98, the FORM-2 conveniences at :112-118, the initial focus
// at :225) and sets no `scrollDismissesKeyboard`, so a field that has
// focus keeps it while the schedule picker is being used, and the entries the
// keyboard covers cannot be scrolled into reach.
//
// Focus itself is not readable from a test — but every decision that moves it
// is pure, and since the refactor those decisions are one transition function,
// `MedicationEditorFocus.resolve(_:from:)`. This suite drives it exactly as the
// sheet does: current focus in, next focus out.

import Foundation
@testable import HealthLog
import Testing

@Suite("Medication editor — the keyboard yields (15-02)")
struct MedicationEditorKeyboardTests {
    // MARK: - 1) the schedule picker takes the floor

    /// The sequence the operator performs: type a dose, then reach for the
    /// Zeitplan row. At the moment the schedule editor becomes the interaction
    /// target, the text field must no longer hold focus — a keyboard over the
    /// control that is being operated is a data-entry dead end.
    @Test("Der Zeitplan-Picker nimmt der Tastatur den Platz")
    func pickerOpenClearsFocus() {
        // The sheet settles, the operator types a dose, then reaches for the
        // Zeitplan row.
        var field = MedicationEditorFocus.resolve(.sheetSettled, from: nil)
        field = MedicationEditorFocus.resolve(.submitted(.name), from: field)
        #expect(field == .dose, "precondition: the dose field has the keyboard")

        field = MedicationEditorFocus.resolve(.scheduleEditorEngaged, from: field)

        #expect(
            field == nil,
            "EXPECTED_RED: the keyboard stays up over the schedule options"
        )
    }

    /// The same must hold from the name field, and it must be idempotent: a
    /// second touch inside the schedule section cannot hand focus back.
    @Test("Auch aus dem Namensfeld heraus, und wiederholbar")
    func pickerOpenClearsFocusFromAnyField() {
        var field = MedicationEditorFocus.resolve(.scheduleEditorEngaged, from: .name)
        // Idempotent: a second touch inside the schedule section cannot hand
        // the keyboard back.
        field = MedicationEditorFocus.resolve(.scheduleEditorEngaged, from: field)

        #expect(
            field == nil,
            "EXPECTED_RED: the keyboard stays up from the name field too"
        )
    }

    // MARK: - 2) the conveniences survive (controls)

    /// FORM-2's submit chain is the reason the focus model exists at all. The
    /// fix removes a collision, not a convenience.
    @Test("Die Absende-Kette Name → Dosis bleibt")
    func submitChainStillAdvances() {
        let seeded = MedicationEditorFocus.resolve(.sheetSettled, from: nil)
        #expect(seeded == .name, "the settled sheet seeds the name field")
        #expect(MedicationEditorFocus.resolve(.submitted(.name), from: seeded) == .dose, "name → dose")
        #expect(MedicationEditorFocus.resolve(.submitted(.dose), from: .dose) == nil, "dose → done")
    }

    /// The sheet keeps the only copy of where focus IS: a tap on a field, or a
    /// keyboard the system put away, never travels through this function, and
    /// the seed is the same regardless of where focus happened to be.
    @Test("Der Sitz des Fokus bleibt beim Blatt")
    func theViewKeepsTheOnlyCopyOfTheTruth() {
        #expect(MedicationEditorFocus.resolve(.sheetSettled, from: .dose) == .name)
        #expect(MedicationEditorFocus.resolve(.sheetSettled, from: nil) == .name)
        #expect(MedicationEditorFocus.resolve(.submitted(.name), from: nil) == .dose)
    }
}
