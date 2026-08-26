import Foundation

/// EMA-approved GLP-1 receptor agonist catalog — Swift port of
/// `src/lib/medications/glp1-knowledge.ts` (server v1.4.25 W19a).
///
/// Values are extracted verbatim from EMA EPAR Product Information PDFs and
/// cross-validated against the journal-of-record population PK paper for
/// tirzepatide (Schneck & Urva 2024, DOI 10.1002/psp4.13099).
///
/// **Posture (per `08-locked-contracts.md` §1.2 GROUND RULE 15):**
///
/// - Display-only. No autonomous dose escalation, no individual weight-loss
///   projection, no drug-drug interaction checking, no mixing/reconstitution
///   math.
/// - Coach must NEVER reason from these numbers as if they were individual
///   predictions; GROUND RULE 9 + GROUND RULE 15 apply universally, on every
///   account and every screen.
/// - Retatrutide is deliberately excluded — no EMA approval as of 2026-05;
///   including it would imply endorsement of unauthorised use.
///
/// **Catalog drift guard:** every value here mirrors the server catalog at
/// `glp1-knowledge.ts:171–547`. The `GLP1DrugCatalogDriftTests` suite locks
/// the numeric fields, brand-list, and per-brand route map against a
/// committed fixture so a future server bump cannot silently desync iOS.
///
/// Sources:
/// - EMA EPAR PDFs linked per drug in `sourceEMA`.
/// - Schneck KB, Urva S. CPT Pharmacometrics Syst Pharmacol. 2024;13(3):494-503.
///   DOI 10.1002/psp4.13099.
public enum GLP1DrugCatalog {
    /// Internal drug ids — stable across schema migrations. Brand-aware UI
    /// looks up by id, not by brand name. Five entries, ordered for
    /// deterministic iteration (matches server `GLP1_DRUG_IDS`).
    public enum DrugID: String, CaseIterable, Sendable, Hashable {
        case tirzepatide
        case semaglutide
        case liraglutide
        case dulaglutide
        case exenatide
    }

    /// Administration route. Most agonists are subcutaneous; Rybelsus is
    /// oral semaglutide (see `brandRoutes` on the semaglutide record).
    public enum Route: String, Sendable, Hashable {
        case subcutaneous
        case oral
    }

    /// Drug-class descriptor. Tirzepatide is the only dual GIP/GLP-1 agonist
    /// among EMA-approved agents (2026-05); the rest are pure GLP-1 receptor
    /// agonists.
    public enum DrugClass: Sendable, Hashable {
        case gipGlp1DualAgonist
        case glp1ReceptorAgonist

        public var label: String {
            switch self {
            case .gipGlp1DualAgonist: "GIP-GLP1 dual agonist"
            case .glp1ReceptorAgonist: "GLP-1 receptor agonist"
            }
        }
    }

    public enum InjectionFrequency: String, Sendable, Hashable {
        case daily
        case twiceDaily = "twice-daily"
        case weekly
    }

    /// Compartment model the PK math should honour. The Swift PK module
    /// currently always picks the one-compartment closed form (per the
    /// MDR boundary — qualitative display only); this field is preserved
    /// for parity so a future R8 two-compartment switch can read the
    /// model intent without a schema migration.
    public enum CompartmentModel: String, Sendable, Hashable {
        case oneCompartment = "one-compartment"
        case twoCompartment = "two-compartment"
    }

    /// Population-PK parameters per drug. Derivations + source citations
    /// match `glp1-knowledge.ts` line-for-line — see the per-record comments
    /// below for the EPAR section anchors.
    public struct Pharmacology: Sendable, Hashable {
        /// Terminal elimination half-life. **Days** for the long-acting
        /// agents, fractional days (hours/24) for liraglutide / Byetta.
        public let halfLifeDays: Double
        /// Time to maximum concentration after a SC dose, **hours**.
        /// Liraglutide uses the EMA EPAR §5.2 mean (~11 h); the weekly
        /// agents use the pharmacology-text midpoint of their EMA-published
        /// 8–72 h range.
        public let tmaxHours: Double
        /// First-order absorption rate constant **/h**. Populated from the
        /// journal-of-record where one exists (tirzepatide); `nil` where EMA
        /// only publishes a terminal half-life and a Tmax — the PK module
        /// derives a Ka from the rule-of-thumb `Ka ≈ ln(2) / (Tmax/3)`.
        public let absorptionRateHourlyKa: Double?
        /// SC bioavailability, fraction in [0,1]. EMA EPAR §5.2 values.
        public let bioavailability: Double
        /// Volume of distribution per kg body weight (**L/kg**). Derived from
        /// the EPAR's reported Vd at a 70 kg reference where the source
        /// gives an absolute litre value.
        public let vdLitersPerKg: Double
        /// Apparent clearance at the 70 kg reference weight, **L/h**.
        public let clearanceLPerHour70kg: Double
        /// Weeks until steady-state plateau on the standard cadence.
        public let steadyStateWeeks: Int
        /// Compartment model that best describes published PK.
        public let compartmentModel: CompartmentModel
    }

