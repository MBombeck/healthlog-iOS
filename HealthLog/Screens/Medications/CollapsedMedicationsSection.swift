import SwiftUI

/// The collapsed list under the active medications, shared by „Ausgeblendet“
/// and „Archiviert“ so both sections have the same head, counter, row height
/// and button. A section only names what differs: title, the line under each
/// name, the row button and an optional sentence under the rows.
struct CollapsedMedicationsSection: View {
    struct RowAction {
        let systemImage: String
        let accessibilityLabel: (Medication) -> LocalizedStringKey
        let identifierPrefix: String
        let perform: (Medication) -> Void
    }

    let title: LocalizedStringKey
    let medications: [Medication]
    let countAccessibilityLabel: Text
    @Binding var isExpanded: Bool
    let detail: (Medication) -> String
    let action: RowAction
    var footer: LocalizedStringKey?

    var body: some View {
        HLSectionHeader(title) {
            Text("\(medications.count)")
                .hlText(.footnote)
                .monospacedDigit()
                .accessibilityLabel(countAccessibilityLabel)
        }

        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: HLLayout.rowGap) {
                ForEach(medications, id: \.id) { med in
                    row(med)
                }
                if let footer {
                    Text(footer)
                        .hlText(.rowSubtitle)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, HLSpace.xxs)
                }
            }
        } label: {
            // The section identity is the header above; the label only says
            // what the tap does.
            Text(isExpanded ? "medications.section.list.collapse" : "medications.section.list.expand")
                .hlText(.prose)
                // At the largest sizes the label wraps; it stays flush left.
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A data row: name and its one detail line on the shared grid, the row
    /// button as its only control.
    private func row(_ med: Medication) -> some View {
        HLRowLayout(title: Text(verbatim: med.name), subtitle: HLRowDetail.text([detail(med)])) {
            // The label names the medication, so VoiceOver says which row it acts on.
            HLIconButton(systemImage: action.systemImage, label: action.accessibilityLabel(med)) {
                action.perform(med)
            }
            .accessibilityIdentifier("\(action.identifierPrefix).\(med.id)")
        } leading: {
            EmptyView()
        }
    }
}

/// Active medications hidden on this device. They keep running; the row
/// button shows them in the list again.
struct HiddenMedicationsSection: View {
    let medications: [Medication]
    @Binding var isExpanded: Bool
    let onUnhide: (Medication) -> Void

    var body: some View {
        CollapsedMedicationsSection(
            title: "medications.section.hidden.title",
            medications: medications,
            countAccessibilityLabel: Text("medications.section.hidden.count_a11y \(String(medications.count))"),
            isExpanded: $isExpanded,
            detail: \.dose,
            action: .init(
                systemImage: "eye",
                accessibilityLabel: { "medications.hidden.unhide_a11y \($0.name)" },
                identifierPrefix: "medications.hidden.unhide",
                perform: onUnhide
            ),
            footer: "medications.section.hidden.footer"
        )
    }
}
