import Foundation

/// v0154 LR-REDO — auto-explainer lookup for the biomarker detail page.
///
/// **What this is.** The walkthrough wants a short "what is this biomarker"
/// paragraph (e.g. "GGT ist ein Leberenzym …") under the detail header — like
/// the Insights description slot. INV-A confirmed there is NO built-in explainer
/// dictionary anywhere (web `biomarker-catalog.ts` only carries name/unit/range
/// defaults). This implements one iOS-side: concise, FACTUAL, NON-DIAGNOSTIC
/// localized strings keyed by the web catalogue slug, with the strings
/// themselves living in `Localizable.xcstrings` (de + en) under the
/// `biomarker.explainer.<slug>` key.
///
/// **Resolution order (mirrors the Insights `descriptionSlot` self-suppression):**
///   1. the user-entered `BiomarkerDTO.context` if present (the user's own note
///      always wins — it's their data),
///   2. else the catalogue auto-explainer matched from the biomarker / analyte
///      name → slug,
///   3. else `nil` (the slot hides entirely — e.g. a free-text analyte with no
///      context and no catalogue match).
///
/// **Editorial rule.** Every explainer string is informational only: what the
/// marker measures and, neutrally, what a deviation *can indicate* — never a
/// prescription, diagnosis, or "you should". This is the same MDR-safe,
/// non-diagnostic register the rest of the app holds.
enum BiomarkerExplainer {
    /// Resolve the explainer text for a biomarker, honouring the user's own
    /// `context` first, then the auto-catalogue, then nothing.
    ///
    /// - Parameters:
    ///   - context: the user-entered `BiomarkerDTO.context` (decrypted) or `nil`.
    ///   - name: the marker / analyte display name used to match a catalogue slug.
    static func text(context: String?, name: String) -> String? {
        if let context, !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return context
        }
        return catalogExplainer(forName: name)
    }

    /// The auto-explainer for a known catalogue marker, matched by name, or `nil`.
    static func catalogExplainer(forName name: String) -> String? {
        guard let slug = slug(forName: name) else { return nil }
        // Build the `LocalizationValue` from a COMPLETE key string (not an
        // interpolation) so the lookup is a literal key rather than a
        // parameterized format. We only look up slugs we authored (the
        // `slug(forName:)` matcher only returns catalogued slugs).
        let key = "biomarker.explainer.\(slug)"
        // `String(localized:)` echoes the key verbatim when the catalog has no
        // entry for it. Guard against that (mirrors `CoachProvenanceLabels.resolve`)
        // so a missing string hides the slot instead of leaking the raw key as the
        // explainer paragraph.
        let resolved = String(localized: String.LocalizationValue(key))
        return resolved == key ? nil : resolved
    }

    // MARK: - Name → slug matching

    /// Map a marker / analyte name to a catalogue slug, or `nil` for an unknown
    /// marker. Matching is by the localized catalogue name (de + en) AND a small
    /// set of common aliases / abbreviations, all case- and diacritic-insensitive
    /// so "Cholesterin", "GGT", "Gamma-GT", "Vitamin D" all resolve. A pure
    /// lookup — no I/O, unit-testable off the main actor.
    static func slug(forName name: String) -> String? {
        let key = normalize(name)
        guard !key.isEmpty else { return nil }
        return nameToSlug[key]
    }

    /// The canonical display name for a catalogue slug (the de-primary first
    /// alias, e.g. `ldl` → "LDL-Cholesterin"), or `nil` for an unknown slug.
    /// Used by the lab-scan review's tier-2 match to canonicalise a fuzzy OCR'd
    /// analyte name before the server mints a new biomarker under it.
    static func canonicalDisplayName(forSlug slug: String) -> String? {
        catalogEntries.first { $0.slug == slug }?.aliases.first
    }

    /// Lowercase, fold diacritics, strip non-alphanumerics so "ALT (GPT)",
    /// "alt-gpt", "ALT" all collapse to the same lookup key.
    private static func normalize(_ raw: String) -> String {
        raw
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Normalized-name → slug table, built once from the catalogue's localized
    /// names plus aliases. The 26 catalogue slugs mirror the web
    /// `biomarker-catalog.ts`. Each slug carries its de + en display name and a
    /// few common spellings the user might type.
    private static let nameToSlug: [String: String] = {
        var table: [String: String] = [:]
        for entry in catalogEntries {
            for alias in entry.aliases {
                table[normalize(alias)] = entry.slug
            }
        }
        return table
    }()

    /// One catalogue entry: a slug + every spelling that should resolve to it.
    private struct CatalogEntry {
        let slug: String
        let aliases: [String]
    }

    /// The catalogue markers + their de/en names + common aliases. Kept in one
    /// place so the explainer set stays in lockstep with the web catalogue
    /// (`src/lib/labs/biomarker-catalog.ts`). v1.25 (GH iOS #38) added the
    /// longevity-panel markers — ApoB, Lp(a), Omega-3 index, fasting insulin (all
    /// real server seeds) plus HOMA-IR (a server-DERIVED value, no catalog seed —
    /// matched here as a best-effort free-text alias so a hand-entered "HOMA-IR"
    /// still gets an explainer). hs-CRP / HbA1c / eGFR / GGT / ferritin / fasting
    /// glucose already shipped pre-v1.25 and keep their entries below.
    private static let catalogEntries: [CatalogEntry] = [
        .init(slug: "total-cholesterol", aliases: ["Gesamtcholesterin", "Total cholesterol", "Cholesterin", "Cholesterol"]),
        .init(slug: "ldl", aliases: ["LDL-Cholesterin", "LDL cholesterol", "LDL"]),
        .init(slug: "hdl", aliases: ["HDL-Cholesterin", "HDL cholesterol", "HDL"]),
        .init(slug: "triglycerides", aliases: ["Triglyceride", "Triglycerides", "Trigs"]),
        // v1.25 longevity panel — atherogenic-particle burden + genetic + RBC EPA/DHA.
        .init(slug: "apob", aliases: ["Apolipoprotein B (ApoB)", "Apolipoprotein B", "ApoB", "Apo B"]),
        .init(slug: "lp-a", aliases: ["Lipoprotein(a)", "Lp(a)", "Lipoprotein a", "Lpa"]),
        .init(slug: "omega-3-index", aliases: ["Omega-3-Index", "Omega-3 index", "Omega 3 Index", "O3I"]),
        .init(slug: "fasting-glucose", aliases: ["Nüchternglukose", "Fasting glucose", "Glukose", "Glucose", "Blutzucker"]),
        .init(slug: "hba1c", aliases: ["HbA1c", "Langzeitzucker"]),
        // v1.25 longevity panel — fasting insulin (catalog seed) + HOMA-IR (derived).
        .init(slug: "fasting-insulin", aliases: ["Nüchtern-Insulin", "Fasting insulin", "Nüchterninsulin", "Insulin (nüchtern)"]),
        .init(slug: "homa-ir", aliases: ["HOMA-IR", "HOMA IR", "HOMA", "Insulinresistenz (HOMA-IR)"]),
        .init(slug: "tsh", aliases: ["TSH", "Thyreotropin"]),
        .init(slug: "ft3", aliases: ["Freies T3", "Free T3", "FT3"]),
        .init(slug: "ft4", aliases: ["Freies T4", "Free T4", "FT4"]),
        .init(slug: "ferritin", aliases: ["Ferritin"]),
        .init(slug: "transferrin-saturation", aliases: ["Transferrinsättigung", "Transferrin saturation", "TSAT"]),
        .init(slug: "vitamin-d", aliases: ["Vitamin D (25-OH)", "Vitamin D", "25-OH-Vitamin-D", "Vitamin D3"]),
        .init(slug: "vitamin-b12", aliases: ["Vitamin B12", "B12", "Cobalamin"]),
        .init(slug: "folate", aliases: ["Folsäure", "Folate", "Folat", "Folsaeure"]),
        .init(slug: "hs-crp", aliases: ["hs-CRP", "CRP", "C-reaktives Protein", "C-reactive protein"]),
        .init(slug: "creatinine", aliases: ["Kreatinin", "Creatinine"]),
        .init(slug: "egfr", aliases: ["eGFR", "GFR"]),
        .init(slug: "alt", aliases: ["ALT (GPT)", "ALT", "GPT", "Alanin-Aminotransferase"]),
        .init(slug: "ast", aliases: ["AST (GOT)", "AST", "GOT", "Aspartat-Aminotransferase"]),
        .init(slug: "ggt", aliases: ["GGT", "Gamma-GT", "γ-GT", "Gamma-Glutamyltransferase"]),
        .init(slug: "sodium", aliases: ["Natrium", "Sodium", "Na"]),
        .init(slug: "potassium", aliases: ["Kalium", "Potassium", "K"]),
        .init(slug: "hemoglobin", aliases: ["Hämoglobin", "Hemoglobin", "Hb", "Haemoglobin"]),
        .init(slug: "hematocrit", aliases: ["Hämatokrit", "Hematocrit", "Hkt", "Haematokrit"]),
        .init(slug: "wbc", aliases: ["Leukozyten", "White blood cells", "WBC", "Leukocytes"]),
        .init(slug: "platelets", aliases: ["Thrombozyten", "Platelets", "PLT"])
    ]

    /// Catalogue slugs that carry an authored explainer — exposed for tests so
    /// they can assert every slug resolves to a non-empty, non-key string.
    static let knownSlugs: [String] = catalogEntries.map(\.slug)
}
