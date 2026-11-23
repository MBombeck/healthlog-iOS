import SwiftUI

/// A period choice standing in the content: segments at full width, a menu
/// from the first accessibility size on.
///
/// No chart page uses it any more: since 1.7 every chart page floats its
/// period at the bottom edge (``SwiftUI/View/hlPeriodBar(selection:label:isShown:)``,
/// glass segments). Kept for the building-block gallery only.
struct HLPeriodPicker<Option: HLRangeOption>: View where Option.AllCases: RandomAccessCollection {
    nonisolated static var identifier: String {
        "hl.periodPicker"
    }

    /// Segments at the standard sizes, a menu from the first accessibility
    /// size on.
    nonisolated static func usesMenu(at typeSize: DynamicTypeSize) -> Bool {
        typeSize.isAccessibilitySize
    }

    @Binding private var selection: Option
    private let label: LocalizedStringKey
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(selection: Binding<Option>, label: LocalizedStringKey = "Time range") {
        _selection = selection
        self.label = label
    }

    var body: some View {
        Group {
            if Self.usesMenu(at: dynamicTypeSize) {
                menu
            } else {
                HLRangePicker(selection: $selection, style: .inline)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityIdentifier(Self.identifier)
    }

    /// The menu form: the label and the chosen period in full, the menu sign
    /// after it, at the leading edge where the segments began.
    private var menu: some View {
        Menu {
            Picker(selection: $selection) {
                ForEach(Array(Option.allCases)) { option in
                    Text(option.rangeAccessibilityLabel).tag(option)
                }
            } label: {
                Text(label)
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: HLSpace.xs) {
                Text(selection.rangeAccessibilityLabel)
                    .font(.hlHeadline)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.hlFootnote.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(HLText.primary)
            .frame(maxWidth: .infinity, minHeight: HLHitTarget.minimum, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(selection.rangeAccessibilityLabel))
        .sensoryFeedback(.selection, trigger: selection)
    }
}

#Preview("HLPeriodPicker") {
    @Previewable @State var range = HLTimeRange.standard
    HLPage {
        HLPeriodPicker(selection: $range)
        HLCard { Color.clear.frame(height: 160) }
    }
}
