import Foundation

/// Build 3 / item 3.2 — the curated seed catalog offered in the biomarker
/// CREATE form, mirroring the web `BIOMARKER_CATALOG`
/// (`src/lib/labs/biomarker-catalog.ts`, 30 entries) and the panel-grouped
/// picker it feeds (`biomarker-form.tsx:86-95, 167-202`).
///
/// **This is NOT a table and NOT server state.** Picking a seed only PRE-FILLS
/// the definition form — name, unit, and suggested reference bounds — which the
/// operator then accepts or overrides before it becomes a real, user-scoped
/// `Biomarker` row on the server. Nothing is written until Save.
///
/// **The bounds are editable defaults, never gospel.** Reference windows vary
/// by lab, sex and age; the form's footer says so. They are common adult
/// fasting windows in the units the web catalog uses (US conventional where the
/// metric/SI split matters), presented as starting points.
///
/// The `slug` is the stable EN identity and is deliberately the SAME slug space
/// `BiomarkerExplainer` already uses, so a marker seeded here automatically
/// resolves its `biomarker.explainer.<slug>` paragraph on the detail page. That
/// was the missing half the audit named: iOS had 31 curated explainers that
/// "erklären nur, sie seeden nicht".
struct BiomarkerSeed: Identifiable, Hashable {
    /// Stable EN identity — also the `biomarker.explainer.<slug>` key.
    let slug: String
    /// Panel grouping key; `BiomarkerSeedPanel` carries its localized label.
    let panel: BiomarkerSeedPanel
    /// Canonical unit. **Not localized** — `mg/dL` is `mg/dL` everywhere.
    let unit: String
    /// Suggested lower bound, or `nil` when the window is open-ended below
    /// (LDL has no clinically useful floor, HDL has no ceiling).
    let lowerBound: Double?
    /// Suggested upper bound, or `nil` when open-ended above.
    let upperBound: Double?

    var id: String {
        slug
    }

    /// The localized display name, resolved from `labs.catalog.<slug>`.
    ///
    /// `String(localized:)` echoes the key verbatim when the catalog has no
    /// entry, which would put a raw `labs.catalog.ldl` in a picker row. Guard
    /// against that the same way `BiomarkerExplainer.catalogExplainer` does and
    /// fall back to the slug, which at least reads as a word.
    var displayName: String {
        let key = "labs.catalog.\(slug)"
        let resolved = String(localized: String.LocalizationValue(key))
        return resolved == key ? slug : resolved
    }
}

/// The ten panel groups the seed picker sections by. Mirrors the web
/// `BIOMARKER_PANELS` order exactly so the two catalogs read the same
/// top-to-bottom.
enum BiomarkerSeedPanel: String, CaseIterable, Hashable {
    case lipids
    case glucose
    case thyroid
    case iron
    case vitamins
    case inflammation
    case renal
    case liver
    case electrolytes
    case bloodCount

    /// Localized panel label (`labs.catalog.panel.<key>`). This is ALSO the
    /// string written into the biomarker's `panel` field when a seed is
    /// applied, matching the web (`setPanel(t(...))`) — the server stores panel
    /// as free text, so the user's own language is the right value.
    var displayName: String {
        let key = "labs.catalog.panel.\(rawValue)"
        let resolved = String(localized: String.LocalizationValue(key))
        return resolved == key ? rawValue : resolved
    }
}

