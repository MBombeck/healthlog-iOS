import Foundation

/// **A360-1 M2 — typed Learn-article link registry (mirror of the server's
/// `LEARN_LINKS` / `LEARN_GUIDES`).**
///
/// The public `/learn` guides are the secondary, plain-language education layer.
/// The server (`src/lib/learn-links.ts` + `src/lib/ai/coach/learn-catalog.ts`,
/// v1.21.0) keeps a frozen `concept → slug` map; this is the iOS mirror.
///
/// Fail-closed by construction: a concept with no mapped guide returns `nil`,
/// so a surface that wires an unmapped concept simply renders no pointer rather
/// than an invented (404) href. The slug set is validated against the server
/// registry by `HLLearnLinkRegistryTests`.
///
/// URLs are minted ONLY through ``HLLearnLinks/url(forSlug:)`` against the
/// frozen ``HLLearnGuide`` catalog — no other code string-concatenates a
/// `/learn` URL (matches the server's "single source of truth" rule).
public struct HLLearnGuide: Sendable, Equatable {
    /// The catalog slug — the path segment under `/learn`.
    public let slug: String
    /// The human-readable guide title (the accessible link label suffix).
    public let title: String
    /// The absolute public URL.
    public let url: URL

    /// 1.4 B4 — the guide's title in the app's language, as the site prints
    /// it. ``title`` stays the English registry title the server mirrors.
    public var localizedTitle: String {
        HLLearnLinks.localizedTitle(forSlug: slug) ?? title
    }

    /// 1.4 B4 — the guide in the app's language: the site publishes every
    /// guide under `/de/learn` as well, and a German reader no longer lands
    /// on the English article.
    public var localizedURL: URL {
        HLLearnLinks.url(forSlug: slug, languageCode: HLLearnLinks.appLanguageCode) ?? url
    }
}

public enum HLLearnLinks {
    /// Base URL for the public `/learn` guides — identical to the server's
    /// `LEARN_BASE_URL` (`https://healthlog.dev/learn`).
    static let baseURL = "https://healthlog.dev/learn"

    /// The published guide `slug → title` catalog (19 guides, mirrors the
    /// server's `LEARN_GUIDES`). Kept in sync with
    /// `src/lib/ai/coach/learn-catalog.ts`.
    private static let catalog: [(slug: String, title: String)] = [
        ("understanding-your-health-metrics", "Understanding Your Health Metrics"),
        ("resting-heart-rate", "Resting Heart Rate"),
        ("heart-rate-variability", "Heart Rate Variability"),
        ("reading-your-blood-pressure", "Reading Your Blood Pressure"),
        ("sleep-consistency", "Sleep Consistency"),
        ("respiratory-rate", "Respiratory Rate"),
        ("blood-oxygen-spo2", "Blood Oxygen (SpO2)"),
        ("body-temperature-baseline", "Body Temperature Baseline"),
        ("blood-sugar-beyond-diabetes", "Blood Sugar Beyond Diabetes"),
        ("vo2max-and-longevity", "VO2 Max and Longevity"),
        ("beyond-the-scale", "Beyond the Scale"),
        ("tracking-mood", "Tracking Mood"),
        ("the-cycle-as-a-vital-sign", "The Cycle as a Vital Sign"),
        ("how-wearables-measure-you", "How Wearables Measure You"),
        ("reading-your-trends", "Reading Your Trends"),
        ("steps-and-movement", "Steps and Movement"),
        ("caffeine-alcohol-and-your-readings", "Caffeine, Alcohol and Your Readings"),
        ("hydration-and-your-body", "Hydration and Your Body"),
        ("stress-and-recovery", "Stress and Recovery")
    ]

    /// The resolved guide catalog. Any entry whose slug fails to form a valid
    /// URL is dropped (fail-closed — `HLLearnLinkRegistryTests` asserts all 19
    /// survive, so a malformed entry is a test failure, never a runtime crash).
    static let guides: [HLLearnGuide] = catalog.compactMap { entry in
        guard let url = URL(string: "\(baseURL)/\(entry.slug)") else { return nil }
        return HLLearnGuide(slug: entry.slug, title: entry.title, url: url)
    }

    /// 1.4 B4 — the language the app runs in (``AppLanguage/current``), which
    /// picks the guide's edition on the site.
    static var appLanguageCode: String {
        AppLanguage.current.rawValue
    }

    /// The guide for a slug in a language: `/de/learn/<slug>` for German,
    /// `/learn/<slug>` otherwise. `nil` for an unknown slug (fail-closed).
    static func url(forSlug slug: String, languageCode: String) -> URL? {
        guard guideBySlug[slug] != nil else { return nil }
        let base = languageCode.hasPrefix("de") ? "https://healthlog.dev/de/learn" : baseURL
        return URL(string: "\(base)/\(slug)")
    }

