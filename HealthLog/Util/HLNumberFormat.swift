import Foundation

/// Locale-aware fixed-fraction decimal formatting for **display** values
/// (L10N-5). The codebase historically rendered display numbers with
/// `String(format: "%.1f", value)`, which is locale-*less*: it always emits a
/// decimal **point**, so a German (`de-DE`) user saw "7.5 mg" where the correct
/// primary-locale rendering is "7,5 mg". A wrong decimal separator on a *dose*
/// is a safety-relevant bug, not just polish.
///
/// This is the display-side counterpart to `LocaleDecimalParser` (which owns
/// the *input* seam). It routes through `FloatingPointFormatStyle` so the
/// user's `Locale` decides the separator; the fraction length is fixed so the
/// precision matches the old `%.Nf` exactly. Do not reintroduce
/// `String(format: "%.Nf", …)` for user-facing numbers — use this seam.
public enum HLNumberFormat {
    /// Fixed-fraction, locale-aware decimal. Precision-equivalent to
    /// `String(format: "%.\(fractionDigits)f", value)` but with a
    /// locale-correct decimal separator (comma under `de-DE`).
    ///
    /// - Parameters:
    ///   - value: the number to render.
    ///   - fractionDigits: exact number of fraction digits (as `%.Nf`).
    ///   - locale: locale providing the decimal separator; defaults to
    ///     `.current` so it follows the running UI locale.
    public static func decimal(
        _ value: Double,
        fractionDigits: Int,
        locale: Locale = .current
    ) -> String {
        value.formatted(
            .number.precision(.fractionLength(fractionDigits)).locale(locale)
        )
    }

    /// The DIN-5008 / Web-style gap between a number and the percent sign: a
    /// NARROW NO-BREAK SPACE (U+202F). It keeps "83 %" on one line and reads
    /// tighter than a normal space — this is what the web client renders for
    /// German. Whether a locale puts a gap before the sign at all is the
    /// locale's call (see `percent(formattedNumber:locale:)`): English writes
    /// "83%", German "83 %". Exposed for the rare call site that needs the
    /// glyph itself.
    public static let narrowNoBreakSpace = "\u{202F}"

    /// A whole-number percentage of a 0…1 fraction, rounded half away from
    /// zero: 2 of 3 is 67, not 66.
    ///
    /// F1 (App-Store screenshots, 1.1.0) — `Int(ratio * 100)` truncates, so the
    /// dashboard read "66 %" for two of three doses. Every ratio→percent
    /// conversion goes through here. A non-finite fraction has no percentage
    /// to show and maps to 0; callers that can reach 0/0 guard it themselves
    /// (they render their own empty/unknown state, never an invented 0 %).
    public static func percentValue(ofFraction fraction: Double) -> Int {
        guard fraction.isFinite else { return 0 }
        return Int((fraction * 100).rounded())
    }

    /// Renders a 0…1 fraction as a rounded whole percentage ("67 %" / "67%").
    public static func percent(fraction: Double, locale: Locale = .current) -> String {
        percent(percentValue(ofFraction: fraction), locale: locale)
    }

    /// Renders an integer percentage the way `locale` writes one. Use this
    /// instead of interpolating a number directly in front of a percent sign
    /// for any user-facing percentage.
    ///
    /// - German: "83 %" with a narrow no-break space (U+202F).
    /// - English: "83%" with no space.
    ///
    /// - Parameters:
    ///   - value: the already-computed percentage (0…100 domain), rendered
    ///     with the locale's grouping/sign conventions.
    ///   - locale: locale for the number rendering; defaults to `.current`.
    public static func percent(_ value: Int, locale: Locale = .current) -> String {
        percent(formattedNumber: value.formatted(.number.locale(locale)), locale: locale)
    }

    /// Fractional-percent counterpart of `percent(_:)` for values that carry
    /// decimals. Precision is fixed to `fractionDigits` (as `%.Nf`); the sign
    /// sits where `locale` puts it.
    ///
    /// - Parameters:
    ///   - value: the already-computed percentage (0…100 domain).
    ///   - fractionDigits: exact number of fraction digits.
    ///   - locale: locale for the number rendering; defaults to `.current`.
    public static func percent(
        _ value: Double,
        fractionDigits: Int = 0,
        locale: Locale = .current
    ) -> String {
        let number = value.formatted(
            .number.precision(.fractionLength(fractionDigits)).locale(locale)
        )
        return percent(formattedNumber: number, locale: locale)
    }

    /// Places the percent sign around an already formatted number the way
    /// `locale` does: Foundation's own percent pattern decides whether there is
    /// a gap and on which side the sign sits ("83%", "83 %", "%83"). The gap
    /// Foundation uses (U+00A0) becomes the narrow no-break space (U+202F) the
    /// web client renders, so German stays "83 %" exactly as before.
    public static func percent(formattedNumber number: String, locale: Locale = .current) -> String {
        let one = 1.formatted(.number.locale(locale))
        let pattern = 1.formatted(.percent.locale(locale))
            .replacingOccurrences(of: "\u{00A0}", with: narrowNoBreakSpace)
        guard let range = pattern.range(of: one) else {
            return number + narrowNoBreakSpace + "%"
        }
        return pattern.replacingCharacters(in: range, with: number)
    }

    /// A closed range spelled out in words: "120 bis 129" / "120 to 129".
    ///
    /// U5 (1.1.1) — ranges no longer join their bounds with an en dash ("–"),
    /// which read as machine-written. The bounds arrive already formatted
    /// (number, date, time, with or without unit); this only joins them. The
    /// catalog key is the English text itself, so a process without the app's
    /// catalog (SPM core tests) still reads "120 to 129".
    public static func range(_ lower: String, _ upper: String) -> String {
        String(
            localized: "\(lower) to \(upper)",
            comment: "U5 — a closed range, e.g. 120 to 129. First %@ = lower bound, second %@ = upper bound, both already formatted."
        )
    }
}
