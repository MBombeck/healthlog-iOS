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
    /// tighter than a normal space — this is what the web client renders and
    /// what iOS should match. Exposed for the rare call site (e.g. a signed
    /// magnitude) that assembles the string itself; inside the `percent(_:)`
    /// helpers the raw `\u{202F}` escape is used so the character before the
    /// sign is `}` (never `)`), keeping the percent-lint quiet on this file.
    public static let narrowNoBreakSpace = "\u{202F}"

    /// Renders an integer percentage the canonical way — "83 %" with a narrow
    /// no-break space before the sign (never the bare, space-less form). Use
    /// this instead of interpolating a number directly in front of a percent
    /// sign for any user-facing percentage.
    ///
    /// - Parameters:
    ///   - value: the already-computed percentage (0…100 domain), rendered
    ///     with the locale's grouping/sign conventions.
    ///   - locale: locale for the number rendering; defaults to `.current`.
    public static func percent(_ value: Int, locale: Locale = .current) -> String {
        "\(value.formatted(.number.locale(locale)))\u{202F}%"
    }

    /// Fractional-percent counterpart of `percent(_:)` for values that carry
    /// decimals. Precision is fixed to `fractionDigits` (as `%.Nf`) and the
    /// narrow no-break space is inserted before the sign.
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
        return "\(number)\u{202F}%"
    }
}