    /// 1.4 B4 — the site's own title of each guide, through the catalog
    /// (German and English). Medical Sources listed the English registry
    /// titles in the German app.
    static func localizedTitle(forSlug slug: String) -> String? {
        titleKeys[slug].map { String(localized: $0) }
    }

    /// One catalog key per guide, `learn.guide.<slug>`.
    private static let titleKeys: [String: LocalizedStringResource] = [
        "understanding-your-health-metrics": "learn.guide.understanding-your-health-metrics",
        "resting-heart-rate": "learn.guide.resting-heart-rate",
        "heart-rate-variability": "learn.guide.heart-rate-variability",
        "reading-your-blood-pressure": "learn.guide.reading-your-blood-pressure",
        "sleep-consistency": "learn.guide.sleep-consistency",
        "respiratory-rate": "learn.guide.respiratory-rate",
        "blood-oxygen-spo2": "learn.guide.blood-oxygen-spo2",
        "body-temperature-baseline": "learn.guide.body-temperature-baseline",
        "blood-sugar-beyond-diabetes": "learn.guide.blood-sugar-beyond-diabetes",
        "vo2max-and-longevity": "learn.guide.vo2max-and-longevity",
        "beyond-the-scale": "learn.guide.beyond-the-scale",
        "tracking-mood": "learn.guide.tracking-mood",
        "the-cycle-as-a-vital-sign": "learn.guide.the-cycle-as-a-vital-sign",
        "how-wearables-measure-you": "learn.guide.how-wearables-measure-you",
        "reading-your-trends": "learn.guide.reading-your-trends",
        "steps-and-movement": "learn.guide.steps-and-movement",
        "caffeine-alcohol-and-your-readings": "learn.guide.caffeine-alcohol-and-your-readings",
        "hydration-and-your-body": "learn.guide.hydration-and-your-body",
        "stress-and-recovery": "learn.guide.stress-and-recovery"
    ]

    /// Fast slug → guide index over the catalog.
    private static let guideBySlug: [String: HLLearnGuide] = Dictionary(
        uniqueKeysWithValues: guides.map { ($0.slug, $0) }
    )

    /// The frozen `concept → slug` mapping — mirror of the server's
    /// `LEARN_LINKS`. The metric-shaped keys are the iOS ``MetricKind``
    /// `rawValue`s where a guide exists (so a metric page passes its raw value
    /// straight through); the remaining keys name a cross-cutting concept
    /// (composite score, the generic lab-biomarker fallback, …).
    ///
    /// Metric keys use the iOS rawValue (which differs from the server's
    /// `InsightMetric` id, e.g. `oxygenSaturation` vs `OXYGEN_SATURATION`) — the
    /// slug each maps to is identical to the server map.
    static let conceptToSlug: [String: String] = [
        // metric-shaped — keyed by MetricKind.rawValue
        "restingHeartRate": "resting-heart-rate",
        "heartRateVariability": "heart-rate-variability",
        "bloodPressure": "reading-your-blood-pressure",
        "oxygenSaturation": "blood-oxygen-spo2",
        "respiratoryRate": "respiratory-rate",
        "bodyTemperature": "body-temperature-baseline",
        "glucose": "blood-sugar-beyond-diabetes",
        "vo2Max": "vo2max-and-longevity",
        "weight": "beyond-the-scale",
        "bodyMassIndex": "beyond-the-scale",
        "steps": "steps-and-movement",
        "sleep": "sleep-consistency",
        // concept-shaped — composite / cross-cutting keys
        "HEALTH_METRICS_OVERVIEW": "understanding-your-health-metrics",
        "TRENDS": "reading-your-trends",
        "RESILIENCE": "stress-and-recovery",
        "MOOD": "tracking-mood",
        "CYCLE": "the-cycle-as-a-vital-sign",
        "WEARABLES": "how-wearables-measure-you",
        "LAB_BIOMARKER": "understanding-your-health-metrics"
    ]

    /// The ONLY sanctioned `/learn` URL resolver. Returns the catalog guide for
    /// a slug, or `nil` for an unknown slug (fail-closed).
    public static func url(forSlug slug: String) -> URL? {
        guideBySlug[slug]?.url
    }

    /// Resolve a concept key (a ``MetricKind`` rawValue or a concept-shaped key)
    /// to its guide, or `nil` when the concept is unmapped or — defensively —
    /// its slug is missing from the catalog. A surface passes the result
    /// straight to ``HLLearnMoreLink``, which renders nothing on `nil`.
    public static func guide(forConcept concept: String) -> HLLearnGuide? {
        guard let slug = conceptToSlug[concept] else { return nil }
        return guideBySlug[slug]
    }
}
