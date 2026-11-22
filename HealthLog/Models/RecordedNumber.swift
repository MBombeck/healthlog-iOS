import Foundation

/// How many digits a number somebody recorded is printed with.
///
/// The rule of the server's `recorded-number.ts`: a stored value keeps every
/// digit it holds (TSH 0.004 is not "0"), read back at twelve significant
/// digits so binary noise goes and nothing a person typed does. A value the
/// server converted from the printed unit keeps as many significant digits as
/// the printed figure had, at least three and never fewer than its own
/// integer digits, so 5.2 mmol/L reads 201 mg/dL.
public enum RecordedNumber {
    static let storedSignificantDigits = 12
    static let convertedMinSignificantDigits = 3
    static let maxFractionDigits = 20

    /// The value to print and the number of decimals it carries. `printed` is
    /// the figure the report printed when `value` was converted from it.
    public static func precision(_ value: Double, printed: Double? = nil) -> (value: Double, fractionDigits: Int) {
        guard value.isFinite, value != 0 else { return (value, 0) }
        var significant = storedSignificantDigits
        if let printed, printed.isFinite, printed != 0 {
            let integerDigits = max(1, shape(value).exponent + 1)
            significant = max(shape(printed).digits, convertedMinSignificantDigits, integerDigits)
        }
        let rounded = rounding(value, significantDigits: significant)
        let (digits, exponent) = shape(rounded)
        return (rounded, min(maxFractionDigits, max(0, digits - 1 - exponent)))
    }

    /// The number in `locale`, with every digit it holds.
    public static func text(_ value: Double, printed: Double? = nil, locale: Locale = .current) -> String {
        let (rounded, fractionDigits) = precision(value, printed: printed)
        return rounded.formatted(.number.precision(.fractionLength(fractionDigits)).locale(locale))
    }

    private static func rounding(_ value: Double, significantDigits: Int) -> Double {
        // `String(format:)` without a locale prints the C spelling `Double` parses.
        Double(String(format: "%.\(max(0, significantDigits - 1))e", value)) ?? value
    }

    /// Significant digits and decimal exponent of a finite, nonzero number,
    /// read from its shortest spelling that parses back to the same value.
    private static func shape(_ number: Double) -> (digits: Int, exponent: Int) {
        let parts = "\(abs(number))".lowercased().split(separator: "e", maxSplits: 1)
        let mantissa = parts.first.map(String.init) ?? "0"
        let power = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let halves = mantissa.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let integerPart = halves.first.map(String.init) ?? ""
        let fractionPart = halves.count > 1 ? String(halves[1]) : ""
        let all = Array(integerPart + fractionPart)
        guard let first = all.firstIndex(where: { $0 != "0" }),
              let last = all.lastIndex(where: { $0 != "0" }) else { return (1, 0) }
        return (last - first + 1, integerPart.count - first - 1 + power)
    }
}
