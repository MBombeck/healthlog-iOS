import SwiftUI

/// **H1/H2 (AUDIT-PARITY-v11612) — units-per-dose picker.**
///
/// Shared between the add-wizard (`AddMedicationSheet`) and the edit sheet
/// (`EditMedicationSheet`) so the two surfaces offer the IDENTICAL curated set
/// — the five split-pill fractions (¼ ⅓ ½ ⅔ ¾) and whole 1…10 — and can never
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
        var all = MedicationUnitsPerDose.allCases
        if !all.contains(selection) {
            all.append(selection)
        }
        return all
    }

    var body: some View {
        Picker("med.form.unitsPerDose.label", selection: $selection) {
            ForEach(options) { option in
                Text(option.label).tag(option)
            }
        }
        .accessibilityIdentifier("med.form.unitsPerDose")
    }
}
