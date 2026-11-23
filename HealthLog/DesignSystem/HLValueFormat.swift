import Foundation

/// The units values are shown in.
///
/// International symbols are the same in every language; the few units that
/// are words come from the catalogue. A unit the app does not know (a lab
/// value's unit from the server, the unit of a metric the user defined) is
/// passed through as it is.
public enum HLUnit: Equatable, Sendable {
    /// A bare number: a count, a score.
    case plain
    case percent
    case kilograms
    case pounds
    case millimetersOfMercury
    case beatsPerMinute
    case milliseconds
    case celsius
    case fahrenheit
    case milligramsPerDeciliter
    case millimolesPerLiter
    case kilocalories
    case steps
    case minutes
    case hours
    case meters
    case kilometers
    case centimeters
    case metersPerSecond
    case milliliters
    case milligrams
    /// A unit given as text.
    case custom(String)

    /// The unit for a symbol as the models and the server spell it. Unknown
    /// symbols stay what they are.
    public init(symbol: String) {
        let trimmed = symbol.trimmingCharacters(in: .whitespaces)
        self = Self.known[trimmed] ?? (trimmed.isEmpty ? .plain : .custom(trimmed))
    }

    private static let known: [String: HLUnit] = [
        "%": .percent,
        "kg": .kilograms,
        "lb": .pounds,
        "mmHg": .millimetersOfMercury,
        "bpm": .beatsPerMinute,
        "ms": .milliseconds,
        "°C": .celsius,
        "°F": .fahrenheit,
        "mg/dL": .milligramsPerDeciliter,
        "mmol/L": .millimolesPerLiter,
        "kcal": .kilocalories,
        "steps": .steps,
        "min": .minutes,
        "h": .hours,
        "m": .meters,
        "km": .kilometers,
        "cm": .centimeters,
        "m/s": .metersPerSecond,
        "ml": .milliliters,
        "mL": .milliliters,
        "mg": .milligrams
    ]

    /// What stands after the number, or `nil` for a bare number.
    public var symbol: String? {
        switch self {
        case .plain: nil
        case .percent: "%"
        case .kilograms: "kg"
        case .pounds: "lb"
        case .millimetersOfMercury: "mmHg"
        case .beatsPerMinute: "bpm"
        case .milliseconds: "ms"
        case .celsius: "°C"
        case .fahrenheit: "°F"
        case .milligramsPerDeciliter: "mg/dL"
        case .millimolesPerLiter: "mmol/L"
        case .kilocalories: "kcal"
        case .steps: String(localized: "steps")
        case .minutes: String(localized: "min")
        case .hours: String(localized: "unit.hours.short")
        case .meters: "m"
        case .kilometers: "km"
        case .centimeters: "cm"
        case .metersPerSecond: "m/s"
        case .milliliters: "ml"
        case .milligrams: "mg"
        case let .custom(text): text.isEmpty ? nil : text
        }
    }
}

/// A value split into what stands before the number, the number, and what
/// stands after it, so a view can set the number larger than its unit.
public struct HLValueParts: Equatable, Sendable {
    public let leading: String
    public let number: String
    public let trailing: String

    public var joined: String {
        leading + number + trailing
    }
}

/// A number with its unit, the same way everywhere.
public enum HLValueFormat {
    /// What stands in place of a value that is not there.
    public static let placeholder = "—"
    /// Decimal places when the caller names none: none for a whole number,
    /// one otherwise.
    public static let defaultFractionDigits = 0 ... 1

    /// "72,4 kg", "83 %", "12.345 Schritte". The gap between number and unit
    /// is a narrow no-break space, so the two never part at a line end; the
    /// percent sign stands where the locale puts it.
    public static func string(
        _ value: Double,
        unit: HLUnit,
        fractionDigits: ClosedRange<Int>? = nil,
        locale: Locale = .current
    ) -> String {
        parts(value, unit: unit, fractionDigits: fractionDigits, locale: locale).joined
    }

    /// The same, or the placeholder when there is no value.
    public static func string(
        _ value: Double?,
        unit: HLUnit,
        fractionDigits: ClosedRange<Int>? = nil,
        locale: Locale = .current
    ) -> String {
        guard let value else { return placeholder }
        return string(value, unit: unit, fractionDigits: fractionDigits, locale: locale)
    }

