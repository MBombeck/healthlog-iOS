import Foundation

public extension MedicalSourceCatalog {
    /// Sources for a surface. Order = display order. Fail-closed for unknown
    /// combinations (empty). GLP-1 topics append the drug's EMA EPAR and, when
    /// present, its journal citation — the only dynamic entries.
    static func sources(for topic: MedicalSourceTopic) -> [MedicalSource] {
        ids(for: topic).map(source)
    }

    // A table-driven topic→ids map necessarily switches over every case;
    // splitting it would only hide the same complexity behind more indirection.
    // swiftlint:disable cyclomatic_complexity
    internal static func ids(for topic: MedicalSourceTopic) -> [MedicalSourceID] {
        switch topic {
        case .correlations: [.benjaminiHochberg1995]
        case let .metric(kind): sources(forMetric: kind)
        // 1.0.3 (App Review 1.4.1, audit row 6) — the `.aiAssistant` methodology
        // text says the answers are grounded in published references, and the
        // sheet then listed none. Same six as `.healthScore`: they ARE the
        // guideline basis of every band the assistant reads a value against.
        // The sheet adds a row into the hub for everything else (`showsHubLink`).
        // swiftlint:disable literal_expression_end_indentation
        case .aiAssistant: [
                .esh2023Hypertension,
                .ada2024Glycemic,
                .who2020PhysicalActivity,
                .aasm2015AdultSleep,
                .who2011Waist,
                .escEas2019Dyslipidaemia
            ]
        // swiftlint:enable literal_expression_end_indentation
        case .pulsePressureMAP: [.statpearlsPulsePressure, .statpearlsMap]
        case .bloodPressureClassification: [.esh2023Hypertension, .esc2024Bp, .accAha2017Bp]
        case .bmi: [.who2000Bmi, .who2011Waist]
        case let .derivedScore(metric): derivedScoreSources(metric)
        case .healthStatus: []
        case .breathing: [.appleSleepApnea]
        case .ecgRhythm: [.appleEcg, .appleIrregularRhythm]
        case .sleepRhythm: [.roenneberg2003Mctq, .wittmann2006SocialJetlag, .phillips2017Sri, .aasm2015AdultSleep]
        // swiftlint:disable literal_expression_end_indentation
        case .healthScore: [
                .esh2023Hypertension,
                .ada2024Glycemic,
                .who2020PhysicalActivity,
                .aasm2015AdultSleep,
                .who2011Waist,
                .escEas2019Dyslipidaemia
            ]
        // swiftlint:enable literal_expression_end_indentation
        case .rangeBands: []
        case .medicationCompliance: []
        case .glp1Pharmacokinetics, .titration: [] // dynamic, see `dynamicSources(for:)`
        case .injectionRotation: [.frid2016InjectionTechnique]
        case .glucoseTargets: [.ada2024Glycemic, .whoIdf2006Glucose]
        case let .labBiomarker(slug): labSources(slug)
        case .labReferenceRanges: [.abimLabReferenceRanges, .escEas2019Dyslipidaemia, .ada2024Glycemic, .kdigo2012Ckd, .who2024Haemoglobin]
        case let .mentalHealth(instrument): mentalHealthSources(instrument)
        case let .personalRecords(kind): personalRecordSources(kind)
        case .nutrition: [.efsaDrv]
        case .cycle: [.acogCo6512015, .wilcox2000FertileWindow]
        case .mood: []
        case .illnessRecovery: []
        case .vorsorge: []
        }
    }

    // swiftlint:enable cyclomatic_complexity

    /// Drug-specific EMA EPAR / journal citations rendered by the sheet as
    /// extra rows (not `MedicalSource`s — they come from `GLP1DrugCatalog`).
    struct DynamicSource: Identifiable, Sendable, Hashable {
        public let id: String
        public let name: String
        public let url: URL
    }

