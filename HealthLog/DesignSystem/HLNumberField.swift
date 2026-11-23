import SwiftUI

/// How typed text becomes a number and a number becomes text again.
///
/// `fractionDigits` means the same as in ``HLValueFormat``: the least and
/// the most decimal places, and without a word from the caller none for a
/// whole number and one otherwise.
public enum HLNumberEntry {
    /// What a field holds.
    public enum State: Equatable, Sendable {
        /// Nothing typed yet.
        case empty
        /// A number the field takes.
        case valid(Double)
        /// A number, but outside the range the field allows.
        case outOfRange
        /// Text that is no number.
        case unreadable

        /// The number, when the field holds one it takes.
        public var value: Double? {
            if case let .valid(value) = self { return value }
            return nil
        }

        /// Whether the field holds something it cannot take.
        public var isRejected: Bool {
            self == .outOfRange || self == .unreadable
        }
    }

    /// What the text stands for. More decimal places than the field has are
    /// rounded away; a number outside `range` is not pulled to the nearest
    /// bound.
    public static func state(
        of text: String,
        range: ClosedRange<Double>? = nil,
        fractionDigits: ClosedRange<Int>? = nil,
        locale: Locale = .current
    ) -> State {
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return .empty }
        guard let parsed = LocaleDecimalParser.parse(text, locale: locale) else { return .unreadable }
        let scale = pow(10, Double(mostDigits(fractionDigits)))
        let rounded = (parsed * scale).rounded() / scale
        if let range, !range.contains(rounded) { return .outOfRange }
        return .valid(rounded)
    }

    /// The number the text stands for, or `nil` when the field is empty, the
    /// text is no number, or the number lies outside `range`.
    public static func value(
        from text: String,
        range: ClosedRange<Double>? = nil,
        fractionDigits: ClosedRange<Int>? = nil,
        locale: Locale = .current
    ) -> Double? {
        state(of: text, range: range, fractionDigits: fractionDigits, locale: locale).value
    }

    /// Whether the text is something the field cannot take: not empty, and
    /// still no value.
    public static func isRejected(
        _ text: String,
        range: ClosedRange<Double>? = nil,
        fractionDigits: ClosedRange<Int>? = nil,
        locale: Locale = .current
    ) -> Bool {
        state(of: text, range: range, fractionDigits: fractionDigits, locale: locale).isRejected
    }

    /// The text a value is shown as while it is edited: the locale's decimal
    /// separator, no grouping, no more decimal places than needed.
    public static func text(
        for value: Double?,
        fractionDigits: ClosedRange<Int>? = nil,
        locale: Locale = .current
    ) -> String {
        guard let value else { return "" }
        return value.formatted(
            .number
                .precision(.fractionLength(0 ... mostDigits(fractionDigits)))
                .grouping(.never)
                .locale(locale)
        )
    }

    /// What an empty field shows in place of a number: "e.g. 30". The words
    /// in front are the point, a bare grey number reads as a value that is
    /// already there. A zero is no example and gives `nil`.
    public static func exampleText(
        for example: Double?,
        fractionDigits: ClosedRange<Int>? = nil,
        locale: Locale = .current
    ) -> String? {
        guard let example, example != 0 else { return nil }
        return String(
            format: String(localized: "numberfield.example"),
            text(for: example, fractionDigits: fractionDigits, locale: locale)
        )
    }

    /// What the field says under its row about text it cannot take, or `nil`
    /// when there is nothing to say.
    public static func message(
        for state: State,
        range: ClosedRange<Double>? = nil,
        fractionDigits: ClosedRange<Int>? = nil,
        locale: Locale = .current
    ) -> String? {
        switch state {
        case .empty, .valid:
            return nil
        case .unreadable:
            return String(localized: "numberfield.error.unreadable")
        case .outOfRange:
            guard let range else { return String(localized: "numberfield.error.unreadable") }
            let span = HLNumberFormat.range(
                text(for: range.lowerBound, fractionDigits: fractionDigits, locale: locale),
                text(for: range.upperBound, fractionDigits: fractionDigits, locale: locale)
            )
            return String(format: String(localized: "numberfield.error.outOfRange"), span)
        }
    }

    /// The most decimal places a field with these digits takes.
    static func mostDigits(_ fractionDigits: ClosedRange<Int>?) -> Int {
        max(0, (fractionDigits ?? HLValueFormat.defaultFractionDigits).upperBound)
    }
}

