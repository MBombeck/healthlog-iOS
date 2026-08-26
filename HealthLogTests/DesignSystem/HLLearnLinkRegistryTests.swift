import Foundation
@testable import HealthLog
import Testing

/// A360-1 M2 — locks the Learn-links registry mirror of the server's
/// `LEARN_LINKS` / `LEARN_GUIDES` (`src/lib/learn-links.ts`). Every mapped slug
/// MUST resolve to a guide in the catalog (no dead/404 link), and the catalog
/// must match the 19 published server guides.
@Suite("HLLearnLinks registry")
struct HLLearnLinkRegistryTests {
    /// The 19 published guide slugs from the server's `LEARN_GUIDES`.
    private let serverSlugs: Set<String> = [
        "understanding-your-health-metrics",
        "resting-heart-rate",
        "heart-rate-variability",
        "reading-your-blood-pressure",
        "sleep-consistency",
        "respiratory-rate",
        "blood-oxygen-spo2",
        "body-temperature-baseline",
        "blood-sugar-beyond-diabetes",
        "vo2max-and-longevity",
        "beyond-the-scale",
        "tracking-mood",
        "the-cycle-as-a-vital-sign",
        "how-wearables-measure-you",
        "reading-your-trends",
        "steps-and-movement",
        "caffeine-alcohol-and-your-readings",
        "hydration-and-your-body",
        "stress-and-recovery"
    ]

    @Test("catalog exactly mirrors the server's published guide slugs")
    func catalogMatchesServer() {
        let iosSlugs = Set(HLLearnLinks.guides.map(\.slug))
        #expect(iosSlugs == serverSlugs)
    }

    @Test("every concept maps to a slug that resolves in the catalog")
    func everyConceptResolves() {
        for (concept, slug) in HLLearnLinks.conceptToSlug {
            #expect(
                serverSlugs.contains(slug),
                "concept \(concept) → slug \(slug) is not a published guide"
            )
            #expect(
                HLLearnLinks.guide(forConcept: concept) != nil,
                "concept \(concept) failed to resolve to a guide"
            )
        }
    }

    @Test("url(forSlug:) returns the absolute /learn URL for a known slug")
    func urlForKnownSlug() {
        let url = HLLearnLinks.url(forSlug: "resting-heart-rate")
        #expect(url?.absoluteString == "https://healthlog.dev/learn/resting-heart-rate")
    }

    @Test("url(forSlug:) is fail-closed for an unknown slug")
    func urlForUnknownSlug() {
        #expect(HLLearnLinks.url(forSlug: "no-such-guide") == nil)
    }

    @Test("an unmapped concept resolves to nil (fail-closed)")
    func unmappedConceptIsNil() {
        #expect(HLLearnLinks.guide(forConcept: "boneMass") == nil)
        #expect(HLLearnLinks.guide(forConcept: "NOT_A_CONCEPT") == nil)
    }

    @Test("the core metric kinds map through their rawValue")
    func metricKindsMap() {
        // These MetricKind rawValues are wired into the metric detail learn slot.
        #expect(HLLearnLinks.guide(forConcept: MetricKind.restingHeartRate.rawValue)?.slug == "resting-heart-rate")
        #expect(HLLearnLinks.guide(forConcept: MetricKind.hrv.rawValue)?.slug == "heart-rate-variability")
        #expect(HLLearnLinks.guide(forConcept: MetricKind.bloodPressure.rawValue)?.slug == "reading-your-blood-pressure")
        #expect(HLLearnLinks.guide(forConcept: MetricKind.glucose.rawValue)?.slug == "blood-sugar-beyond-diabetes")
        #expect(HLLearnLinks.guide(forConcept: MetricKind.spo2.rawValue)?.slug == "blood-oxygen-spo2")
        #expect(HLLearnLinks.guide(forConcept: MetricKind.weight.rawValue)?.slug == "beyond-the-scale")
        #expect(HLLearnLinks.guide(forConcept: MetricKind.vo2Max.rawValue)?.slug == "vo2max-and-longevity")
    }
}