    public struct DrugRecord: Sendable, Hashable, Identifiable {
        public let id: DrugID
        /// International non-proprietary name (e.g. "Tirzepatide").
        public let inn: String
        /// EMA-registered brand names. Ordered as they appear in the server
        /// catalog for deterministic iteration.
        public let brands: [String]
        /// Default route for the drug. Per-brand exceptions live in
        /// `brandRoutes` (only populated when at least one brand departs
        /// from the default — currently Rybelsus oral semaglutide).
        public let route: Route
        public let brandRoutes: [String: Route]
        public let drugClass: DrugClass
        public let pharmacology: Pharmacology
        /// Standard titration ladder in **mg**, strictly ascending. The
        /// schedule is informational per EMA EPAR §4.2 — never surfaced as
        /// autonomous escalation guidance (GROUND RULE 9).
        public let titrationStepsMg: [Double]
        public let titrationIntervalWeeks: Int
        public let maxDoseMg: Double
        public let standardInjectionFrequency: InjectionFrequency
        public let dosesPerPen: Int?
        public let penType: String
        /// Direct link to the EMA EPAR product-information PDF. Surfaced in
        /// the Settings → About → Scientific Sources screen.
        public let sourceEMA: URL
        /// Peer-reviewed pharmacometric citation where one exists (today:
        /// tirzepatide only). `nil` for the EMA-only sources.
        public let sourceJournal: JournalCitation?

        public struct JournalCitation: Sendable, Hashable {
            public let citation: String
            public let doi: String
        }
    }

    // MARK: - Public lookups

    /// Stable iteration order matching server `GLP1_DRUG_IDS`.
    public static let allDrugIDs: [DrugID] = DrugID.allCases

    /// All five records, keyed by id. Use `drug(for:)` at call sites — that
    /// keeps the API ergonomic and lets us swap the storage shape later.
    public static let records: [DrugID: DrugRecord] = Dictionary(
        uniqueKeysWithValues: [
            tirzepatide, semaglutide, liraglutide, dulaglutide, exenatide
        ].map { ($0.id, $0) }
    )

    public static func drug(for id: DrugID) -> DrugRecord {
        // Catalog is statically-populated and exhaustive over `DrugID`; the
        // force-unwrap is safe by construction and a missing entry would be
        // a programming error caught by the drift test on the first run.
        // swiftlint:disable:next force_unwrapping
        records[id]!
    }

    /// Resolve the route for a given drug + brand. Falls back to the record
    /// default when no per-brand override is registered. Returns `nil` if
    /// the brand is not registered on the drug.
    public static func route(for id: DrugID, brand: String) -> Route? {
        let record = drug(for: id)
        guard record.brands.contains(where: { $0.caseInsensitiveCompare(brand) == .orderedSame }) else {
            return nil
        }
        // The override map is case-sensitive in the server catalog
        // (`brandRoutes["Rybelsus"]`); we match the canonical brand value
        // back from `brands` to look it up.
        if let canonical = record.brands.first(where: { $0.caseInsensitiveCompare(brand) == .orderedSame }),
           let override = record.brandRoutes[canonical]
        {
            return override
        }
        return record.route
    }

    /// Find the drug record that lists the given brand (case-insensitive).
    /// Returns `nil` when the brand is unknown — the caller renders an
    /// "unknown drug" empty state and never falls back to a default curve
    /// (would breach MDR boundary).
    public static func findDrug(byBrand brand: String) -> DrugRecord? {
        let needle = brand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        for id in allDrugIDs {
            let record = drug(for: id)
            if record.brands.contains(where: { $0.lowercased() == needle }) {
                return record
            }
        }
        return nil
    }

    /// Find the drug ID for a given brand string (case-insensitive). Mirrors
    /// the server's `findDrugIdByBrand` helper (`glp1-knowledge.ts:590-597`).
    public static func findDrugID(byBrand brand: String) -> DrugID? {
        findDrug(byBrand: brand)?.id
    }