/// The one field for entering a number: title at the leading edge, the number
/// and its unit at the trailing edge. At the accessibility sizes the title
/// stands above the number.
///
/// The bound value is `nil` as long as the field holds nothing usable. What
/// exactly it holds (nothing, a number, a number outside the range, no
/// number) goes out through `state`. Text the field cannot take is not
/// corrected behind the user's back: once the field loses the focus it says
/// under its row what is wrong, and it stays quiet while the user is typing.
///
/// A form that moves the cursor itself binds the field like a text field:
/// `HLNumberField(…).focused($field, equals: .weight)`.
public struct HLNumberField: View {
    private let title: LocalizedStringKey
    @Binding private var value: Double?
    private let state: Binding<HLNumberEntry.State>?
    private let unit: HLUnit
    private let range: ClosedRange<Double>?
    private let fractionDigits: ClosedRange<Int>?
    private let example: Double?
    /// Binds the text field itself to the form's focus state. `nil` as long
    /// as the form does not move the cursor.
    private var formFocus: ((AnyView) -> AnyView)?

    @State private var text = ""
    @FocusState private var isFocused: Bool
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// - Parameter example: a number the empty field shows as "e.g. 30", for
    ///   a field whose title alone does not say what size of number is meant.
    public init(
        _ title: LocalizedStringKey,
        value: Binding<Double?>,
        state: Binding<HLNumberEntry.State>? = nil,
        unit: HLUnit,
        range: ClosedRange<Double>? = nil,
        fractionDigits: ClosedRange<Int>? = nil,
        example: Double? = nil
    ) {
        self.title = title
        _value = value
        self.state = state
        self.unit = unit
        self.range = range
        self.fractionDigits = fractionDigits
        self.example = example
    }

    /// Whether a form has bound this field to its own focus state.
    public var followsFormFocus: Bool {
        formFocus != nil
    }

    /// Binds the field to one case of a form's focus state, so the form can
    /// put the cursor into it and a keyboard key can move on from it.
    public func focused<Value: Hashable>(_ binding: FocusState<Value?>.Binding, equals value: Value) -> HLNumberField {
        var field = self
        field.formFocus = { AnyView($0.focused(binding, equals: value)) }
        return field
    }

