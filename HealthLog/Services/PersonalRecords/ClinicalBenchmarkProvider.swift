import Foundation

/// v0.5.5.7 RECONCILE-COMPARE — clinical-benchmark provider for the
/// `PersonalRecordsScreen` comparison band (POLISH-PR deferred #5).
///
/// **Why a protocol seam:** the live provider hard-codes population
/// means + std-devs per `MetricKind` so the comparison band paints
/// without a server round-trip. Tests substitute an in-memory stub.
/// A future server-shipped clinical-range endpoint (`/api/insights/
/// benchmarks/:kind`) can swap to a remote impl without touching the
/// view.
///
/// **Scope contract:** these are *rough* population reference points,
/// not medical advice. The disclaimer is enforced at the view layer
/// via `BenchmarkSourceSheet` — every band tap surfaces the source +
/// "kein medizinischer Befund" copy.
///
/// **Direction semantics:** for `min`-direction kinds (resting HR,
/// body fat — lower is better) and `max`-direction kinds (steps,
/// sleep — higher is better), the band rendering stays the same: we
/// always plot mean ± 1σ as a horizontal stripe and place the user's
/// value as a tick on that stripe. The `RangeFavorability` field
/// helps the consumer surface a sentence like "Dein Wert liegt
/// unterhalb des typischen Bereichs" with the correct semantic.
public protocol ClinicalBenchmarkProvider: Sendable {
    /// Returns the population reference for `kind`, or `nil` when we
    /// don't carry benchmark data for that kind. Callers MUST tolerate
    /// `nil` — the comparison band omits itself when the provider has
    /// nothing to render.
    func benchmark(for kind: MetricKind) -> ClinicalBenchmark?
}

/// One population reference snapshot — the mean + 1σ band plus
/// metadata for label + accessibility output.
///
/// **Sources:** see per-case comments in
/// `LiveClinicalBenchmarkProvider.lookup(_:)`. Every figure cites the
/// most recent CDC NHANES or WHO/AHA publication available at
/// authoring time (2026-05). A clinical advisor pass would refine
/// these against per-cohort tables (age-band, gender, BMI-adjusted).
public struct ClinicalBenchmark: Sendable, Equatable {
    /// Population mean for the metric in the unit the
    /// `PersonalRecord.base.unit` ships in (so the band's tick and
    /// the user value line up without unit conversion at the view).
    public let mean: Double
    /// One standard deviation. The band renders `mean - sigma` to
    /// `mean + sigma` so ~68% of the population lands inside the
    /// stripe.
    public let sigma: Double
    /// Optional clinical floor — values below this are clinically
    /// concerning regardless of population distribution (e.g. SpO₂
    /// < 95% per WHO clinical reference). Drives the optional
    /// "Klinische Untergrenze"-line annotation.
    public let clinicalFloor: Double?
    /// Optional clinical ceiling — symmetric counterpart for
    /// hyper-bounds (BP systolic > 140, BMI > 25 etc.). The band
    /// passes this through to the view for the dashed-rule overlay.
    public let clinicalCeiling: Double?
    /// Direction of "good" — whether the user wants to land below or
    /// above the mean. Drives the favorability copy.
    public let favorability: Favorability
    /// One-line population descriptor for the disclaimer sheet
    /// (e.g. "CDC NHANES 2017-2020, Erwachsene 20+ J.").
    public let sourceLabel: String

    public init(
        mean: Double,
        sigma: Double,
        clinicalFloor: Double? = nil,
        clinicalCeiling: Double? = nil,
        favorability: Favorability,
        sourceLabel: String
    ) {
        self.mean = mean
        self.sigma = sigma
        self.clinicalFloor = clinicalFloor
        self.clinicalCeiling = clinicalCeiling
        self.favorability = favorability
        self.sourceLabel = sourceLabel
    }

    /// Encodes which side of the mean the user's wellbeing benefits
    /// from. `.lowerIsBetter` for resting HR, body fat, BMI (above
    /// healthy band). `.higherIsBetter` for steps, sleep duration.
    /// `.centered` when the bullseye is the mean itself (BP systolic
    /// at ~120 mmHg — both too-low and too-high are sub-optimal).
    public enum Favorability: String, Sendable, Equatable {
        case lowerIsBetter
        case higherIsBetter
        case centered
    }

    /// Returns the band's lower edge. Clamped to 0 because every
    /// metric we benchmark is non-negative.
    public var bandLow: Double {
        max(0, mean - sigma)
    }

    /// Returns the band's upper edge.
    public var bandHigh: Double {
        mean + sigma
    }