enum BiomarkerSeedCatalog {
    /// All 30 seeds, in the web catalog's order.
    static let all: [BiomarkerSeed] = [
        // Lipids
        .init(slug: "total-cholesterol", panel: .lipids, unit: "mg/dL", lowerBound: nil, upperBound: 200),
        .init(slug: "ldl", panel: .lipids, unit: "mg/dL", lowerBound: nil, upperBound: 116),
        .init(slug: "hdl", panel: .lipids, unit: "mg/dL", lowerBound: 40, upperBound: nil),
        .init(slug: "triglycerides", panel: .lipids, unit: "mg/dL", lowerBound: nil, upperBound: 150),
        .init(slug: "apob", panel: .lipids, unit: "mg/dL", lowerBound: nil, upperBound: 90),
        .init(slug: "lp-a", panel: .lipids, unit: "nmol/L", lowerBound: nil, upperBound: 125),
        .init(slug: "omega-3-index", panel: .lipids, unit: "%", lowerBound: 8, upperBound: nil),
        // Glucose metabolism
        .init(slug: "fasting-glucose", panel: .glucose, unit: "mg/dL", lowerBound: 70, upperBound: 100),
        .init(slug: "hba1c", panel: .glucose, unit: "%", lowerBound: nil, upperBound: 5.7),
        .init(slug: "fasting-insulin", panel: .glucose, unit: "µIU/mL", lowerBound: 2.5, upperBound: 13),
        // Thyroid
        .init(slug: "tsh", panel: .thyroid, unit: "mIU/L", lowerBound: 0.4, upperBound: 4),
        .init(slug: "ft3", panel: .thyroid, unit: "pg/mL", lowerBound: 2.3, upperBound: 4.2),
        .init(slug: "ft4", panel: .thyroid, unit: "ng/dL", lowerBound: 0.8, upperBound: 1.8),
        // Iron
        .init(slug: "ferritin", panel: .iron, unit: "ng/mL", lowerBound: 30, upperBound: 400),
        .init(slug: "transferrin-saturation", panel: .iron, unit: "%", lowerBound: 20, upperBound: 50),
        // Vitamins
        .init(slug: "vitamin-d", panel: .vitamins, unit: "ng/mL", lowerBound: 30, upperBound: 100),
        .init(slug: "vitamin-b12", panel: .vitamins, unit: "pg/mL", lowerBound: 200, upperBound: 900),
        .init(slug: "folate", panel: .vitamins, unit: "ng/mL", lowerBound: 3, upperBound: 20),
        // Inflammation
        .init(slug: "hs-crp", panel: .inflammation, unit: "mg/L", lowerBound: nil, upperBound: 3),
        // Renal
        .init(slug: "creatinine", panel: .renal, unit: "mg/dL", lowerBound: 0.6, upperBound: 1.3),
        .init(slug: "egfr", panel: .renal, unit: "mL/min/1.73m²", lowerBound: 90, upperBound: nil),
        // Liver
        .init(slug: "alt", panel: .liver, unit: "U/L", lowerBound: nil, upperBound: 40),
        .init(slug: "ast", panel: .liver, unit: "U/L", lowerBound: nil, upperBound: 40),
        .init(slug: "ggt", panel: .liver, unit: "U/L", lowerBound: nil, upperBound: 55),
        // Electrolytes
        .init(slug: "sodium", panel: .electrolytes, unit: "mmol/L", lowerBound: 135, upperBound: 145),
        .init(slug: "potassium", panel: .electrolytes, unit: "mmol/L", lowerBound: 3.5, upperBound: 5.1),
        // Blood count
        .init(slug: "hemoglobin", panel: .bloodCount, unit: "g/dL", lowerBound: 12, upperBound: 17.5),
        .init(slug: "hematocrit", panel: .bloodCount, unit: "%", lowerBound: 36, upperBound: 50),
        .init(slug: "wbc", panel: .bloodCount, unit: "10³/µL", lowerBound: 4, upperBound: 11),
        .init(slug: "platelets", panel: .bloodCount, unit: "10³/µL", lowerBound: 150, upperBound: 400)
    ]

    /// Seeds in one panel, in catalog order. Empty panels are the caller's
    /// problem to skip (the web does the same).
    static func seeds(in panel: BiomarkerSeedPanel) -> [BiomarkerSeed] {
        all.filter { $0.panel == panel }
    }

    static func seed(slug: String) -> BiomarkerSeed? {
        all.first { $0.slug == slug }
    }
}
