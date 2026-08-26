import Foundation

/// Human-readable labels for the report-selection leaf ids (CU-11).
///
/// **This is a label lookup, never a vocabulary.** The set of selectable leaves
/// comes exclusively from `GET /api/meta/capabilities` →
/// ``ServerCapabilities/Share/leaves``; nothing here decides what may be
/// chosen. Every resolution path ends in a humanised fallback derived from the
/// id itself, so a leaf the server adds tomorrow renders as words on a build
/// shipped today instead of vanishing or crashing.
///
/// Resolution order, most specific first:
///  1. The id is a server `MeasurementType` token this build already knows —
///     reuse the metric's existing localized title (``MetricKind/displayName``),
///     so a leaf and its dashboard tile can never disagree on what it is called.
///  2. A `report.leaf.<ID>` entry in `Localizable.xcstrings` — how the 14
///     structured sections (`LAB_RESULTS`, `MEDICATION_LIST`, …) get their DE/EN
///     wording. Resolved dynamically by id, so the catalogue is data, not a
///     `switch` that would have to enumerate the vocabulary.
///  3. Humanised id (`MEDICATION_LIST` → `Medication list`).
public enum ReportLeafDisplay {
    /// Localized label for one leaf id.
    public static func label(for leaf: String) -> String {
        if let kind = ServerMeasurementType(rawValue: leaf)?.metricKind {
            return kind.displayName
        }
        let key = "report.leaf.\(leaf)"
        let resolved = String(localized: String.LocalizationValue(key))
        // `String(localized:)` echoes the key back verbatim when it is not in
        // the catalog — that is the signal to humanise instead of showing a
        // dotted key to a user.
        return resolved == key ? humanized(leaf) : resolved
    }

    /// `MEDICATION_ADMINISTRATIONS` → `Medication administrations`. The last
    /// line of defence: readable, honest, and never wrong about the scope
    /// because it is the id itself.
    static func humanized(_ leaf: String) -> String {
        let words = leaf
            .split(separator: "_")
            .map { $0.lowercased() }
            .joined(separator: " ")
        guard let first = words.first else { return leaf }
        return first.uppercased() + words.dropFirst()
    }
}
