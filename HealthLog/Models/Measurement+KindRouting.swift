import Foundation

// Per-kind routing predicates + the availability key table, split out of
// `Measurement.swift` under the PROJECT_GUIDE.md file-length discipline when Build 3 /
// item 3.3 added 21 `MetricKind` cases. **Pure move** — same module, same
// access levels, same behaviour; only the file boundary changes.
//
// What lives here: the predicates that decide HOW a kind is fetched and
// displayed (`isCumulative`, `prefersSeriesForRecent`,
// `suppressesAggregateStats`, `isHighFrequencyVital`) plus the
// `MetricKind` → server `MeasurementType` key table the kind-scoped read path
// and the availability slice both consult.

extension MetricKind {
    /// **V0.5.4-BF-3 cumulative-kind predicate.** `true` for the five HK
    /// kinds whose measurements are per-day aggregates (`stats:HK_ID:DAY`
    /// externalId, see `HealthKitCumulativeTypeConfig.cumulativeIdentifiers`)
    /// + any future server-cumulative kind. Tiles + chart-detail surfaces
    /// for these kinds must compose the displayed value via *same-day sum*
    /// (not "latest single sample"). Operator-reported v0.5.3 bug:
    /// "Schritte zeigt nicht den Tagesgesamtwert" — `.steps` tile rendered
    /// `latest.primaryValue` which on a HK setup that emits per-sample
    /// step rows landed as the most recent batch's count, not the full
    /// day's cumulative.
    var isCumulative: Bool {
        switch self {
        // v0.8.3 W-D: the four activity aggregates the app already collects
        // are per-day cumulative HK rows (`stats:HK_ID:DAY` externalId, see
        // `HealthKitCumulativeTypeConfig.cumulativeIdentifiers`). Their tile +
        // chart-detail surfaces must compose the displayed value via same-day
        // sum, exactly like `.steps`.
        case .steps, .activeEnergy, .flightsClimbed, .distanceWalkingRunning, .timeInDaylight:
            true
        default:
            false
        }
    }

    /// v0.14 b146 (M4) — `true` for low-frequency *event-count* kinds where a
    /// Min/Ø/Max/Median strip is degenerate: a sparse single occurrence yields
    /// Min == Ø == Max == Median, so the StatsRow reads as noise (the web sub-
    /// pages show no spread strip for count metrics either). The insights metric
    /// page suppresses its StatsRow for these.
    var suppressesAggregateStats: Bool {
        switch self {
        case .falls, .breathingDisturbances, .sleepDisturbanceCount:
            true
        default:
            false
        }
    }

    /// v0.15.2 D1 (#34) — `true` for the *continuous* vitals an Apple Watch can
    /// emit many times within a single clock-minute, so the chronological
    /// measurements feed should collapse a same-minute run into ONE honest row
    /// (value + "·N") instead of N near-identical rows. This is a DISPLAY-ONLY
    /// scoping predicate (no data is dropped) and is intentionally conservative:
    /// only spot heart-rate (`pulse`), respiratory rate, and SpO₂ qualify — the
    /// three discrete-but-high-frequency streams. It deliberately EXCLUDES
    /// per-day rollups (`restingHeartRate` / `walkingHeartRate` / `averageHeartRate`
    /// — one row/day, never clustered), low-frequency manual vitals
    /// (blood-pressure pairs, glucose, weight), and everything cumulative — those
    /// must keep rendering as individual rows. The durable fix is bucketed upload
    /// (server-coordinated, GH #34); this predicate gates only the felt stopgap.
    var isHighFrequencyVital: Bool {
        switch self {
        case .pulse, .respiratoryRate, .spo2:
            true
        default:
            false
        }
    }

