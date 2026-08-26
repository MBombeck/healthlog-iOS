import Foundation

/// Pure, view-agnostic presentation helpers for the nutrient read surfaces —
/// the German (localized) display name per catalog code, the human unit glyph,
/// and amount / progress formatting. Kept out of the SwiftUI layer so it stays
/// unit-testable.
///
/// **Names are localized**, not hardcoded here: every catalog code maps to a
/// stable xcstrings key `nutrients.names.<rawValue>` (mirrors the server's own
/// `nutrients.names.<code>` i18n key). The screen resolves the key; this enum
/// only produces it.
public enum NutrientDisplay {
    /// The xcstrings key for a nutrient's display name — `nutrients.names.<code>`.
    public static func nameKey(for code: NutrientCode) -> String {
        "nutrients.names.\(code.rawValue)"
    }

    /// The localized display name for a nutrient (resolves the `nameKey`).
    public static func name(for code: NutrientCode) -> String {
        String(localized: String.LocalizationValue(nameKey(for: code)))
    }

    /// Human unit glyph for a wire unit string — `ug` renders as `µg`, `ml`/`mg`
    /// pass through, and any unknown unit renders verbatim (tolerant).
    public static func unitGlyph(_ wireUnit: String) -> String {
        switch wireUnit {
        case "ug": "µg"
        case "ml": "ml"
        case "mg": "mg"
        default: wireUnit
        }
    }

    /// Format an amount + its unit for display, e.g. `88 mg`, `1.500 ml`,
    /// `1,5 µg`. Whole numbers drop the fraction; sub-integer values keep up to
    /// two decimals (locale-aware grouping + separators).
    public static func formatted(amount: Double, wireUnit: String, locale: Locale = .current) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.maximumFractionDigits = amount < 10 && amount != amount.rounded() ? 2 : 0
        f.minimumFractionDigits = 0
        let number = f.string(from: NSNumber(value: amount)) ?? "\(amount)"
        return "\(number) \(unitGlyph(wireUnit))"
    }

    /// Fraction (0…) of an amount against a reference value. `nil` when there is
    /// no reference or a non-positive reference (avoids a divide-by-zero and an
    /// "∞ %" render). NOT clamped — a value over the reference reads > 1 so the
    /// UI can show "over target" honestly.
    public static func progressFraction(amount: Double, reference: Double?) -> Double? {
        guard let reference, reference > 0 else { return nil }
        return amount / reference
    }
}
