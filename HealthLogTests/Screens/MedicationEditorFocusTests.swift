// 20-04 (D-15-02-A) — the create sheet learns what the editor knows.
//
// 15-02 fixed B3 ("das Dropdown für den Zeitplan öffnet sich, während die
// Tastatur noch die unteren Zeilen verdeckt") in `EditMedicationSheet` only,
// because that is where the walkthrough reported it. `AddMedicationSheet`
// carries the identical shape: its own private `Field` enum and `@FocusState`,
// the same settle-then-focus `.task`, the same name→dose submit chain, a
// cadence section mounted with no focus handling at all, and no
// `scrollDismissesKeyboard` on its `Form`. The operator has been told B3 is
// done; this is what makes that statement whole.
//
// **Why this suite reads source text.** 15-02's own tests
// (`MedicationEditorKeyboardTests`) pin the pure transition function
// `MedicationEditorFocus.resolve(_:from:)`, and that function is already green —
// it was green before 15-02's fix reached the create sheet and it will be green
// whether or not this plan lands. The open question is not what the function
// decides; it is whether the create sheet ASKS it. `@FocusState` is not readable
// from a test and a SwiftUI modifier is not reflectable, so the adoption itself
// has no runtime seam, and the repository's existing idiom for exactly this
// class of contract is a source assertion (`HLButtonRestrainedContractTests`,
// `UIStandardBaselineTests`).
//
// **The control probe.** A source search that finds nothing proves nothing
// unless the same search is known to find something (the 12-11 rule). Every
// assertion below is therefore run against `EditMedicationSheet.swift` first,
// where 15-02 already landed it — so a green result here means "the create
// sheet adopted it", never "the pattern moved and the search went blind".

import Foundation
@testable import HealthLog
import Testing

@Suite("Medication create sheet — the same keyboard contract as the editor (20-04)")
struct MedicationEditorFocusTests {
    private enum SourceMissing: Error, CustomStringConvertible {
        case unreadable(String)

        var description: String {
            switch self {
            case let .unreadable(path): "could not read \(path)"
            }
        }
    }

    /// `<repo>/HealthLogTests/Screens/MedicationEditorFocusTests.swift` →
    /// `<repo>`. `resolvingSymlinksInPath()` for the same reason as
    /// `UIStandardBaselineTests.repoRoot()`.
    private nonisolated static func repoRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent() // Screens
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // <repo>
            .resolvingSymlinksInPath()
    }

    private nonisolated static func sheetSource(_ name: String) throws -> String {
        let url = repoRoot()
            .appendingPathComponent("HealthLog")
            .appendingPathComponent("Screens")
            .appendingPathComponent("Medications")
            .appendingPathComponent(name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw SourceMissing.unreadable(url.path)
        }
        return text
    }

    /// The two lines of adoption D-15-02-A names, as literal source facts.
    private nonisolated static let adoptions = [
        "the schedule row resolves focus away": "MedicationEditorFocus.resolve(.scheduleEditorEngaged",
        "the form dismisses the keyboard on a drag": ".scrollDismissesKeyboard(.interactively)"
    ]

    // MARK: - 1) the control: the search is known to work

    @Test("Kontrollprobe: im Bearbeiten-Blatt findet dieselbe Suche beides")
    func theEditorAlreadyCarriesBothHalves() throws {
        let editor = try Self.sheetSource("EditMedicationSheet.swift")
        for (what, needle) in Self.adoptions {
            #expect(editor.contains(needle), "control probe failed for \(what) — the search went blind")
        }
    }

    // MARK: - 2) the subject

    @Test("Das Anlegen-Blatt trägt denselben Fokus-/Tastatur-Vertrag")
    func theCreateSheetCarriesTheSameContract() throws {
        let create = try Self.sheetSource("AddMedicationSheet.swift")
        let adopted = Self.adoptions.values.allSatisfy { create.contains($0) }
        #expect(
            adopted,
            """
            EXPECTED_RED: AddMedicationSheet has neither MedicationEditorFocus.resolve \
            nor scrollDismissesKeyboard — B3 was fixed in the edit sheet only
            """
        )
    }

    /// One focus vocabulary, not two. The create sheet's private `Field` enum is
    /// the reason the adoption is not a one-liner, and leaving it in place would
    /// let the two sheets drift apart again.
    @Test("Es gibt nur noch ein Fokus-Vokabular, nicht zwei")
    func theCreateSheetStopsDeclaringItsOwnFieldEnum() throws {
        let create = try Self.sheetSource("AddMedicationSheet.swift")
        let single = create.contains("MedicationEditorFocus.Field")
            && !create.contains("private enum Field")
        #expect(
            single,
            "EXPECTED_RED: the create sheet keeps a second, private focus vocabulary of its own"
        )
    }

    // MARK: - 3) the decision itself is still 15-02's (control)

    /// The adoption must not re-derive the transition. Green before and after —
    /// its job is to fail if someone copies a DIFFERENT rule into the create
    /// sheet instead of calling the one the editor calls.
    @Test("Die Entscheidung selbst bleibt die aus 15-02")
    func theTransitionItselfIsUnchanged() {
        #expect(MedicationEditorFocus.resolve(.scheduleEditorEngaged, from: .name) == nil)
        #expect(MedicationEditorFocus.resolve(.scheduleEditorEngaged, from: .dose) == nil)
        #expect(MedicationEditorFocus.resolve(.sheetSettled, from: nil) == .name)
        #expect(MedicationEditorFocus.resolve(.submitted(.name), from: .name) == .dose)
        #expect(MedicationEditorFocus.resolve(.submitted(.dose), from: .dose) == nil)
    }
}
