import Foundation
@testable import HealthLog
import Testing

/// **W-WIDGET-DEEPLINK (v0152)** — pins the per-measurement widget deep link:
/// the canonical `MetricKind` ⇄ kebab-slug round-trip (now owned by the
/// plattform-free `InsightsLayoutTileId`), the `LatestMeasurement` widget's
/// per-metric URL builder, the `DeepLinkRoute` parse back to
/// `.insights(metric:)`, and the unmapped-kind root fallback.
@Suite("InsightsLatestMeasurementDeepLink — kind⇄slug + widget URL + route")
struct InsightsLatestMeasurementDeepLinkTests {
    /// Helper: avoids `URL(string:)!` (force-unwrap lint). Static fixtures, so a
    /// `nil` here is a test bug, not a crash.
    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string), "Test fixture URL invalid: \(string)")
    }

    // MARK: - kindToSlug ⇄ slugToKind round-trip

    @Test("Every mapped kind round-trips slug → kind → slug")
    func kindSlugRoundTrip() {
        for (kind, slug) in InsightsLayoutTileId.kindToSlug {
            // Forward: kind → slug
            #expect(InsightsLayoutTileId.slug(forKind: kind) == slug)
            // Reverse: slug → kind
            #expect(InsightsLayoutTileId.kind(forSlug: slug) == kind)
            // Inverse table direct lookup agrees.
            #expect(InsightsLayoutTileId.slugToKind[slug] == kind)
        }
    }

    @Test("slugToKind is the exact inverse of kindToSlug (no drift, no collision)")
    func inverseIsConsistent() {
        // Same cardinality ⇒ no two kinds share a slug (the inverse is total).
        #expect(InsightsLayoutTileId.slugToKind.count == InsightsLayoutTileId.kindToSlug.count)
        for (slug, kind) in InsightsLayoutTileId.slugToKind {
            #expect(InsightsLayoutTileId.kindToSlug[kind] == slug)
        }
    }

    @Test("Mapped slugs are server-known — all of them")
    func mappedSlugsAreServerKnown() {
        // Parity Build 4 / 4.1 — the `steps` exemption is gone: it is a
        // `SUB_PAGE_METRIC` key on the web (v1.12) and now in `serverKnownIds`,
        // so EVERY mapped slug must be server-known with no carve-out left.
        for slug in InsightsLayoutTileId.kindToSlug.values {
            #expect(
                InsightsLayoutTileId.serverKnownIds.contains(slug),
                "Slug \(slug) is not in serverKnownIds — would 422 a layout PUT"
            )
        }
    }

    @Test("Mapped slugs all match the DeepLink metric-slug allowlist shape")
    func mappedSlugsMatchAllowlist() throws {
        // Mirrors `DeepLinkRoute.metricSlugAllowlist`: ^[a-z0-9-]{1,48}$ — a slug
        // that broke this shape would be rejected by the parser → root fallback.
        let regex = try NSRegularExpression(pattern: "^[a-z0-9-]{1,48}$")
        for slug in InsightsLayoutTileId.kindToSlug.values {
            let range = NSRange(slug.startIndex..., in: slug)
            #expect(
                regex.firstMatch(in: slug, options: [], range: range) != nil,
                "Slug \(slug) fails the metric-slug allowlist shape"
            )
        }
    }

    // MARK: - kindRaw → slug (snapshot camelCase rawValue)

    @Test("Weight snapshot kindRaw resolves to the weight slug")
    func weightKindRawSlug() {
        #expect(InsightsLatestMeasurementDeepLink.slug(forKindRaw: "weight") == "weight")
    }

    @Test("Blood-pressure snapshot kindRaw resolves to the kebab slug")
    func bloodPressureKindRawSlug() {
        #expect(InsightsLatestMeasurementDeepLink.slug(forKindRaw: "bloodPressure") == "blood-pressure")
    }

    @Test("Custom-rawValue kind (spo2 = oxygenSaturation) resolves to oxygen slug")
    func spo2KindRawSlug() {
        // `MetricKind.spo2` has rawValue "oxygenSaturation" and slug "oxygen" —
        // the two-hop camelCase→kind→kebab-slug bridge the whole task is about.
        #expect(InsightsLatestMeasurementDeepLink.slug(forKindRaw: "oxygenSaturation") == "oxygen")
    }

    @Test("Unknown / nil kindRaw resolves to nil slug (→ root fallback)")
    func unknownKindRawSlug() {
        #expect(InsightsLatestMeasurementDeepLink.slug(forKindRaw: nil) == nil)
        #expect(InsightsLatestMeasurementDeepLink.slug(forKindRaw: "not-a-real-kind") == nil)
        // A real kind that has no Insights page (composite/derived) → nil.
        #expect(InsightsLatestMeasurementDeepLink.slug(forKindRaw: MetricKind.sleepScore.rawValue) == nil)
    }

    // MARK: - widget URL builder

    @Test("Widget builds the specific-metric URL for a sample measurement")
    func widgetURLForSample() throws {
        let weightURL = try #require(InsightsLatestMeasurementDeepLink.url(forKindRaw: "weight"))
        #expect(try weightURL == url("healthlog://insights/weight"))

        let bpURL = try #require(InsightsLatestMeasurementDeepLink.url(forKindRaw: "bloodPressure"))
        #expect(try bpURL == url("healthlog://insights/blood-pressure"))
    }

    @Test("Unmapped / nil kind → Insights root URL (graceful fallback)")
    func widgetURLFallback() throws {
        let root = try url("healthlog://insights")
        #expect(InsightsLatestMeasurementDeepLink.url(forKindRaw: nil) == root)
        #expect(InsightsLatestMeasurementDeepLink.url(forKindRaw: "not-a-real-kind") == root)
        #expect(InsightsLatestMeasurementDeepLink.url(forKindRaw: MetricKind.sleepScore.rawValue) == root)
    }

    // MARK: - end-to-end: URL parses back to .insights(metric:)

    @Test("Built per-metric URL parses to .insights(metric: slug)")
    func builtURLParsesToInsightsMetric() throws {
        let built = try #require(InsightsLatestMeasurementDeepLink.url(forKindRaw: "bloodPressure"))
        #expect(DeepLinkRoute(url: built) == .insights(metric: "blood-pressure"))

        let weightBuilt = try #require(InsightsLatestMeasurementDeepLink.url(forKindRaw: "weight"))
        #expect(DeepLinkRoute(url: weightBuilt) == .insights(metric: "weight"))
    }

    @Test("Every mapped kind's built URL parses back to its slug")
    func everyMappedKindURLParses() throws {
        for (kind, slug) in InsightsLayoutTileId.kindToSlug {
            let built = try #require(
                InsightsLatestMeasurementDeepLink.url(forKindRaw: kind.rawValue),
                "No URL built for \(kind.rawValue)"
            )
            #expect(
                DeepLinkRoute(url: built) == .insights(metric: slug),
                "URL for \(kind.rawValue) did not parse to .insights(metric: \(slug))"
            )
        }
    }

    @Test("Fallback root URL parses to .insights(metric: nil)")
    func fallbackURLParsesToOverview() throws {
        let root = try #require(InsightsLatestMeasurementDeepLink.url(forKindRaw: nil))
        #expect(DeepLinkRoute(url: root) == .insights(metric: nil))
    }
}
