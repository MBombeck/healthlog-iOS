import Foundation

/// Locale-aware decimal parsing for user-typed numeric input (A360-5 H-4).
///
/// The codebase historically parsed typed numbers with
/// `Double(text.replacingOccurrences(of: ",", with: "."))`, which has two
/// silent-failure modes the data-integrity audit flagged:
///
///   1. **Thousands ambiguity.** German "1.000" (one thousand) survives the
///      naive comma→dot replace as `"1.000"` → `Double` reads `1.0` (wrong by
///      1000×); "1,000,5" style mixed input becomes non-parseable garbage.
///   2. **Silent drop.** A `Double?` that resolves `nil` on bad input makes a
///      range-filter quietly do nothing / a value quietly fall away, with no
///      user-visible signal.
///
/// `LocaleDecimalParser` parses against the user's `Locale` first (so a de-DE
/// user's "72,4" and grouped "1.234,5" both parse correctly), then falls back
/// to a dot-decimal interpretation so a user who types "72.4" on a German
/// locale still succeeds. The result is an explicit `Double?` the caller can
/// branch on to surface a parse-failure state instead of dropping silently.
///
/// This is the single seam every entry sheet + filter should use; do not
/// reintroduce the `replacingOccurrences(of: ",", with: ".")` + `Double(_:)`
/// idiom.
enum LocaleDecimalParser {
    /// Locale-aware formatter, configured once. `NumberFormatter` is not
    /// `Sendable`; we build a fresh one per call off the supplied locale to stay
    /// concurrency-clean (these parses are user-input-rate, never hot-path).
    private static func formatter(for locale: Locale) -> NumberFormatter {
        let nf = NumberFormatter()
        nf.locale = locale
        nf.numberStyle = .decimal
        nf.generatesDecimalNumbers = false
        return nf
    }

    /// Parse `text` into a `Double`, honouring `locale`'s decimal + grouping
    /// separators, with a dot-decimal fallback. Returns `nil` on empty / wholly
    /// unparseable input so the caller can react visibly.
    static func parse(_ text: String, locale: Locale = .current) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // 1. Locale-native parse (de-DE "72,4" / grouped "1.234,5").
        if let number = formatter(for: locale).number(from: trimmed) {
            return number.doubleValue
        }

        // 2. Fallback: a user on a comma-locale who typed a dot-decimal ("72.4"),
        //    or a `Locale` whose formatter rejected an otherwise-valid token.
        //    Strip grouping-like separators conservatively: only when there is a
        //    single separator do we treat it as the decimal mark.
        if let invariant = Double(trimmed) { return invariant }
        let commaNormalized = trimmed.replacingOccurrences(of: ",", with: ".")
        // Reject multi-dot strings here so "1.000.000" doesn't read as 1.0.
        if commaNormalized.filter({ $0 == "." }).count <= 1 {
            return Double(commaNormalized)
        }
        return nil
    }
}