    static func dynamicSources(for topic: MedicalSourceTopic) -> [DynamicSource] {
        switch topic {
        case let .glp1Pharmacokinetics(drugID), let .titration(drugID):
            let record = GLP1DrugCatalog.drug(for: drugID)
            var out = [DynamicSource(id: "ema-\(drugID.rawValue)", name: "EMA EPAR — \(record.inn)", url: record.sourceEMA)]
            if let j = record.sourceJournal, let url = URL(string: "https://doi.org/\(j.doi)") {
                out.append(DynamicSource(id: "doi-\(j.doi)", name: j.citation, url: url))
            }
            return out
        default:
            return []
        }
    }

    // A table-driven metric→ids map necessarily switches over every case;
    // splitting it would only hide the same complexity behind more indirection.
    // swiftlint:disable cyclomatic_complexity
    static func sources(forMetric kind: MetricKind) -> [MedicalSourceID] {
        switch kind {
        case .restingHeartRate, .pulse, .walkingHeartRate, .averageHeartRate, .maxHeartRate: [.aha2024Rhr]
        case .hrv, .hrvRMSSD: [.escNaspe1996Hrv]
        case .bloodPressure: [.esh2023Hypertension, .esc2024Bp, .accAha2017Bp]
        case .spo2: [.statpearlsPulseOx, .fda2024PulseOx]
        case .respiratoryRate: [.alaRespiratoryRate, .rcp2017News2]
        case .bodyTemperature, .wristTemperature, .skinTemperature, .bodyTemperatureDeviation: [.jgim2019Temperature]
        case .glucose: [.ada2024Glycemic, .whoIdf2006Glucose]
        case .vo2Max: [.nes2011FitnessAge]
        case .weight, .bmi: [.who2000Bmi]
        case .bodyFat, .fatMass, .fatFreeMass, .leanBodyMass, .muscleMass: [.aceBodyFatStandards]
        case .visceralFat: [.vatImagingThreshold]
        case .bodyWater: [.watson1980Tbw, .icrp89ReferenceMan]
        case .waistCircumference, .waistToHeight: [.who2011Waist]
        case .steps, .distanceWalkingRunning: [.stepsSaintMaurice2020, .tudorLocke2011Steps, .who2020PhysicalActivity]
        case .activeEnergy, .flightsClimbed, .energyExpenditureKJ: [.who2020PhysicalActivity]
        case .sleep, .sleepScore, .sleepEfficiency, .sleepConsistency, .sleepNeed, .sleepPerformance, .sleepDisturbanceCount:
            [.aasm2015AdultSleep, .hirshkowitz2015NsfSleep, .cdc2024Sleep]
        case .pulseWaveVelocity, .vascularAge: [.escEsh2018Pwv]
        case .phq9Score: [.kroenke2001Phq9]
        case .gad7Score: [.spitzer2006Gad7]
        case .who5Score: [.topp2015Who5]
        case .sciScore: [.espie2014Sci]
        case .recoveryScore, .stressScore, .strainScore, .resilience, .ansCharge, .cardioLoad, .dayStrain, .workoutStrain,
             .cardioRecovery: [.escNaspe1996Hrv]
        case .gripStrength: [.leong2015Grip]
        case .sixMinuteWalk: [.ats2002SixMinuteWalk]
        case .audioExposureEnvironment, .audioExposureHeadphone: [.who2018Noise]
        case .walkingSteadiness, .falls, .stairAscentSpeed, .stairDescentSpeed: [.appleWalkingSteadiness]
        case .walkingSpeed, .walkingAsymmetry, .walkingDoubleSupport, .walkingStepLength: [.studenski2011GaitSpeed, .appleWalkingSteadiness]
        case .breathingDisturbances: [.appleSleepApnea]
        case .boneMass: [.icrp89ReferenceMan]
        case .timeInDaylight: [.who2020PhysicalActivity]
        case .mood: [.topp2015Who5]
        // Deliberately empty, not an oversight: `.painNRS` is a self-report on a
        // 0–10 rail the methodology text already explains, `.unknown` is the
        // decode sentinel, and the six device-event kinds
        // (`.irregularRhythmNotification`, `.highHeartRateEvent`,
        // `.lowHeartRateEvent`, `.walkingSteadinessEvent`,
        // `.breathingDisturbanceEvent`, `.audioExposureEvent`) carry the device
        // attribution as their citation — naming the manufacturer's own
        // detection is the honest source, a guideline paper would not be.
        default: []
        }
    }

