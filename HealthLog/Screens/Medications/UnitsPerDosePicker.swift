import SwiftUI

/// **H1/H2 (AUDIT-PARITY-v11612) — units-per-dose picker.**
///
/// Shared between the add-wizard (`AddMedicationSheet`) and the edit sheet
/// (`EditMedicationSheet`) so the two surfaces offer the IDENTICAL curated set
/// — the five split-pill fractions (¼ ⅓ ½ ⅔ ¾), whole 1…10 and, against a
/// server from v1.39.1 on, the halves 1½ … 9½ — and can never
/// drift. A single menu picker keeps the Form row compact; the selection is the
/// `MedicationUnitsPerDose` value that maps to the server `unitsPerDose`
/// decimal.
struct UnitsPerDosePicker: View {
    @Binding var selection: MedicationUnitsPerDose

    /// The curated options plus, if the current selection is a valid server whole
    /// above ``MedicationUnitsPerDose/pickerWholeMax`` (e.g. a web-set 15), that
    /// exact value as an extra row — so an out-of-range-but-valid prefill always
    /// has a matching tag and round-trips losslessly instead of snapping to 10.
    private var options: [MedicationUnitsPerDose] {
        var all = MedicationUnitsPerDose.pickerOptions(offeringHalves: MedicationUnitsPerDose.serverTakesHalves())
        if !all.contains(selection) {
            all.append(selection)
        }
        return all
    }

    var body: some View {
        // A form row that stacks at the accessibility sizes instead of
        // cutting its value in the middle.
        HLFormPicker("med.form.unitsPerDose.label", selection: $selection, options: options) { option in
            Text(verbatim: option.label)
        }
        .accessibilityIdentifier("med.form.unitsPerDose")
    }
}

/// "Doses per unit" as a labelled form row: the title on the left, the
/// number field on the right with "Optional" as its prompt. A bare text field
/// read as a grey placeholder without any control once nothing was typed,
/// and as a number without a name once something was.
struct MedicationDosesPerUnitField: View {
    @Binding var text: String

    var body: some View {
        LabeledContent {
            TextField("med.form.dosesPerUnit.label", text: $text, prompt: Text("Optional"))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
        } label: {
            HLRowTitle("med.form.dosesPerUnit.label")
        }
    }
}
