import SwiftUI

/// Where a value stands decides how large it is set.
public enum HLValueSize: Equatable, Sendable {
    /// In a row or a list: as large as the row title and one weight
    /// lighter, so the value reads without outweighing the name beside it.
    case row
    /// In a cell of a tile grid (Min/Ø/Max, sleep stages, a workout's
    /// figures), under a 12 pt label.
    case compact
    /// On a tile or as the lead value of a card.
    case tile
    /// As the one large value at the top of a detail page.
    case hero

    /// Font of the number. Only the sizes off the row grid use the rounded
    /// metric face; in a row the number is set like the text around it.
    public var numberFont: Font {
        switch self {
        case .row: .hlSubhead.weight(.medium)
        case .compact: .hlMetric(.body)
        case .tile: .hlMetric(.title)
        case .hero: .hlMetric(.largeTitle)
        }
    }

    /// Font of the unit, quieter than the number on the same baseline.
    public var unitFont: Font {
        switch self {
        case .row: .hlSubhead
        case .compact: .hlCaption
        case .tile, .hero: .hlSubhead
        }
    }
}

/// A value with its unit: the number in the rounded metric face with digits
/// of equal width, the unit one step smaller and quieter on the same
/// baseline.
///
/// A missing value shows the placeholder; VoiceOver hears "No data" instead.
public struct HLValueText: View {
    /// What the text shows. A reading with a missing number shows the
    /// placeholder as a whole.
    private enum Reading {
        case single(Double?)
        case pair(Double?, Double?)
        case range(Double?, Double?)
        case delta(Double?)
    }

    private let reading: Reading
    private let unit: HLUnit
    private let size: HLValueSize
    private let fractionDigits: ClosedRange<Int>?

    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(
        _ value: Double?,
        unit: HLUnit,
        size: HLValueSize = .row,
        fractionDigits: ClosedRange<Int>? = nil
    ) {
        reading = .single(value)
        self.unit = unit
        self.size = size
        self.fractionDigits = fractionDigits
    }

    /// Two numbers of one reading: "128/82 mmHg".
    public init(
        _ first: Double?,
        _ second: Double?,
        unit: HLUnit,
        size: HLValueSize = .row,
        fractionDigits: ClosedRange<Int>? = nil
    ) {
        reading = .pair(first, second)
        self.unit = unit
        self.size = size
        self.fractionDigits = fractionDigits
    }

    /// A span between two values: "60 bis 100 bpm".
    public init(
        range lower: Double?,
        _ upper: Double?,
        unit: HLUnit,
        size: HLValueSize = .row,
        fractionDigits: ClosedRange<Int>? = nil
    ) {
        reading = .range(lower, upper)
        self.unit = unit
        self.size = size
        self.fractionDigits = fractionDigits
    }

    /// A change with its sign: "+1,2 kg".
    public init(
        delta value: Double?,
        unit: HLUnit,
        size: HLValueSize = .row,
        fractionDigits: ClosedRange<Int>? = nil
    ) {
        reading = .delta(value)
        self.unit = unit
        self.size = size
        self.fractionDigits = fractionDigits
    }

    private var parts: HLValueParts? {
        switch reading {
        case let .single(value):
            value.map { HLValueFormat.parts($0, unit: unit, fractionDigits: fractionDigits, locale: locale) }
        case let .pair(first?, second?):
            HLValueFormat.pairParts(first, second, unit: unit, fractionDigits: fractionDigits, locale: locale)
        case let .range(lower?, upper?):
            HLValueFormat.rangeParts(lower, upper, unit: unit, fractionDigits: fractionDigits, locale: locale)
        case let .delta(value):
            value.map { HLValueFormat.deltaParts($0, unit: unit, fractionDigits: fractionDigits, locale: locale) }
        case .pair, .range:
            nil
        }
    }

    public var body: some View {
        if let parts {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    // A reading is never cut short. Where number and unit
                    // do not fit side by side, the unit moves under it.
                    ViewThatFits(in: .horizontal) {
                        line(parts)
                        stacked(parts)
                    }
                } else {
                    line(parts)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: parts.joined))
        } else {
            Text(verbatim: HLValueFormat.placeholder)
                .font(size.numberFont)
                .foregroundStyle(HLText.tertiary)
                .accessibilityLabel(Text("No data"))
        }
    }

    private func line(_ parts: HLValueParts) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if !parts.leading.isEmpty { unitText(parts.leading) }
            numberText(parts.number)
            if !parts.trailing.isEmpty { unitText(parts.trailing) }
        }
        .lineLimit(1)
    }

    private func stacked(_ parts: HLValueParts) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if !parts.leading.isEmpty { unitText(parts.leading) }
                numberText(parts.number)
                    .minimumScaleFactor(0.5)
            }
            // On its own line the unit needs no gap in front of it.
            if !parts.trailing.isEmpty { unitText(parts.trailing.trimmingCharacters(in: .whitespaces)) }
        }
        .lineLimit(1)
    }

    private func numberText(_ number: String) -> some View {
        Text(verbatim: number)
            .font(size.numberFont)
            .monospacedDigit()
            .foregroundStyle(HLText.primary)
            .hlNumericChange(number)
    }

    private func unitText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(size.unitFont)
            .foregroundStyle(HLText.secondary)
    }
}

#Preview("HLValueText, light") {
    HLValueTextPreview()
        .preferredColorScheme(.light)
}

#Preview("HLValueText, dark") {
    HLValueTextPreview()
        .preferredColorScheme(.dark)
}

#Preview("HLValueText, largest type") {
    HLValueTextPreview()
        .dynamicTypeSize(.accessibility5)
}

private struct HLValueTextPreview: View {
    var body: some View {
        HLPage {
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    HLValueText(72.4, unit: .kilograms, size: .hero)
                    HLValueText(83, unit: .percent, size: .tile)
                    HLValueText(61.8, unit: .kilograms, size: .compact)
                    HLRowLayout(title: "Pulse") {
                        HLValueText(64, unit: .beatsPerMinute)
                    }
                    HLRowLayout(title: "Blood pressure") {
                        HLValueText(128, 82, unit: .millimetersOfMercury)
                    }
                    HLRowLayout(title: "Target range") {
                        HLValueText(range: 60, 100, unit: .beatsPerMinute)
                    }
                    HLRowLayout(title: "Weight") {
                        HLValueText(delta: -0.4, unit: .kilograms)
                    }
                    HLRowLayout(title: "Sleep") {
                        HLValueText(nil, unit: .hours)
                    }
                }
            }
        }
    }
}

/// How a shown number changes: its digits roll to the new value in one
/// snappy beat, so a new period shows which figure moved and how far. With
/// Reduce Motion the new value fades in instead.
struct HLNumericChange: ViewModifier {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? .opacity : .numericText())
            .hlAnimation(.snappy(duration: 0.3), value: text)
    }
}

extension View {
    /// Rolls the digits of `text` when it changes (``HLNumericChange``).
    func hlNumericChange(_ text: String) -> some View {
        modifier(HLNumericChange(text: text))
    }
}
