import SwiftUI

/// A form row that picks one of several values from a menu: the row title on
/// the left, the chosen value with the menu sign on the right.
///
/// The system menu picker keeps its value on one line and cuts it in the
/// middle once the text is large ("Allge…dheit"). From the accessibility
/// sizes on this row stacks instead: the title on its own line, the value
/// under it, wrapping as far as it needs, the menu sign after it. The menu
/// itself is the system's, with the check mark at the chosen value.
///
/// ```swift
/// HLFormPicker("Goal", selection: $goal, options: CycleGoal.allCases) { Text($0.title) }
/// ```
struct HLFormPicker<Value: Hashable>: View {
    private let title: Text
    @Binding private var selection: Value
    private let options: [Value]
    private let label: (Value) -> Text

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        _ title: LocalizedStringKey,
        selection: Binding<Value>,
        options: [Value],
        label: @escaping (Value) -> Text
    ) {
        self.title = Text(title)
        _selection = selection
        self.options = options
        self.label = label
    }

    /// For a title that exists only at run time.
    init(
        title: Text,
        selection: Binding<Value>,
        options: [Value],
        label: @escaping (Value) -> Text
    ) {
        self.title = title
        _selection = selection
        self.options = options
        self.label = label
    }

    /// From the first accessibility size on, title and value stand one
    /// above the other.
    nonisolated static func stacks(at typeSize: DynamicTypeSize) -> Bool {
        typeSize.isAccessibilitySize
    }

    var body: some View {
        Group {
            if Self.stacks(at: dynamicTypeSize) {
                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    rowTitle
                    Menu {
                        picker
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
                            label(selection)
                                .font(HLRowValue.Emphasis.setting.font)
                                .foregroundStyle(HLRowValue.Emphasis.setting.tint)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.hlFootnote.weight(.semibold))
                                .foregroundStyle(HLText.secondary)
                                .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .sensoryFeedback(.selection, trigger: selection)
                    .accessibilityLabel(title)
                    .accessibilityValue(label(selection))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: HLSpace.sm) {
                    rowTitle
                    Spacer(minLength: HLSpace.sm)
                    picker
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                }
            }
        }
        .frame(minHeight: HLLayout.rowMinHeight)
    }

    private var rowTitle: some View {
        title
            .font(HLRowTitle.font)
            .foregroundStyle(HLText.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var picker: some View {
        Picker(selection: $selection) {
            ForEach(options, id: \.self) { option in
                label(option).tag(option)
            }
        } label: {
            title
        }
    }
}

#Preview("HLFormPicker") {
    @Previewable @State var goal = "Allgemeine Gesundheit"
    Form {
        HLFormPicker(
            title: Text(verbatim: "Ziel"),
            selection: $goal,
            options: ["Allgemeine Gesundheit", "Schwangerschaft planen", "Verhütung"]
        ) { Text(verbatim: $0) }
    }
    .dynamicTypeSize(.accessibility3)
}