    /// Classifies `value` against the band. Drives the one-line
    /// summary the comparison band renders.
    public func classify(_ value: Double) -> Region {
        if value < bandLow {
            return .belowBand
        }
        if value > bandHigh {
            return .aboveBand
        }
        return .insideBand
    }

    /// Three-region classification for the band tick.
    public enum Region: String, Sendable, Equatable {
        case belowBand
        case insideBand
        case aboveBand
    }
}

/// Live clinical-benchmark provider with hardcoded population
/// references per `MetricKind`. Single source of truth for the
/// comparison-band data.
///
/// **Data provenance (every figure auditable):**
/// - `restingHeartRate`: 70 bpm mean, σ ≈ 12. Source: AHA "Target
///   Heart Rates Chart" + CDC NHANES 2017-2020 resting-pulse
///   summary (adults 20+). Clinical floor 50 bpm (bradycardia
///   threshold per Mayo Clinic clinical guideline 2022).
/// - `bloodPressure` (composite — uses `value` as systolic; the
///   server PR row for blood pressure is systolic-anchored per
///   `MetricTypeKindResolver` `BP_SYSTOLIC`/`BLOOD_PRESSURE_SYS`):
///   120 mmHg mean, σ 12. Source: AHA 2017 guideline "Normal
///   <120 / <80" + ESH 2023 reference adult population. Clinical
///   ceiling 140 mmHg (Stage 2 hypertension per AHA 2017).
/// - `bodyFat`: 25% mean for a general-adult average, σ 6. Source:
///   ACE Fitness body-fat-percentage chart + ACSM (gender-pooled,
///   ages 20-60). NOTE: per-gender / per-age tables exist and would
///   refine this — flagged in the source sheet as "rough average".
/// - `spo2` (oxygen saturation): 97% mean, σ 2. Clinical floor 95%
///   (WHO clinical-reference cut-off for normal at sea level).
/// - `bmi`: 24 mean, σ 4. Source: WHO BMI classification (healthy
///   band 18.5–24.9). Clinical floor 18.5 (underweight),
///   clinical ceiling 25 (overweight threshold per WHO 2020).
/// - `steps`: 7500 steps/day mean, σ 3000. Source: Tudor-Locke
///   et al. (2011) "How many steps/day are enough?" + CDC adult
///   physical-activity surveillance reports 2019-2023. Often-cited
///   10k figure has weak empirical basis; 7500 better reflects
///   measured adult population means.
/// - `sleep`: 7 hours mean, σ 1. Source: NSF 2015 sleep duration
///   recommendations (adult target 7-9h) + CDC BRFSS 2020 average
///   adult sleep duration (~7.0 h).
///
/// **What we do NOT benchmark (intentional gaps):**
/// - `pulse` (resting vs. exertional ambiguity — server doesn't
///   yet flag the PR row context, so a single benchmark would
///   mislead).
/// - `hrv` (SDNN values vary 2–3× across age cohorts; without
///   user's age the band would be misleading).
/// - `vo2Max` (Cooper benchmark requires age + gender;
///   single-value would mislead).
/// - `glucose` (fasting vs. random vs. post-prandial split is
///   load-bearing for clinical interpretation; single benchmark
///   would dangerously over-simplify).
/// - `bodyTemperature` (Fever bounds are clinically meaningful;
///   population stat would dilute the message — better surfaced
///   via the existing alert path).
/// - `weight`, `bodyWater`, `boneMass`, `walkingSpeed`,
///   `walkingAsymmetry`, `walkingStepLength` (no broadly-applicable
///   single-value benchmark; height/age/gender split is
///   load-bearing).
public struct LiveClinicalBenchmarkProvider: ClinicalBenchmarkProvider {
    public init() {}