    /// Best-effort brand extraction from the free-text medication name the
    /// user typed in. Strategy: lowercase + tokenize on whitespace/punct,
    /// then check each token against the catalog. Picks the **first match**
    /// in catalog-order so a "Mounjaro 7.5 mg" string resolves cleanly.
    ///
    /// Returns `nil` when no brand token matches — the detail screen falls
    /// back to the generic "not a GLP-1" path without showing the chart
    /// entry-point.
    public static func detectDrugID(fromMedicationName name: String) -> DrugID? {
        let needle = name.lowercased()
        // Direct full-string match first (handles "Mounjaro"/"Ozempic" alone).
        if let id = findDrugID(byBrand: name) { return id }
        // Substring scan — every catalog brand is unique enough that a
        // contains-check won't fire false-positives ("Ozempic Pen" → Ozempic).
        for id in allDrugIDs {
            let record = drug(for: id)
            if record.brands.contains(where: { needle.contains($0.lowercased()) }) {
                return id
            }
        }
        return nil
    }
}

// MARK: - Records

// Each record below mirrors `glp1-knowledge.ts:171-547` line-for-line. The
// per-field source citations remain as inline comments so a reviewer can
// pin a value to its EMA EPAR section without hopping to the TS source.

private extension GLP1DrugCatalog {
    /// §1.1 — Tirzepatide. EMA EPAR cross-validated against Schneck & Urva
    /// 2024 (psp4.13099). Two-compartment per the journal-of-record, but the
    /// PK module renders the one-compartment closed form (MDR boundary).
    static let tirzepatide = DrugRecord(
        id: .tirzepatide,
        inn: "Tirzepatide",
        brands: ["Mounjaro", "Zepbound"],
        route: .subcutaneous,
        brandRoutes: [:],
        drugClass: .gipGlp1DualAgonist,
        pharmacology: Pharmacology(
            halfLifeDays: 5.0,
            tmaxHours: 24,
            absorptionRateHourlyKa: 0.0373, // psp4.13099 Table 3
            bioavailability: 0.8, // EMA EPAR §5.2
            vdLitersPerKg: 0.09, // ~6.45 L / 70 kg per psp4.13099 (Vc + Vp)
            clearanceLPerHour70kg: 0.0329, // psp4.13099 Table 3
            steadyStateWeeks: 4, // EMA EPAR §5.2
            compartmentModel: .twoCompartment
        ),
        titrationStepsMg: [2.5, 5, 7.5, 10, 12.5, 15], // EMA EPAR §4.2
        titrationIntervalWeeks: 4,
        maxDoseMg: 15,
        standardInjectionFrequency: .weekly,
        dosesPerPen: 4, // §6.5 KwikPen
        penType: "KwikPen",
        sourceEMA: makeURL(
            "https://www.ema.europa.eu/en/documents/product-information/mounjaro-epar-product-information_en.pdf"
        ),
        sourceJournal: DrugRecord.JournalCitation(
            citation: "Schneck KB, Urva S. CPT Pharmacometrics Syst Pharmacol. 2024;13(3):494-503.",
            doi: "10.1002/psp4.13099"
        )
    )

    /// §1.2–§1.3 — Semaglutide (Ozempic SC, Wegovy SC, Rybelsus oral).
    static let semaglutide = DrugRecord(
        id: .semaglutide,
        inn: "Semaglutide",
        brands: ["Ozempic", "Wegovy", "Rybelsus"],
        route: .subcutaneous,
        brandRoutes: [
            "Ozempic": .subcutaneous,
            "Wegovy": .subcutaneous,
            "Rybelsus": .oral
        ],
        drugClass: .glp1ReceptorAgonist,
        pharmacology: Pharmacology(
            halfLifeDays: 7.0, // EMA EPAR §5.2 (≈ 1 week)
            tmaxHours: 24,
            absorptionRateHourlyKa: nil, // EMA EPAR does not publish a pop-PK Ka
            bioavailability: 0.89, // EMA Ozempic §5.2
            vdLitersPerKg: 0.18, // Wegovy §5.2 (~12.4 L / 70 kg)
            clearanceLPerHour70kg: 0.05,
            steadyStateWeeks: 5,
            compartmentModel: .twoCompartment
        ),
        titrationStepsMg: [0.25, 0.5, 1, 2],
        titrationIntervalWeeks: 4,
        maxDoseMg: 2,
        standardInjectionFrequency: .weekly,
        dosesPerPen: 4,
        penType: "FlexTouch",
        sourceEMA: makeURL(
            "https://www.ema.europa.eu/en/documents/product-information/ozempic-epar-product-information_en.pdf"
        ),
        sourceJournal: nil
    )

