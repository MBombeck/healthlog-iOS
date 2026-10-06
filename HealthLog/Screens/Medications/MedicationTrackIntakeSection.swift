import SwiftUI

/// **v1.39.1 (#1033) — the per-medication "track intake" switch.**
///
/// The web leads a medication's schedule with the same switch. On: doses fall
/// due on the schedule, with reminders and adherence. Off: the medication is
/// kept as a record — dose, dates and schedule stay stored as information, and
/// nothing falls due, reminds or counts toward adherence. The editor offers it
/// only against a server that knows the field, and the save names it only when
/// it changed (``MedicationTrackIntakeWrite``).
struct MedicationTrackIntakeSection: View {
    @Binding var isOn: Bool

    var body: some View {
        Section {
            HLSettingsToggleRow(
                title: "med.edit.trackIntake.label",
                description: isOn ? "med.edit.trackIntake.helperOn" : "med.edit.trackIntake.helperOff",
                isOn: $isOn,
                accessibilityID: "med.edit.trackIntake"
            )
        } header: {
            Text("med.edit.trackIntake.section")
        }
    }
}

/// The editor's intake-tracking state: the switch as shown, and the server's
/// own `trackIntake` (`nil` when the server does not know the field, in which
/// case the switch is not offered and the field is never sent).
struct MedicationTrackIntakeFormValue: Equatable {
    var tracked = true
    var server: Bool?
}
