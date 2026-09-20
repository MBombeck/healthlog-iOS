import Foundation

/// **1.0.3 (App Review 1.4.1) — one cited medical source.**
///
/// The iOS mirror of the server's `Citation` (`src/lib/medical-citations.ts`).
/// `name` is canonical and never translated (same rule as the server's
/// `citationLabel`); the caveat IS localized and lives under
/// `sources.caveat.<id>` in `Localizable.xcstrings`.
public struct MedicalSource: Identifiable, Sendable, Hashable {
    public let id: MedicalSourceID
    public let name: String
    public let year: Int
    public let url: URL

    public var caveatKey: String {
        "sources.caveat.\(id.rawValue)"
    }
}

/// Stable ids. Server ids are mirrored 1:1; iOS-only additions carry the same
/// `<author-or-body>-<year>-<subject>` shape.
public enum MedicalSourceID: String, CaseIterable, Sendable {
    // server-mirrored
    case esh2023Hypertension = "esh-2023-hypertension"
    case stepsSaintMaurice2020 = "steps-saint-maurice-2020"
    case who2020PhysicalActivity = "who-2020-physical-activity"
    case bts2017EmergencyOxygen = "bts-2017-emergency-oxygen"
    case niceNg115Copd = "nice-ng115-copd"
    case ada2024Glycemic = "ada-2024-glycemic"
    case ispad2022Pediatric = "ispad-2022-pediatric"
    case aceBodyFatStandards = "ace-body-fat-standards"
    case aasm2015AdultSleep = "aasm-2015-adult-sleep"
    case watson1980Tbw = "watson-1980-tbw"
    case icrp89ReferenceMan = "icrp-89-reference-man"
    case aha2024Rhr = "aha-2024-rhr"
    case statpearlsPulseOx = "statpearls-pulse-ox"
    case accAha2017Bp = "acc-aha-2017-bp"
    case esc2024Bp = "esc-2024-bp"
    case statpearlsPulsePressure = "statpearls-pulse-pressure"
    case statpearlsMap = "statpearls-map"
    case escEsh2018Pwv = "esc-esh-2018-pwv"
    case fda2024PulseOx = "fda-2024-pulse-ox"
    case jgim2019Temperature = "jgim-2019-temperature"
    case rcp2017News2 = "rcp-2017-news2"
    case alaRespiratoryRate = "ala-respiratory-rate"
    case vatImagingThreshold = "vat-imaging-threshold"
    case wilcox2000FertileWindow = "wilcox-2000-fertile-window"
    case acogCo6512015 = "acog-co651-2015"
    case phillips2017Sri = "phillips-2017-sri"
    case cdc2024Sleep = "cdc-2024-sleep"
    case who2000Bmi = "who-2000-bmi"
    case whoIdf2006Glucose = "who-idf-2006-glucose"
    case escNaspe1996Hrv = "esc-naspe-1996-hrv"
    // iOS additions
    case benjaminiHochberg1995 = "benjamini-hochberg-1995"
    case escEas2019Dyslipidaemia = "esc-eas-2019-dyslipidaemia"
    case eas2022Lpa = "eas-2022-lpa"
    case kdigo2012Ckd = "kdigo-2012-ckd"
    case matthews1985HomaIr = "matthews-1985-homa-ir"
    case harris2004Omega3Index = "harris-2004-omega3-index"
    case kroenke2001Phq9 = "kroenke-2001-phq9"
    case spitzer2006Gad7 = "spitzer-2006-gad7"
    case topp2015Who5 = "topp-2015-who5"
    case espie2014Sci = "espie-2014-sci"
    case roenneberg2003Mctq = "roenneberg-2003-mctq"
    case wittmann2006SocialJetlag = "wittmann-2006-social-jetlag"
    case tudorLocke2011Steps = "tudor-locke-2011-steps"
    case hirshkowitz2015NsfSleep = "hirshkowitz-2015-nsf-sleep"
    case cdcNhanes = "cdc-nhanes"
    case efsaDrv = "efsa-drv"
    case who2020Ferritin = "who-2020-ferritin"
    case holick2011VitaminD = "holick-2011-vitamin-d"
    case jonklaas2014AtaThyroid = "jonklaas-2014-ata-thyroid"
    case pearson2003Crp = "pearson-2003-crp"
    case who2024Haemoglobin = "who-2024-haemoglobin"
    case abimLabReferenceRanges = "abim-2026-lab-reference-ranges"
    case frid2016InjectionTechnique = "frid-2016-injection-technique"
    case nes2011FitnessAge = "nes-2011-fitness-age"
    case who2011Waist = "who-2011-waist"
    case leong2015Grip = "leong-2015-grip"
    case ats2002SixMinuteWalk = "ats-2002-six-minute-walk"
    case who2018Noise = "who-2018-noise"
    case appleEcg = "apple-ecg"
    case appleIrregularRhythm = "apple-irregular-rhythm"
    case appleWalkingSteadiness = "apple-walking-steadiness"
    case appleSleepApnea = "apple-sleep-apnea"
    case studenski2011GaitSpeed = "studenski-2011-gait-speed"
}