    // swiftlint:enable cyclomatic_complexity

    private static func derivedScoreSources(_ metric: String) -> [MedicalSourceID] {
        switch metric {
        case "READINESS": [.aha2024Rhr, .escNaspe1996Hrv, .aasm2015AdultSleep]
        case "SLEEP_SCORE": [.aasm2015AdultSleep, .hirshkowitz2015NsfSleep]
        case "RECOVERY_SCORE", "STRESS_SCORE", "HRV_BALANCE": [.escNaspe1996Hrv]
        case "STRAIN_SCORE": [.who2020PhysicalActivity, .aha2024Rhr]
        case "FITNESS_AGE": [.nes2011FitnessAge]
        case "VASCULAR_AGE_DELTA": [.escEsh2018Pwv]
        default: []
        }
    }

    // A table-driven slug→ids map necessarily switches over every case;
    // splitting it would only hide the same complexity behind more indirection.
    // swiftlint:disable:next cyclomatic_complexity
    private static func labSources(_ slug: String) -> [MedicalSourceID] {
        switch slug {
        case "total-cholesterol", "ldl", "hdl", "triglycerides", "apob": [.escEas2019Dyslipidaemia]
        case "lp-a": [.eas2022Lpa, .escEas2019Dyslipidaemia]
        case "omega-3-index": [.harris2004Omega3Index]
        case "fasting-glucose", "hba1c": [.ada2024Glycemic, .whoIdf2006Glucose]
        case "fasting-insulin", "homa-ir": [.matthews1985HomaIr, .ada2024Glycemic]
        case "tsh", "ft3", "ft4": [.jonklaas2014AtaThyroid]
        case "ferritin", "transferrin-saturation": [.who2020Ferritin]
        case "vitamin-d": [.holick2011VitaminD]
        case "vitamin-b12", "folate": [.abimLabReferenceRanges]
        case "hs-crp": [.pearson2003Crp]
        case "creatinine", "egfr": [.kdigo2012Ckd]
        case "hemoglobin", "hematocrit": [.who2024Haemoglobin]
        case "alt", "ast", "ggt", "sodium", "potassium", "wbc", "platelets": [.abimLabReferenceRanges]
        default: [.abimLabReferenceRanges]
        }
    }

    private static func mentalHealthSources(_ instrument: MentalHealthInstrument) -> [MedicalSourceID] {
        switch instrument.rawValue {
        case "PHQ9": [.kroenke2001Phq9]
        case "GAD7": [.spitzer2006Gad7]
        case "WHO5": [.topp2015Who5]
        case "SCI": [.espie2014Sci]
        default: []
        }
    }

    private static func personalRecordSources(_ kind: MetricKind) -> [MedicalSourceID] {
        switch kind {
        case .restingHeartRate: [.cdcNhanes, .aha2024Rhr]
        case .bloodPressure: [.accAha2017Bp, .esh2023Hypertension]
        case .bodyFat: [.aceBodyFatStandards]
        case .spo2: [.statpearlsPulseOx]
        case .bmi: [.who2000Bmi]
        case .steps: [.tudorLocke2011Steps, .cdcNhanes]
        case .sleep: [.hirshkowitz2015NsfSleep, .cdc2024Sleep]
        default: sources(forMetric: kind)
        }
    }