    /// Binds the field to a form's focus flag.
    public func focused(_ binding: FocusState<Bool>.Binding) -> HLNumberField {
        var field = self
        field.formFocus = { AnyView($0.focused(binding)) }
        return field
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            row
                .frame(minHeight: HLLayout.rowMinHeight)
                .contentShape(Rectangle())
                .onTapGesture { isFocused = true }
            if let shownMessage {
                HLFormErrorText(shownMessage)
                    .font(.hlFootnote)
                    .padding(.bottom, HLSpace.xs)
            }
        }
        .onAppear {
            text = HLNumberEntry.text(for: value, fractionDigits: fractionDigits, locale: locale)
            publish(entry(text))
        }
        .onChange(of: text) { _, newText in
            let entry = entry(newText)
            if entry.value != value { value = entry.value }
            publish(entry)
        }
        .onChange(of: value) { _, newValue in
            // Only a change from outside rewrites the text; what the user is
            // typing ("72," on the way to "72,4") stays as typed.
            if entry(text).value != newValue {
                text = HLNumberEntry.text(for: newValue, fractionDigits: fractionDigits, locale: locale)
            }
        }
    }

    @ViewBuilder
    private var row: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                HLRowTitle(title)
                    .accessibilityHidden(true)
                input(alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                HLRowTitle(title)
                    .accessibilityHidden(true)
                input(alignment: .trailing)
            }
        }
    }

    /// Number and unit, joined the way ``HLValueText`` joins them, so
    /// "72,4 kg" reads the same in a field and in a row.
    private func input(alignment: TextAlignment) -> some View {
        let affix = HLValueFormat.parts(0, unit: unit, locale: locale)
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            if !affix.leading.isEmpty { unitText(affix.leading) }
            textField(alignment: alignment)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(verbatim: text + affix.trailing))
                .accessibilityHint(Text(verbatim: shownMessage ?? ""))
            if !affix.trailing.isEmpty { unitText(affix.trailing) }
        }
    }

    @ViewBuilder
    private func textField(alignment: TextAlignment) -> some View {
        let field = bareTextField(alignment: alignment)
        if let formFocus {
            formFocus(AnyView(field))
        } else {
            field
        }
    }

    private func bareTextField(alignment: TextAlignment) -> some View {
        // Without an example the field stays blank: a grey zero read as the
        // value "0".
        TextField(text: $text) {
            Text(verbatim: examplePrompt ?? "")
        }
        .font(.hlBody)
        .monospacedDigit()
        .multilineTextAlignment(alignment)
        .keyboardType(keyboard)
        .foregroundStyle(showsRejection ? HLColor.statusBad : HLText.primary)
        .focused($isFocused)
        // Under the title the field is as wide as its text, so the unit
        // follows the number and does not stand at the far edge.
        .fixedSize(horizontal: alignment == .leading, vertical: false)
    }

    private var examplePrompt: String? {
        HLNumberEntry.exampleText(for: example, fractionDigits: fractionDigits, locale: locale)
    }

    private func unitText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.hlBody)
            .foregroundStyle(HLText.secondary)
            .accessibilityHidden(true)
    }

    private func entry(_ text: String) -> HLNumberEntry.State {
        HLNumberEntry.state(of: text, range: range, fractionDigits: fractionDigits, locale: locale)
    }

    private func publish(_ entry: HLNumberEntry.State) {
        guard let state, state.wrappedValue != entry else { return }
        state.wrappedValue = entry
    }

    /// The field speaks up only after the user has left it: "2" on the way
    /// to "25" is not an error yet.
    private var showsRejection: Bool {
        !isFocused && entry(text).isRejected
    }

    private var shownMessage: String? {
        guard showsRejection else { return nil }
        return HLNumberEntry.message(for: entry(text), range: range, fractionDigits: fractionDigits, locale: locale)
    }

    private var keyboard: UIKeyboardType {
        // The number pads have no minus sign.
        if let range, range.lowerBound < 0 { return .numbersAndPunctuation }
        return HLNumberEntry.mostDigits(fractionDigits) == 0 ? .numberPad : .decimalPad
    }
}

#Preview("HLNumberField, light") {
    HLNumberFieldPreview()
        .preferredColorScheme(.light)
}

#Preview("HLNumberField, dark") {
    HLNumberFieldPreview()
        .preferredColorScheme(.dark)
}

#Preview("HLNumberField, largest type") {
    HLNumberFieldPreview()
        .dynamicTypeSize(.accessibility5)
}

private struct HLNumberFieldPreview: View {
    @State private var weight: Double? = 72.4
    @State private var pulse: Double?

    var body: some View {
        HLSheetScaffold("Log a measurement", action: .save(isEnabled: weight != nil) { true }) {
            Form {
                Section {
                    HLNumberField("Weight", value: $weight, unit: .kilograms, range: 20 ... 300)
                    HLNumberField(
                        "Pulse",
                        value: $pulse,
                        unit: .beatsPerMinute,
                        range: 20 ... 250,
                        fractionDigits: 0 ... 0,
                        example: 60
                    )
                }
                .hlFormRowSurface()
            }
        }
    }
}
