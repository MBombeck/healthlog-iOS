import SwiftUI

/// The symptoms to log as chips, one to pick, as on the web's quick entry.
///
/// From ``filterThreshold`` + 1 symptoms on (the server admits 30 of one's
/// own since 1.48.4, plus the built-in ones Apple Health created) a filter
/// field stands above the chips; the picked chip stays while the filter
/// hides the others, so a choice never disappears.
struct SymptomChipPicker: View {
    let definitions: [SymptomDefinition]
    @Binding var selection: String?
    @State private var filter = ""

    /// The web's `SYMPTOM_FILTER_THRESHOLD`: up to this many chips fit a
    /// glance on a phone.
    nonisolated static let filterThreshold = 12

    nonisolated static func showsFilter(count: Int) -> Bool {
        count > filterThreshold
    }

    /// The chips a filter leaves: every one whose name holds the text, and
    /// the picked one (the web's `filterSymptomChips`).
    nonisolated static func filtered(
        _ definitions: [SymptomDefinition],
        filter: String,
        picked: String?
    ) -> [SymptomDefinition] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return definitions }
        return definitions.filter { definition in
            definition.id == picked
                || (definition.label ?? "").localizedStandardContains(needle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HLRowTitle("symptoms.field.symptom")
            if Self.showsFilter(count: definitions.count) {
                TextField("symptoms.filter.placeholder", text: $filter)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("symptoms.edit.filter")
            }
            let shown = Self.filtered(definitions, filter: filter, picked: selection)
            if shown.isEmpty {
                HLEmptyNote("symptoms.filter.empty")
            } else {
                HLFlowLayout {
                    ForEach(shown) { definition in
                        HLChip(
                            verbatim: SymptomEventFormat.label(definition.label),
                            isSelected: selection == definition.id
                        ) {
                            selection = selection == definition.id ? nil : definition.id
                        }
                        .accessibilityIdentifier("symptoms.chip.\(definition.id)")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("symptoms.edit.symptom")
    }
}