    /// §1.4 — Liraglutide (Saxenda weight-mgmt, Victoza T2DM). Daily SC.
    static let liraglutide = DrugRecord(
        id: .liraglutide,
        inn: "Liraglutide",
        brands: ["Saxenda", "Victoza"],
        route: .subcutaneous,
        brandRoutes: [:],
        drugClass: .glp1ReceptorAgonist,
        pharmacology: Pharmacology(
            halfLifeDays: 13.0 / 24.0, // ≈ 13 h per EMA EPAR §5.2
            tmaxHours: 11,
            absorptionRateHourlyKa: nil,
            bioavailability: 0.55,
            vdLitersPerKg: 0.22,
            clearanceLPerHour70kg: 1.2,
            steadyStateWeeks: 1,
            compartmentModel: .twoCompartment
        ),
        titrationStepsMg: [0.6, 1.2, 1.8, 2.4, 3.0],
        titrationIntervalWeeks: 1,
        maxDoseMg: 3.0,
        standardInjectionFrequency: .daily,
        dosesPerPen: nil, // continuous-dial pen, doses vary
        penType: "Pre-filled pen",
        sourceEMA: makeURL(
            "https://www.ema.europa.eu/en/documents/product-information/saxenda-epar-product-information_en.pdf"
        ),
        sourceJournal: nil
    )

    /// §1.5 — Dulaglutide (Trulicity). Weekly SC, half-life ~5 d.
    static let dulaglutide = DrugRecord(
        id: .dulaglutide,
        inn: "Dulaglutide",
        brands: ["Trulicity"],
        route: .subcutaneous,
        brandRoutes: [:],
        drugClass: .glp1ReceptorAgonist,
        pharmacology: Pharmacology(
            halfLifeDays: 5.0,
            tmaxHours: 48,
            absorptionRateHourlyKa: nil,
            bioavailability: 0.47,
            vdLitersPerKg: 0.27,
            clearanceLPerHour70kg: 0.107,
            steadyStateWeeks: 2,
            compartmentModel: .twoCompartment
        ),
        titrationStepsMg: [0.75, 1.5, 3.0, 4.5],
        titrationIntervalWeeks: 4,
        maxDoseMg: 4.5,
        standardInjectionFrequency: .weekly,
        dosesPerPen: 1, // disposable single-dose
        penType: "Single-dose pen",
        sourceEMA: makeURL(
            "https://www.ema.europa.eu/en/documents/product-information/trulicity-epar-product-information_en.pdf"
        ),
        sourceJournal: nil
    )

    /// Exenatide — Byetta IR (twice-daily) as default record; Bydureon ER
    /// listed as a brand but its weekly cadence is documented in the EPAR
    /// separately. The catalog captures the IR profile to stay safe — the
    /// PK math degrades gracefully for ER if a user logs Bydureon.
    static let exenatide = DrugRecord(
        id: .exenatide,
        inn: "Exenatide",
        brands: ["Byetta", "Bydureon"],
        route: .subcutaneous,
        brandRoutes: [:],
        drugClass: .glp1ReceptorAgonist,
        pharmacology: Pharmacology(
            halfLifeDays: 2.4 / 24.0, // Byetta IR — ~2.4 h per EMA EPAR §5.2
            tmaxHours: 2.1,
            absorptionRateHourlyKa: nil,
            bioavailability: 0.65,
            vdLitersPerKg: 0.4,
            clearanceLPerHour70kg: 9.1,
            steadyStateWeeks: 1,
            compartmentModel: .twoCompartment
        ),
        titrationStepsMg: [0.005, 0.01], // Byetta 5 µg → 10 µg twice daily
        titrationIntervalWeeks: 4,
        maxDoseMg: 0.01,
        standardInjectionFrequency: .twiceDaily,
        dosesPerPen: 60, // Byetta 60 doses per pen
        penType: "Pre-filled pen (Byetta) / weekly suspension (Bydureon)",
        sourceEMA: makeURL(
            "https://www.ema.europa.eu/en/documents/product-information/byetta-epar-product-information_en.pdf"
        ),
        sourceJournal: nil
    )

    /// Static-init URL helper. URLs in the catalog are hard-coded EMA links
    /// already in the server source; the force-unwrap reflects "this string
    /// is a valid URL by construction" and a malformed value here would be
    /// caught by the catalog-drift test on first run.
    static func makeURL(_ string: String) -> URL {
        // swiftlint:disable:next force_unwrapping
        URL(string: string)!
    }
}
