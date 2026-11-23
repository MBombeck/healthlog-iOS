import SwiftUI

/// **"Einnahmen automatisch erfassen" in the
/// medication editor, under "Erweitert".**
///
/// A rare option, so it waits behind the centred „Erweitert" link and folds
/// out in a card of its own beneath it, like the add sheet's options. On: the server records each scheduled
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
        // A group, so the change handler sits on the link and the card alike.
        Group {
            Section {
                HLLinkButton("Advanced", isExpanded: isExpanded) {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { isExpanded.toggle() }
                }
                .accessibilityIdentifier("med.edit.advanced")
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }
            if isExpanded {
                Section {
                    HLSettingsToggleRow(
                        title: "med.edit.autoMarkTaken.label",
                        description: "med.edit.autoMarkTaken.helper",
                        isOn: $value.isOn,
                        accessibilityID: "med.edit.autoMarkTaken"
                    )
                    if let sinceText = Self.sinceText(value: value, since: since) {
                        Text(verbatim: sinceText)
                            .hlText(.rowSubtitle)
                            .accessibilityIdentifier("med.edit.autoMarkTaken.since")
                    }
                }
                .hlFormRowSurface()
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
