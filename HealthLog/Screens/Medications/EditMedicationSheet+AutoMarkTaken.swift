import SwiftUI

/// **MED-PLUS (1.5.0, #126 3.11) — "Einnahmen automatisch erfassen" in the
/// medication editor, under "Erweitert".**
///
/// A rare option, so it folds out of one row of its own section (the pattern
/// of the add sheet's advanced options). On: the server records each scheduled
/// dose as taken at its time, a dose the person logs or skips always wins, and
/// no reminder goes out; under the switch "Seit …" names when it was switched
/// on (`autoMarkTakenSince`). The save names `autoMarkTaken` only when the
/// switch changed (``MedicationAutoMarkTakenFormValue/write``).
///
/// Offered only where ``Medication/offersAutoMarkTakenSwitch(canManage:)``
/// says so: the server knows the field, the medication has scheduled doses,
/// and the record in use lets the caller change medications. Folds out as soon
/// as the prefill shows the option on, so it is never hidden while it acts (the
/// section is built before the prefill lands, hence the change handler).
struct MedicationAutoMarkTakenSection: View {
    @Binding var value: MedicationAutoMarkTakenFormValue
    /// The server's `autoMarkTakenSince`, shown while the switch is as served.
    let since: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    var body: some View {
        Section {
            Button {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Text("Advanced")
                        .foregroundStyle(HLText.primary)
                    Spacer(minLength: HLSpace.sm)
                    Image(systemName: "chevron.down")
                        .font(.hlSubhead.weight(.semibold))
                        .foregroundStyle(HLText.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("med.edit.advanced")
            .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
            if isExpanded {
                HLSettingsToggleRow(
                    title: "med.edit.autoMarkTaken.label",
                    description: "med.edit.autoMarkTaken.helper",
                    isOn: $value.isOn,
                    accessibilityID: "med.edit.autoMarkTaken"
                )
                if let sinceText = Self.sinceText(value: value, since: since) {
                    Text(verbatim: sinceText)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .accessibilityIdentifier("med.edit.autoMarkTaken.since")
                }
            }
        }
        .onChange(of: value.server, initial: true) { _, server in
            if server == true { isExpanded = true }
        }
    }

    /// "Seit …" only while the switch is on as served: a switch just flipped
    /// on has no moment yet (the server stamps it on save).
    static func sinceText(value: MedicationAutoMarkTakenFormValue, since: Date?) -> String? {
        guard value.isOn, value.server == true, let since else { return nil }
        let date = HLDateFormat.date(since, style: .abbreviated)
        return String(localized: "med.edit.autoMarkTaken.since \(date) \(HLTimeFormat.time(since))")
    }
}
