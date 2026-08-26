import Foundation

/// Build 3 / item 3.2 — the "Save & next value" reset POLICY, as a pure value.
///
/// `AddLabResultSheet` holds its fields as `@State`, which no unit test can
/// reach. The policy that matters — **which fields survive a save-and-next and
/// which are cleared** — therefore lives here instead of inside the view, and
/// the sheet routes its reset through this one function. There is no second
/// copy of the rule to drift.
///
/// The rule, and the reason for it:
///   - **`takenAt` SURVIVES.** A real lab report is ten to twenty analytes
///     sharing ONE blood-draw date. Keeping it is the entire point of the flow
///     (web: `lab-form.tsx:202-224`, which comments the same intent); clearing
///     it would put the date picker back in the operator's way on every row.
///   - **`resultType` SURVIVES.** A report full of qualitative findings should
///     not flip back to numeric after every row.
///   - **Everything describing THIS reading is cleared** — the biomarker
///     selection, the value, the qualitative text, the note, and the free-text
///     analyte/unit/panel/bounds that travel with an unlinked marker.
struct LabEntryDraft: Equatable {
    var selectedBiomarkerID: String?
    var analyte: String = ""
    var unit: String = ""
    /// The NUMERIC field's raw text (locale-parsed at save time).
    var valueText: String = ""
    /// The QUALITATIVE result text. Separate from ``valueText`` so switching
    /// modes never smuggles "72,4" in as a qualitative result.
    var qualitativeText: String = ""
    var referenceLowText: String = ""
    var referenceHighText: String = ""
    var panel: String = ""
    var note: String = ""
    var takenAt: Date
    var resultType: LabResultType = .numeric

    /// The draft for the NEXT value of the same report.
    ///
    /// Returns a new draft rather than mutating in place so a test can assert
    /// "before" and "after" side by side, and so the sheet's assignment block
    /// reads as one atomic swap.
    func resetForNextValue() -> LabEntryDraft {
        LabEntryDraft(
            selectedBiomarkerID: nil,
            analyte: "",
            unit: "",
            valueText: "",
            qualitativeText: "",
            referenceLowText: "",
            referenceHighText: "",
            panel: "",
            note: "",
            // The two survivors.
            takenAt: takenAt,
            resultType: resultType
        )
    }
}
