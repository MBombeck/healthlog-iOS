import Foundation

/// **W-WIDGET-DEEPLINK (v0152) — builds the per-measurement Insights deep link
/// the `LatestMeasurement` widget opens.**
///
/// The App-Group snapshot carries the reading's kind as a camelCase
/// `MetricKind.rawValue` (`WidgetSnapshot.LatestMeasurement.kindRaw`, e.g.
/// `"weight"` / `"oxygenSaturation"`), but the in-app Insights deep-link route
/// (`DeepLinkRoute.insights(metric:)` / `AppRouter`) expects a **kebab metric
/// slug** from the canonical allowlist (`"weight"` / `"oxygen"`). This helper
/// bridges the two: `kindRaw` → `MetricKind` → `InsightsLayoutTileId.slug(forKind:)`
/// → `healthlog://insights/<slug>`.
///
/// Plattform-free + Foundation-only, living in `WidgetShared` so it compiles
/// into BOTH the app and the widget extension. The widget can't reach the
/// app-only `InsightsTabSlug`, but `InsightsLayoutTileId` (in `HealthLog/Models`)
/// crosses the target boundary and owns the canonical kind⇄slug map.
///
/// **Graceful fallback:** a `nil` / unknown / unmapped kind resolves to the bare
/// `healthlog://insights` root (the old behaviour) — never a broken URL, never a
/// crash. The route resolves to `.insights(metric: <slug>)` in `DeepLinkRouter`,
/// which the Insights pager jumps to instantly (W-NAVANIM / W-INSIGHTS2).
public enum InsightsLatestMeasurementDeepLink {
    /// The bare Insights root the deep link falls back to when there is no
    /// per-metric page to land on.
    public static let rootURLString = "healthlog://insights"

    /// The per-metric deep-link URL for a snapshot reading's `kindRaw`
    /// (camelCase `MetricKind.rawValue`), or the Insights root when the kind is
    /// `nil` / unknown / has no Insights page.
    ///
    /// - Parameter kindRaw: the snapshot reading's `kindRaw`
    ///   (`WidgetSnapshot.LatestMeasurement.kindRaw`), or `nil` for an empty
    ///   snapshot.
    /// - Returns: `healthlog://insights/<slug>` for a mapped kind, else
    ///   `healthlog://insights`.
    public static func url(forKindRaw kindRaw: String?) -> URL? {
        guard let slug = slug(forKindRaw: kindRaw) else {
            return URL(string: rootURLString)
        }
        return URL(string: "\(rootURLString)/\(slug)")
    }

    /// The kebab Insights slug for a camelCase `kindRaw`, or `nil` when the kind
    /// is `nil` / not a known `MetricKind` / has no Insights page. Exposed for
    /// unit tests so the slug resolution is asserted independently of `URL`
    /// construction.
    public static func slug(forKindRaw kindRaw: String?) -> String? {
        guard let kindRaw, let kind = MetricKind(rawValue: kindRaw) else { return nil }
        return InsightsLayoutTileId.slug(forKind: kind)
    }
}