    public func benchmark(for kind: MetricKind) -> ClinicalBenchmark? {
        switch kind {
        case .restingHeartRate:
            ClinicalBenchmark(
                mean: 70,
                sigma: 12,
                clinicalFloor: 50,
                clinicalCeiling: 100,
                favorability: .lowerIsBetter,
                sourceLabel: "CDC NHANES 2017-2020 + AHA Resting-Heart-Rate Chart"
            )
        case .bloodPressure:
            // Treat the server PR `value` as systolic — `BP_SYSTOLIC`
            // is the slot the server ships records for. Diastolic
            // benchmark is carried as a separate constant below but
            // the screen only surfaces systolic for now.
            ClinicalBenchmark(
                mean: 120,
                sigma: 12,
                clinicalFloor: 90,
                clinicalCeiling: 140,
                favorability: .centered,
                sourceLabel: "AHA 2017 + ESH 2023 (Systolisch, Erwachsenen-Population)"
            )
        case .bodyFat:
            ClinicalBenchmark(
                mean: 25,
                sigma: 6,
                clinicalFloor: nil,
                clinicalCeiling: nil,
                favorability: .lowerIsBetter,
                sourceLabel: "ACE Fitness Body-Fat-Chart + ACSM (rough, gender-pooled)"
            )
        case .spo2:
            ClinicalBenchmark(
                mean: 97,
                sigma: 2,
                clinicalFloor: 95,
                clinicalCeiling: nil,
                favorability: .higherIsBetter,
                sourceLabel: "WHO klinische Untergrenze (Meereshöhe)"
            )
        case .bmi:
            ClinicalBenchmark(
                mean: 24,
                sigma: 4,
                clinicalFloor: 18.5,
                clinicalCeiling: 25,
                favorability: .centered,
                sourceLabel: "WHO BMI-Klassifikation (gesunder Bereich 18,5–24,9)"
            )
        case .steps:
            ClinicalBenchmark(
                mean: 7500,
                sigma: 3000,
                clinicalFloor: nil,
                clinicalCeiling: nil,
                favorability: .higherIsBetter,
                sourceLabel: "Tudor-Locke et al. 2011 + CDC BRFSS 2019-2023"
            )
        case .sleep:
            ClinicalBenchmark(
                mean: 7,
                sigma: 1,
                clinicalFloor: 6,
                clinicalCeiling: 9,
                favorability: .higherIsBetter,
                sourceLabel: "NSF 2015 Empfehlung (Erwachsene 7-9 h) + CDC BRFSS 2020"
            )
        case .weight,
             .pulse,
             .glucose,
             .bodyTemperature,
             .bodyWater,
             .boneMass,
             .hrv,
             .vo2Max,
             .walkingSpeed,
             .walkingAsymmetry,
             .walkingStepLength,
             .walkingDoubleSupport,
             .walkingSteadiness,
             .respiratoryRate,
             .audioExposureEnvironment,
             .audioExposureHeadphone,
             // v0.8.3 W-D — no population benchmark for these activity aggregates.
             .activeEnergy,
             .flightsClimbed,
             .distanceWalkingRunning,
             .timeInDaylight,
             // v0.11 W21 — no broadly-applicable single-value benchmark for the
             // body-composition + arterial metrics (age/gender split is
             // load-bearing) or walking-HR.
             .fatFreeMass,
             .leanBodyMass,
             .muscleMass,
             .skinTemperature,
             .pulseWaveVelocity,
             .vascularAge,
             .visceralFat,
             .walkingHeartRate,
             .fatMass,
             // v0.13.1 IC — no broadly-applicable single-value population
             // benchmark for the v1.10.0 additive signals (age/fitness split is
             // load-bearing; the user's own baseline leads, mirroring the
             // server registry's no-fixed-band stance).
             .falls,
             .sixMinuteWalk,
             .stairAscentSpeed,
             .stairDescentSpeed,
             .breathingDisturbances,
             .cardioRecovery,
             .wristTemperature,
             // v0.14.6 — v1.12.8 WHOOP-native types: the user's own baseline
             // leads (no broadly-applicable single-value population benchmark).
             .averageHeartRate,
             .maxHeartRate,
             .sleepDisturbanceCount,
             // v0.14.1 W-B189 — v1.17.1 source-fixed signals (#23): vendor-
             // derived scores + a personal-baseline temperature offset; no fixed
             // population benchmark (the user's own baseline leads).
             .ansCharge,
             .cardioLoad,
             .sleepScore,
             .bodyTemperatureDeviation,
             // v0158 — v1.25 clinical types: no fixed population benchmark wired
             // yet (the user's own baseline leads); the server bands lead at the
             // display edge.
             .painNRS,
             .gripStrength,
             .waistCircumference,
             .waistToHeight,
             // Build 3 / item 3.3 — the 21 decoder catch-up types. Wearable
             // scores are vendor-scaled and the screener sums have clinical
             // cut-offs the SERVER owns, so iOS wires no population benchmark:
             // the user's own baseline leads.
             .phq9Score, .gad7Score, .who5Score, .sciScore,
             .recoveryScore, .stressScore, .strainScore, .hrvRMSSD,
             .dayStrain, .workoutStrain, .sleepPerformance, .sleepEfficiency,
             .sleepConsistency, .sleepNeed, .energyExpenditureKJ, .resilience,
             .irregularRhythmNotification, .highHeartRateEvent, .lowHeartRateEvent,
             .walkingSteadinessEvent, .breathingDisturbanceEvent,
             // Build 7 / item 7.3 — mood is a subjective daily score with no
             // population benchmark (the user's own baseline leads).
             .mood:
            nil
        }
    }
}