    /// **v0.7.0 W-STEPS Layer 3 — series-routing predicate.** `true` for the
    /// kinds whose `recent(kind:)` page should come from the dense per-day
    /// `/api/measurements/series` frame rather than the global limit-400
    /// `/api/measurements` page. This is intentionally *separate* from
    /// `isCumulative` (which controls tile *display* as a same-day sum): a
    /// kind can be display-cumulative without being series-routed and vice
    /// versa. Today only `.steps` qualifies — it is stored server-side as one
    /// `stats:<id>:<day>` row per day, so a HK-power-user's many per-sample
    /// step rows would otherwise blow past the 400-row page in a few weeks,
    /// leaving "Schritte alle Daten" empty. `.sleep` stays on the recent
    /// page because its per-night rows are sparse enough to fit, and the
    /// drill-down expects real per-stage source attribution the series
    /// payload can't carry.
    var prefersSeriesForRecent: Bool {
        switch self {
        case .steps:
            true
        default:
            false
        }
    }

    /// v0.13.1 IC — the server `MeasurementType` key whose all-time `count` in
    /// the `/api/analytics?slice=summaries` slice signals "this kind has data".
    /// This is the per-kind has-data signal the web tab-strip gates its pills on
    /// (`metric-availability.ts:hasMetricData` → `summaries[METRIC].count > 0`),
    /// NOT the last-400 `/api/measurements` recency window — which under-reports
    /// low-frequency kinds (blood-pressure / weight) on a HealthKit power-user
    /// whose recent rows are dominated by steps/energy/HR samples. That window
    /// gap is the operator-reported "BP and pulse just aren't in the Insights
    /// list" bug; gating on the summaries `count` fixes it for ALL mapped kinds
    /// at once.
    ///
    /// Special cases mirroring the web:
    /// - `bloodPressure` → systolic key (BP is two wire rows; the SYS count is
    ///   authoritative for "has BP").
    /// - `bmi` → `WEIGHT` (BMI is derived from weight + profile height; the web
    ///   gates it on the weight count, `hasMetricData("BMI")`).
    ///
    /// `nil` only for kinds the slim slice cannot key (none today — every
    /// charted kind has a server `MeasurementType`). The `availabilityKeyTable`
    /// is the single audit point.
    var availabilitySummaryKey: String? {
        Self.availabilityKeyTable[self]
    }

