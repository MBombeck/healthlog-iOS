import Foundation
@testable import HealthLog
import Testing

/// Locks the `BiomarkerExplainer` catalogue — especially the v1.25 longevity
/// additions (GH iOS #38): ApoB, Lp(a), Omega-3 index, fasting insulin, and the
/// server-derived HOMA-IR. Each must (a) carry a non-empty, non-key explainer
/// string and (b) resolve from its German + English names / common aliases.
@Suite("BiomarkerExplainer — catalogue + v1.25 longevity slugs")
struct BiomarkerExplainerTests {
    /// The v1.25 longevity slugs this wave added.
    private static let v125Slugs = ["apob", "lp-a", "omega-3-index", "fasting-insulin", "homa-ir"]

    @Test("every catalogue slug resolves to a non-empty, non-key explainer")
    func everySlugHasExplainer() throws {
        for slug in BiomarkerExplainer.knownSlugs {
            let name = try #require(
                BiomarkerExplainer.canonicalDisplayName(forSlug: slug),
                "slug \(slug) has no canonical display name"
            )
            let text = try #require(
                BiomarkerExplainer.catalogExplainer(forName: name),
                "slug \(slug) (name \(name)) resolves no explainer"
            )
            #expect(!text.isEmpty)
            #expect(text != "biomarker.explainer.\(slug)")
        }
    }

    @Test("v1.25 longevity slugs are all present in the catalogue")
    func v125SlugsPresent() {
        for slug in Self.v125Slugs {
            #expect(BiomarkerExplainer.knownSlugs.contains(slug), "missing v1.25 slug \(slug)")
        }
    }

    @Test(
        "v1.25 names + aliases resolve to the right slug",
        arguments: [
            ("ApoB", "apob"),
            ("Apolipoprotein B", "apob"),
            ("Lp(a)", "lp-a"),
            ("Lipoprotein(a)", "lp-a"),
            ("Omega-3-Index", "omega-3-index"),
            ("Omega-3 index", "omega-3-index"),
            ("Nüchtern-Insulin", "fasting-insulin"),
            ("Fasting insulin", "fasting-insulin"),
            ("HOMA-IR", "homa-ir"),
            ("HOMA", "homa-ir")
        ]
    )
    func aliasResolvesToSlug(name: String, expected: String) {
        #expect(BiomarkerExplainer.slug(forName: name) == expected)
    }

    @Test("v1.25 longevity markers each carry a real explainer paragraph")
    func v125ExplainersResolve() throws {
        let names = ["ApoB", "Lp(a)", "Omega-3-Index", "Fasting insulin", "HOMA-IR"]
        for name in names {
            let text = try #require(
                BiomarkerExplainer.catalogExplainer(forName: name),
                "no explainer for \(name)"
            )
            #expect(!text.isEmpty)
        }
    }

    @Test("an unknown analyte resolves no slug + no explainer (slot hides)")
    func unknownAnalyteIsNil() {
        #expect(BiomarkerExplainer.slug(forName: "Zzzz Unknownmarker") == nil)
        #expect(BiomarkerExplainer.catalogExplainer(forName: "Zzzz Unknownmarker") == nil)
    }
}