    /// The number alone, with the locale's separators.
    ///
    /// - Parameter grouping: `.never` for a number that is typed or read back
    ///   as typed text, such as the example in an empty field: "8000" stays
    ///   "8000", because "8.000" reads back as eight.
    public static func number(
        _ value: Double,
        fractionDigits: ClosedRange<Int>? = nil,
        grouping: NumberFormatStyleConfiguration.Grouping = .automatic,
        locale: Locale = .current
    ) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(fractionDigits ?? defaultFractionDigits))
                .grouping(grouping)
                .locale(locale)
        )
    }

    /// The number with its sign in front, for a change: "+1,2", "-0,4", and
    /// a bare "0" where nothing changed.
    public static func signedNumber(
        _ value: Double,
        fractionDigits: ClosedRange<Int>? = nil,
        locale: Locale = .current
    ) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(fractionDigits ?? defaultFractionDigits))
                .sign(strategy: .always(includingZero: false))
                .locale(locale)
        )
    }

    /// Two numbers of one reading with the unit once at the end:
    /// "128/82 mmHg".
    public static func pair(
        _ first: Double,
        _ second: Double,
        unit: HLUnit,
        fractionDigits: ClosedRange<Int>? = nil,
        locale: Locale = .current
    ) -> String {
        pairParts(first, second, unit: unit, fractionDigits: fractionDigits, locale: locale).joined
    }

    /// A span between two values in words, the unit once at the end:
    /// "60 bis 100 bpm".
    public static func range(
        _ lower: Double,
        _ upper: Double,
        unit: HLUnit,
        fractionDigits: ClosedRange<Int>? = nil,
        locale: Locale = .current
    ) -> String {
        rangeParts(lower, upper, unit: unit, fractionDigits: fractionDigits, locale: locale).joined
    }

    /// A change with its sign: "+1,2 kg", "-0,4 kg".
    public static func delta(
        _ value: Double,
        unit: HLUnit,
        fractionDigits: ClosedRange<Int>? = nil,
        locale: Locale = .current
    ) -> String {
        deltaParts(value, unit: unit, fractionDigits: fractionDigits, locale: locale).joined
    }

    public static func parts(
        _ value: Double,
        unit: HLUnit,
        fractionDigits: ClosedRange<Int>? = nil,
        locale: Locale = .current
    ) -> HLValueParts {
        parts(
            formatted: number(value, fractionDigits: fractionDigits, locale: locale),
            unit: unit,
            locale: locale
        )
    }

    public static func pairParts(
        _ first: Double,
        _ second: Double,
        unit: HLUnit,
        fractionDigits: ClosedRange<Int>? = nil,
        locale: Locale = .current
    ) -> HLValueParts {
        let numbers = [first, second].map { number($0, fractionDigits: fractionDigits, locale: locale) }
        return parts(formatted: numbers.joined(separator: pairSeparator), unit: unit, locale: locale)
    }

    public static func rangeParts(
        _ lower: Double,
        _ upper: Double,
        unit: HLUnit,
        fractionDigits: ClosedRange<Int>? = nil,
        locale: Locale = .current
    ) -> HLValueParts {
        let span = HLNumberFormat.range(
            number(lower, fractionDigits: fractionDigits, locale: locale),
            number(upper, fractionDigits: fractionDigits, locale: locale)
        )
        return parts(formatted: span, unit: unit, locale: locale)
    }

    public static func deltaParts(
        _ value: Double,
        unit: HLUnit,
        fractionDigits: ClosedRange<Int>? = nil,
        locale: Locale = .current
    ) -> HLValueParts {
        parts(
            formatted: signedNumber(value, fractionDigits: fractionDigits, locale: locale),
            unit: unit,
            locale: locale
        )
    }

    /// What stands between the two numbers of a pair.
    public static let pairSeparator = "/"

    /// Puts the unit around text that is already formatted: one number, a
    /// pair, a span.
    private static func parts(formatted number: String, unit: HLUnit, locale: Locale) -> HLValueParts {
        guard let symbol = unit.symbol else {
            return HLValueParts(leading: "", number: number, trailing: "")
        }
        guard unit == .percent else {
            return HLValueParts(
                leading: "",
                number: number,
                trailing: HLNumberFormat.narrowNoBreakSpace + symbol
            )
        }
        let whole = HLNumberFormat.percent(formattedNumber: number, locale: locale)
        guard let range = whole.range(of: number) else {
            return HLValueParts(leading: "", number: whole, trailing: "")
        }
        return HLValueParts(
            leading: String(whole[..<range.lowerBound]),
            number: number,
            trailing: String(whole[range.upperBound...])
        )
    }
}