    // swiftlint:disable cyclomatic_complexity
    /// Localized methodology paragraph key per topic (`sources.method.<name>`),
    /// `nil` when a topic is reference-only. A table-driven topic→key map
    /// necessarily switches over every case; splitting it would only hide
    /// the same complexity behind more indirection.
    static func methodologyKey(for topic: MedicalSourceTopic) -> String? {
        switch topic {
        case .correlations: "sources.method.correlations"
        // A kind with no references must not open a sheet whose method text
        // promises "the references below" — `HLSourcesLink` then self-suppresses.
        case let .metric(kind): sources(forMetric: kind).isEmpty ? nil : "sources.method.metricExplainer"
        case .aiAssistant: "sources.method.aiAssistant"
        case .pulsePressureMAP: "sources.method.pulsePressureMAP"
        case .bloodPressureClassification: "sources.method.bpClassification"
        case .bmi: "sources.method.bmi"
        case .derivedScore: "sources.method.derivedScores"
        case .healthStatus: "sources.method.healthStatus"
        case .breathing: "sources.method.breathing"
        case .ecgRhythm: "sources.method.ecgRhythm"
        case .sleepRhythm: "sources.method.sleepRhythm"
        case .healthScore: "sources.method.healthScore"
        case .rangeBands: "sources.method.rangeBands"
        case .medicationCompliance: "sources.method.medicationCompliance"
        case .glp1Pharmacokinetics: "sources.method.glp1PK"
        case .titration: "sources.method.titration"
        case .injectionRotation: "sources.method.injectionRotation"
        case .glucoseTargets: "sources.method.glucoseTargets"
        case .labBiomarker: "sources.method.labBiomarker"
        case .labReferenceRanges: "sources.method.labReferenceRanges"
        case .mentalHealth: "sources.method.mentalHealth"
        case .personalRecords: "sources.method.personalRecords"
        case .nutrition: "sources.method.nutrition"
        case .cycle: "sources.method.cycle"
        case .mood: "sources.method.mood"
        case .illnessRecovery: "sources.method.illnessRecovery"
        case .vorsorge: "sources.method.vorsorge"
        }
    }

    // swiftlint:enable cyclomatic_complexity

    /// Every methodology key, for the hub. Order = hub display order.
    static let allMethodologyKeys: [(titleKey: String, bodyKey: String)] = [
        ("sources.methodTitle.correlations", "sources.method.correlations"),
        ("sources.methodTitle.healthScore", "sources.method.healthScore"),
        ("sources.methodTitle.derivedScores", "sources.method.derivedScores"),
        ("sources.methodTitle.rangeBands", "sources.method.rangeBands"),
        ("sources.methodTitle.metricExplainer", "sources.method.metricExplainer"),
        ("sources.methodTitle.bpClassification", "sources.method.bpClassification"),
        ("sources.methodTitle.pulsePressureMAP", "sources.method.pulsePressureMAP"),
        ("sources.methodTitle.bmi", "sources.method.bmi"),
        ("sources.methodTitle.healthStatus", "sources.method.healthStatus"),
        ("sources.methodTitle.sleepRhythm", "sources.method.sleepRhythm"),
        ("sources.methodTitle.breathing", "sources.method.breathing"),
        ("sources.methodTitle.ecgRhythm", "sources.method.ecgRhythm"),
        ("sources.methodTitle.medicationCompliance", "sources.method.medicationCompliance"),
        ("sources.methodTitle.glp1PK", "sources.method.glp1PK"),
        ("sources.methodTitle.titration", "sources.method.titration"),
        ("sources.methodTitle.injectionRotation", "sources.method.injectionRotation"),
        ("sources.methodTitle.glucoseTargets", "sources.method.glucoseTargets"),
        ("sources.methodTitle.labBiomarker", "sources.method.labBiomarker"),
        ("sources.methodTitle.labReferenceRanges", "sources.method.labReferenceRanges"),
        ("sources.methodTitle.mentalHealth", "sources.method.mentalHealth"),
        ("sources.methodTitle.personalRecords", "sources.method.personalRecords"),
        ("sources.methodTitle.nutrition", "sources.method.nutrition"),
        ("sources.methodTitle.cycle", "sources.method.cycle"),
        ("sources.methodTitle.mood", "sources.method.mood"),
        ("sources.methodTitle.illnessRecovery", "sources.method.illnessRecovery"),
        ("sources.methodTitle.aiAssistant", "sources.method.aiAssistant"),
        ("sources.methodTitle.vorsorge", "sources.method.vorsorge")
    ]
}