    /// Static `MetricKind` → server-summaries `MeasurementType` key. A plain
    /// dictionary keeps the lookup O(1) + the contract auditable in one place
    /// (and dodges a 40-arm switch / the cyclomatic-complexity budget). Keys
    /// mirror `measurementTypeEnum` (`src/lib/validations/measurement.ts`) — note
    /// `steps` → `ACTIVITY_STEPS` and `activeEnergy` → `ACTIVE_ENERGY_BURNED`,
    /// which differ from the camelCase domain raw values.
    private static let availabilityKeyTable: [MetricKind: String] = [
        .weight: "WEIGHT",
        .bloodPressure: "BLOOD_PRESSURE_SYS",
        .pulse: "PULSE",
        .glucose: "BLOOD_GLUCOSE",
        .bodyFat: "BODY_FAT",
        .bodyTemperature: "BODY_TEMPERATURE",
        .spo2: "OXYGEN_SATURATION",
        .bodyWater: "TOTAL_BODY_WATER",
        .boneMass: "BONE_MASS",
        .sleep: "SLEEP_DURATION",
        .steps: "ACTIVITY_STEPS",
        .restingHeartRate: "RESTING_HEART_RATE",
        .hrv: "HEART_RATE_VARIABILITY",
        .vo2Max: "VO2_MAX",
        .walkingSpeed: "WALKING_SPEED",
        .walkingAsymmetry: "WALKING_ASYMMETRY",
        .walkingStepLength: "WALKING_STEP_LENGTH",
        // Stored BMI measurements live under BODY_MASS_INDEX (e.g. smart-scale
        // rows via HealthKit). The old "WEIGHT" mapping (BMI-derived-from-weight)
        // fetched weight rows that then decode to `.weight` and were filtered out
        // by the kind guard → the BMI list/detail was always empty even with
        // stored rows. The tile HEADLINE still comes from the server-derived
        // dashboard-summary `comprehensive.bmi`; this key feeds the HISTORY.
        .bmi: "BODY_MASS_INDEX",
        .walkingDoubleSupport: "WALKING_DOUBLE_SUPPORT",
        .walkingSteadiness: "WALKING_STEADINESS",
        .respiratoryRate: "RESPIRATORY_RATE",
        .audioExposureEnvironment: "AUDIO_EXPOSURE_ENV",
        .audioExposureHeadphone: "AUDIO_EXPOSURE_HEADPHONE",
        .activeEnergy: "ACTIVE_ENERGY_BURNED",
        .flightsClimbed: "FLIGHTS_CLIMBED",
        .distanceWalkingRunning: "WALKING_RUNNING_DISTANCE",
        .timeInDaylight: "TIME_IN_DAYLIGHT",
        .fatFreeMass: "FAT_FREE_MASS",
        .leanBodyMass: "LEAN_BODY_MASS",
        .muscleMass: "MUSCLE_MASS",
        .skinTemperature: "SKIN_TEMPERATURE",
        .pulseWaveVelocity: "PULSE_WAVE_VELOCITY",
        .vascularAge: "VASCULAR_AGE",
        .visceralFat: "VISCERAL_FAT",
        .walkingHeartRate: "WALKING_HEART_RATE_AVERAGE",
        .fatMass: "FAT_MASS",
        // v0.13.1 IC — v1.10.0 additive HealthKit signals.
        .falls: "FALL_COUNT",
        .sixMinuteWalk: "SIX_MINUTE_WALK_DISTANCE",
        .stairAscentSpeed: "STAIR_ASCENT_SPEED",
        .stairDescentSpeed: "STAIR_DESCENT_SPEED",
        .breathingDisturbances: "BREATHING_DISTURBANCES",
        .cardioRecovery: "CARDIO_RECOVERY",
        .wristTemperature: "WRIST_TEMPERATURE",
        .averageHeartRate: "AVERAGE_HEART_RATE",
        .maxHeartRate: "MAX_HEART_RATE",
        .sleepDisturbanceCount: "SLEEP_DISTURBANCE_COUNT",
        // v0.14.1 W-B189 — v1.17.1 source-fixed render-only signals (#23).
        .ansCharge: "ANS_CHARGE",
        .cardioLoad: "CARDIO_LOAD",
        .sleepScore: "SLEEP_SCORE",
        .bodyTemperatureDeviation: "BODY_TEMPERATURE_DEVIATION",
        // v0158 — v1.25 clinical measurement types. Keys mirror the server
        // `measurementTypeEnum` SCREAMING_SNAKE form so the availability slice
        // lights their has-data signal.
        .painNRS: "PAIN_NRS",
        .gripStrength: "GRIP_STRENGTH",
        .waistCircumference: "WAIST_CIRCUMFERENCE",
        .waistToHeight: "WAIST_TO_HEIGHT",
        // Build 3 / item 3.3 — the 21 decoder catch-up types. Keys mirror the
        // server `measurementTypeEnum` SCREAMING_SNAKE form so both the
        // availability slice and the kind-scoped `?type=` page work for them.
        .phq9Score: "PHQ9_SCORE",
        .gad7Score: "GAD7_SCORE",
        .who5Score: "WHO5_SCORE",
        .sciScore: "SCI_SCORE",
        .recoveryScore: "RECOVERY_SCORE",
        .stressScore: "STRESS_SCORE",
        .strainScore: "STRAIN_SCORE",
        .hrvRMSSD: "HRV_RMSSD",
        .dayStrain: "DAY_STRAIN",
        .workoutStrain: "WORKOUT_STRAIN",
        .sleepPerformance: "SLEEP_PERFORMANCE",
        .sleepEfficiency: "SLEEP_EFFICIENCY",
        .sleepConsistency: "SLEEP_CONSISTENCY",
        .sleepNeed: "SLEEP_NEED",
        .energyExpenditureKJ: "ENERGY_EXPENDITURE_KJ",
        .resilience: "RESILIENCE",
        .irregularRhythmNotification: "IRREGULAR_RHYTHM_NOTIFICATION",
        .highHeartRateEvent: "HIGH_HEART_RATE_EVENT",
        .lowHeartRateEvent: "LOW_HEART_RATE_EVENT",
        .walkingSteadinessEvent: "WALKING_STEADINESS_EVENT",
        .breathingDisturbanceEvent: "BREATHING_DISTURBANCE_EVENT"
    ]
}
