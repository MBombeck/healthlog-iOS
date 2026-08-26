import Foundation

/// Identifiable wrapper so the per-tile AI explainer can present via
/// `.sheet(item:)` and a notable-trend chip can push via
/// `.navigationDestination(item:)`. The metric kind is the identity — tapping
/// `✦` on the same tile twice re-presents the same sheet.
///
/// **W52 (v0.11 overview rework):** extracted out of `InsightsScreen.swift` (was a
/// top-level `struct` there) into its own file so the screen stays under the
/// length cap after the inline Vitals dashboard block landed. Kept `struct`
/// (internal) — it's constructed from `InsightsScreen` + the Insights tile grid.
struct AIExplainerMetric: Identifiable, Equatable, Hashable {
    let kind: MetricKind
    var id: String {
        kind.rawValue
    }
}
