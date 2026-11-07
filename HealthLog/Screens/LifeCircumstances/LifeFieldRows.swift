import SwiftUI

// **LIFE (1.5.0)** — the question rows of the life circumstances.
//
// Every row allows "no answer" (`nil`, or nothing ticked), wraps its label
// at every text size and stacks its control under the label at the
// accessibility sizes. No row draws a card of its own: they sit in the
// section's one card, separated by the card's own spacing.

/// The label above or beside a control: wraps, never truncates.
struct LifeRowLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.hlSubhead)
            .foregroundStyle(HLText.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Label and trailing control on one line, or stacked at accessibility sizes.
struct LifeAdaptiveRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: () -> Control
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                LifeRowLabel(text: label)
                control()
            }
        } else {
            HStack(alignment: .center, spacing: HLSpace.md) {
                LifeRowLabel(text: label).layoutPriority(1)
                control()
            }
        }
    }
}

/// One answer out of a closed list, with "no answer" first.
struct LifeChoiceRow<Value: Hashable>: View {
    let label: String
    let options: [Value]
    let title: (Value) -> String
    @Binding var selection: Value?
    var identifier: String

    var body: some View {
        LifeAdaptiveRow(label: label) {
            Picker(selection: $selection) {
                Text("life.noAnswer").tag(Value?.none)
                ForEach(options, id: \.self) { option in
                    Text(verbatim: title(option)).tag(Value?.some(option))
                }
            } label: {
                Text(verbatim: label)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(HLText.secondary)
            .accessibilityLabel(Text(verbatim: label))
            .accessibilityIdentifier(identifier)
        }
    }
}

/// Yes, no or no answer.
struct LifeBoolRow: View {
    let label: String
    @Binding var value: Bool?
    var identifier: String

    var body: some View {
        LifeChoiceRow(
            label: label,
            options: [true, false],
            title: { $0 ? String(localized: "life.yes") : String(localized: "life.no") },
            selection: $value,
            identifier: identifier
        )
    }
}

/// Any number of answers out of a closed list, as tick rows. `limit` stops
/// further ticks once reached (goals: three).
struct LifeMultiChoiceRows<Value: Hashable>: View {
    let label: String
    var hint: String?
    let options: [Value]
    let title: (Value) -> String
    @Binding var selection: [Value]
    var limit: Int?
    var identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            LifeRowLabel(text: label)
            if let hint {
                Text(verbatim: hint)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                tickRow(option, index: index)
            }
        }
    }

    private func tickRow(_ option: Value, index: Int) -> some View {
        let isOn = selection.contains(option)
        let isFull = limit.map { selection.count >= $0 } ?? false
        return Button {
            toggle(option)
        } label: {
            HStack(spacing: HLSpace.sm) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? HLAccent.userBrandTint : HLText.tertiary)
                    .accessibilityHidden(true)
                Text(verbatim: title(option))
                    .font(.hlBody)
                    .foregroundStyle(HLText.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isOn && isFull)
        .accessibilityLabel(Text(verbatim: title(option)))
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("\(identifier).\(index)")
    }

    /// Keeps the ticked answers in the list's own order.
    private func toggle(_ option: Value) {
        var set = Set(selection)
        if set.contains(option) { set.remove(option) } else { set.insert(option) }
        selection = options.filter { set.contains($0) }
    }
}

/// A whole number typed on the number pad, clamped to `range`. Empty is "no
/// answer".
struct LifeNumberRow: View {
    let label: String
    let range: ClosedRange<Int>
    @Binding var value: Int?
    var identifier: String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LifeAdaptiveRow(label: label) {
            TextField(String(localized: "life.noAnswer"), text: $text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(.hlBody)
                .frame(minWidth: 72, maxWidth: 140)
                .focused($focused)
                .accessibilityLabel(Text(verbatim: label))
                .accessibilityIdentifier(identifier)
                .onAppear { text = value.map(String.init) ?? "" }
                .onChange(of: text) { _, new in
                    let digits = new.filter(\.isNumber)
                    guard !digits.isEmpty, let parsed = Int(digits) else {
                        value = nil
                        return
                    }
                    value = min(max(parsed, range.lowerBound), range.upperBound)
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { text = value.map(String.init) ?? "" }
                }
                .onChange(of: value) { _, new in
                    if !focused { text = new.map(String.init) ?? "" }
                }
        }
    }
}

/// Hours in half-hour steps, 0 to 24 (sitting on a workday).
struct LifeHalfHourRow: View {
    let label: String
    @Binding var value: Double?
    var identifier: String

    private static let options: [Double] = stride(from: 0.0, through: 24.0, by: 0.5).map { $0 }

    var body: some View {
        LifeChoiceRow(
            label: label,
            options: Self.options,
            title: { $0.formatted(.number.precision(.fractionLength(0 ... 1))) },
            selection: $value,
            identifier: identifier
        )
    }
}

/// A year out of `earliest…this year`, newest first.
struct LifeYearRow: View {
    let label: String
    let earliest: Int
    @Binding var value: Int?
    var identifier: String

    var body: some View {
        let latest = Calendar.current.component(.year, from: .now)
        LifeChoiceRow(
            label: label,
            options: Array((earliest ... max(earliest, latest)).reversed()),
            title: { String($0) },
            selection: $value,
            identifier: identifier
        )
    }
}