/// Which surface is asking. Fail-closed: a topic the catalog does not know
/// resolves to no sources and no methodology, and the affordance renders
/// nothing (`HLLearnMoreLink` discipline).
public enum MedicalSourceTopic: Hashable, Sendable {
    case correlations
    case metric(MetricKind)
    case aiAssistant
    case pulsePressureMAP
    case bloodPressureClassification
    case bmi
    case derivedScore(String) // DerivedMetricDTO.metric, e.g. "READINESS"
    case healthStatus
    case breathing
    case ecgRhythm
    case sleepRhythm
    case healthScore
    case rangeBands
    case medicationCompliance
    case glp1Pharmacokinetics(GLP1DrugCatalog.DrugID)
    case titration(GLP1DrugCatalog.DrugID)
    case injectionRotation
    case glucoseTargets
    case labBiomarker(String) // catalog slug, e.g. "hs-crp"
    case labReferenceRanges
    case mentalHealth(MentalHealthInstrument)
    case personalRecords(MetricKind)
    case nutrition
    case cycle
    case mood
    case illnessRecovery
    case vorsorge

    /// **1.0.3 (App Review 1.4.1, audit row 6)** — `true` for the one topic whose
    /// sheet also offers a way into the full ``MedicalSourcesScreen`` hub.
    ///
    /// The assistant is the only surface that can talk about ANY metric, so its
    /// six guideline references are a floor, not the whole basis. Every other
    /// topic is scoped to one claim and its own references are the complete
    /// answer — a hub row there would be a shrug where a citation belongs.
    public var showsHubLink: Bool {
        if case .aiAssistant = self { return true }
        return false
    }

    /// Stable, identifier-safe suffix for `accessibilityIdentifier("sources.<suffix>")`.
    public var accessibilitySuffix: String {
        switch self {
        case .correlations: "correlations"
        case let .metric(kind): "metric.\(kind.rawValue)"
        case .aiAssistant: "aiAssistant"
        case .pulsePressureMAP: "pulsePressureMAP"
        case .bloodPressureClassification: "bpClassification"
        case .bmi: "bmi"
        case let .derivedScore(metric): "derived.\(metric)"
        case .healthStatus: "healthStatus"
        case .breathing: "breathing"
        case .ecgRhythm: "ecgRhythm"
        case .sleepRhythm: "sleepRhythm"
        case .healthScore: "healthScore"
        case .rangeBands: "rangeBands"
        case .medicationCompliance: "medicationCompliance"
        case let .glp1Pharmacokinetics(id): "glp1.pk.\(id.rawValue)"
        case let .titration(id): "glp1.titration.\(id.rawValue)"
        case .injectionRotation: "injectionRotation"
        case .glucoseTargets: "glucoseTargets"
        case let .labBiomarker(slug): "lab.\(slug)"
        case .labReferenceRanges: "labReferenceRanges"
        case let .mentalHealth(instrument): "mentalHealth.\(instrument.rawValue)"
        case let .personalRecords(kind): "personalRecords.\(kind.rawValue)"
        case .nutrition: "nutrition"
        case .cycle: "cycle"
        case .mood: "mood"
        case .illnessRecovery: "illnessRecovery"
        case .vorsorge: "vorsorge"
        }
    }

    /// The topics a shipped surface uses — the test asserts each is non-empty.
    /// Keep in lockstep with SPEC.md §4.
    public static let allSurfacedForTest: [MedicalSourceTopic] = [
        .correlations, .metric(.bloodPressure), .aiAssistant, .pulsePressureMAP,
        .bloodPressureClassification, .bmi, .derivedScore("READINESS"), .derivedScore("SLEEP_SCORE"),
        .derivedScore("RECOVERY_SCORE"), .derivedScore("STRESS_SCORE"), .derivedScore("STRAIN_SCORE"),
        .derivedScore("FITNESS_AGE"), .derivedScore("VASCULAR_AGE_DELTA"), .derivedScore("HRV_BALANCE"),
        .healthStatus, .breathing, .ecgRhythm, .sleepRhythm, .healthScore, .rangeBands,
        .medicationCompliance, .glp1Pharmacokinetics(GLP1DrugCatalog.allDrugIDs[0]),
        .titration(GLP1DrugCatalog.allDrugIDs[0]), .injectionRotation, .glucoseTargets,
        .labBiomarker("hs-crp"), .labBiomarker("alt"), .labReferenceRanges,
        .mentalHealth(.phq9), .personalRecords(.restingHeartRate), .nutrition, .cycle, .mood,
        .illnessRecovery, .vorsorge
    ]
}
