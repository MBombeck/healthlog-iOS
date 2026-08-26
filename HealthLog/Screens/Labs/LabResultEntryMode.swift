import SwiftUI

/// **Item 1.5 — numeric vs. qualitative lab result entry.**
///
/// The server has carried `value: number | null` + `valueText: string | null`
/// since v1.18.9; the web form exposes the choice as a two-button segmented
/// control (`lab-form.tsx:320-344`) and offers three suggestions behind a
/// `<datalist>` (`:382-386`). iOS had neither the wire field nor the control, so
/// a qualitative row round-tripped through the app as an empty measurement.
///
/// This type is the shared vocabulary for the add + edit sheets so the two can
/// never drift on which mode posts which key.
enum LabResultType: String, CaseIterable, Identifiable, Hashable {
    case numeric
    case qualitative

    var id: String {
        rawValue
    }

    /// Segmented-control label.
    var pickerLabel: LocalizedStringKey {
        switch self {
        case .numeric: "labs.form.numeric"
        case .qualitative: "labs.form.qualitative"
        }
    }
}

/// The three suggestions the web form offers behind its `<datalist>`. Rendered
/// as tappable chips on iOS — a phone has no datalist affordance, and three
/// one-tap options beat a free-text field the user has to spell into.
///
/// Free text stays possible: the chips FILL the field, they don't constrain it.
enum LabQualitativeSuggestion: String, CaseIterable, Identifiable {
    case negative
    case positive
    case borderline

    var id: String {
        rawValue
    }

    /// The localized suggestion text — this is also the value that gets POSTed,
    /// so it deliberately reads as the operator's own words, not a code.
    var text: String {
        switch self {
        case .negative: String(localized: "labs.form.qualNegative")
        case .positive: String(localized: "labs.form.qualPositive")
        case .borderline: String(localized: "labs.form.qualBorderline")
        }
    }
}

/// The shared "Ergebnistyp" segmented control + qualitative suggestion chips,
/// so the add and edit sheets present an identical affordance.
struct LabResultTypePicker: View {
    @Binding var resultType: LabResultType

    var body: some View {
        Picker("labs.form.resultType", selection: $resultType) {
            ForEach(LabResultType.allCases) { type in
                Text(type.pickerLabel).tag(type)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("labs.form.resultType.picker")
    }
}

/// One-tap fill chips for the three canonical qualitative results.
struct LabQualitativeSuggestionChips: View {
    @Binding var text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HLSpace.sm) {
                ForEach(LabQualitativeSuggestion.allCases) { suggestion in
                    let label = suggestion.text
                    Button {
                        text = label
                    } label: {
                        Text(verbatim: label)
                            .font(.hlSubhead)
                            .padding(.horizontal, HLSpace.md)
                            .padding(.vertical, HLSpace.chip)
                            .foregroundStyle(text == label ? HLColor.background : HLText.primary)
                            .background(
                                Capsule()
                                    .fill(text == label ? AnyShapeStyle(HLText.primary) : AnyShapeStyle(Color.clear))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(text == label ? Color.clear : HLText.tertiary.opacity(0.3), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("labs.form.qualSuggestion.\(suggestion.rawValue)")
                    .accessibilityAddTraits(text == label ? .isSelected : [])
                }
            }
        }
    }
}
