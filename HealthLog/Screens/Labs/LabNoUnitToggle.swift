import SwiftUI

/// #160 / server #1313 — the explicit "No unit" switch next to a lab unit
/// field (marker editor, manual entry, scan review row). On, the field is
/// locked and the value goes out as the unity `"1"`; off again, the field
/// shows what was typed before. Never offered next to a medication dose, and
/// only from server 1.46.6 on (``LabUnit/offersNoUnit(current:defaults:)``).
struct LabNoUnitToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        HLSettingsToggleRow(
            title: "labs.unit.none",
            description: nil,
            isOn: $isOn,
            accessibilityID: "labs.unit.none"
        )
        .accessibilityHint(Text("labs.unit.noneHint"))
    }
}

extension LabUnit {
    /// The text a lab unit field shows: what was typed, or nothing while
    /// "No unit" is on. Writes go to `typed` only while the field is open, so
    /// switching "No unit" off restores the typed text.
    static func fieldBinding(typed: Binding<String>, noUnit: Bool) -> Binding<String> {
        Binding(
            get: { noUnit ? "" : typed.wrappedValue },
            set: { newValue in
                if !noUnit { typed.wrappedValue = newValue }
            }
        )
    }
}
