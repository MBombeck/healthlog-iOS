import SwiftUI

/// A text field of a lab form that keeps its name once it holds a value:
/// the label in caption size over the field, as on the sign-in forms. A bare
/// field only showed its placeholder while empty, so a filled review listed
/// "42", "ng/ml", "30" without saying which is which.
struct LabFormField<Field: View>: View {
    private let label: LocalizedStringKey
    private let field: Field

    init(_ label: LocalizedStringKey, @ViewBuilder field: () -> Field) {
        self.label = label
        self.field = field()
    }

    var body: some View {
        HLFormField(label) { field }
    }
}

/// Where a reference range comes from and its sources, as one line: the
/// caption wraps, the link stays at the right. Every lab page that states a
/// range verdict carries it (App Review 1.4.1).
struct LabReferenceSourceLine: View {
    let topic: MedicalSourceTopic

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At the accessibility sizes the link goes under the caption; side
        // by side both broke into syllables.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: HLSpace.xs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: HLSpace.sm))
        layout {
            Text("labs.detail.reference.caption")
                .hlText(.rowSubtitle)
                .fixedSize(horizontal: false, vertical: true)
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: HLSpace.sm)
            }
            HLSourcesLink(topic: topic)
        }
    }
}

/// The panel a reading or a marker belongs to, in the person's language.
///
/// The server stores the panel as free text: a seeded marker carries the
/// label in the language it was created in, a read report the English key
/// ("coagulation"). Known keys read as their label; anything else stays as
/// the person or the lab wrote it.
enum LabPanelName {
    static func display(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        let key = trimmed.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "")
        if let seed = BiomarkerSeedPanel.allCases.first(where: { $0.rawValue.lowercased() == key }) {
            return seed.displayName
        }
        if key == "coagulation" {
            return String(localized: "labs.catalog.panel.coagulation")
        }
        return trimmed
    }

    /// What an editor sends for the panel field: the stored value as it was
    /// while the field still shows its label, so opening and saving a marker
    /// never rewrites "coagulation" into the reader's language.
    static func toSave(typed: String, stored: String?) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        if let stored, trimmed == display(stored) {
            return stored.trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }
}
