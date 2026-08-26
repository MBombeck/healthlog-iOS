import Foundation

/// Domain enum for metric types. Server source of truth:
/// `src/app/api/dashboard/summary/route.ts:25-35` +
/// `src/app/api/measurements/series/route.ts:20-31`.
///
/// **v0.4.0 alignment (A4-Audit row 5 + row 20):**
/// - Added `.sleep` / `.steps` cases — server emits tiles for these as
///   soon as the user has SLEEP_DURATION / ACTIVITY_STEPS data. Before
///   this, decoding the dashboard summary threw `dataCorrupted` on
///   unknown enum case and the whole dashboard fell back to skeleton.
/// - Renamed raw values of `.spo2` → `"oxygenSaturation"` and
///   `.bodyWater` → `"totalBodyWater"` to match the server kindEnum.
/// - `.bodyTemperature` stays for HK readbacks (server doesn't have it
///   in its series-kind enum — we never query the series endpoint with
///   it, only use it as a display label for HK-write-through samples).
///
/// **v0.5.2 HK-completeness (F2):** added seven HK-backed kinds so the
/// dashboard surfaces every meaningful sample Apple Health emits today:
/// `restingHeartRate`, `hrv` (SDNN), `vo2Max` are server-backed (Prisma
/// enum has `RESTING_HEART_RATE` / `HEART_RATE_VARIABILITY` / `VO2_MAX`
/// since v1.4.30); `walkingSpeed`, `walkingAsymmetry`, `walkingStepLength`,
/// `bmi` are iOS-local for now — they read off HK directly and post into
/// the per-sample batch path with an HK identifier the server may not yet
/// recognise (server returns `skipped`, anchor still advances). When the
/// server's `MeasurementType`-enum picks these up, the `/api/measurements/
/// series`-endpoint route enables for them too; until then `kindSupportsSeries`
/// stays false for the four iOS-local kinds and the tile renders HK-cached
/// sparkline only.
public enum MetricKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case weight
    case bloodPressure
    case pulse
    case glucose
    case bodyFat
    case bodyTemperature
    case spo2 = "oxygenSaturation"
    case bodyWater = "totalBodyWater"
    case boneMass
    case sleep
    case steps
    /// Resting heart rate (Apple Watch low-activity average). Server enum
    /// `RESTING_HEART_RATE`; raw value matches `seriesKindKey` for
    /// `/api/measurements/series?kind=restingHeartRate` (camelCase per
    /// server zod schema).
    case restingHeartRate
    /// Heart-rate variability — Apple's SDNN (Standard Deviation of NN
    /// intervals, ms). Server enum `HEART_RATE_VARIABILITY`. Raw key
    /// `hrv` keeps the camelCase, but the server-series key is
    /// `heartRateVariability`.
    case hrv = "heartRateVariability"
    /// Cardio fitness — VO₂ max (mL/(kg·min)). Server enum `VO2_MAX`.
    case vo2Max
    /// Walking speed (m/s). **Server-persisted since v1.6.0** (W-WALK) —
    /// Prisma `WALKING_SPEED`, mapped from `HKQuantityTypeIdentifierWalking-
    /// Speed`. Collected via the HK observer + uploaded over the
    /// `hkIdentifier` batch path; the `/api/measurements` list decodes the
    /// `WALKING_SPEED` wire rows back to this kind. The series endpoint still
    /// doesn't list it, so `kindSupportsSeries` stays false and detail reads
    /// off the list page + HK cache.
    case walkingSpeed
    /// Walking asymmetry percentage (%). **Server-persisted since v1.5.5.**
    case walkingAsymmetry = "walkingAsymmetryPercentage"
    /// Average step length (m). **Server-persisted since v1.6.0** (W-WALK) —
    /// Prisma `WALKING_STEP_LENGTH`, mapped from `HKQuantityTypeIdentifier-
    /// WalkingStepLength`. Same list/HK-cache surface semantics as
    /// `walkingSpeed`.
    case walkingStepLength
    /// Body Mass Index (kg/m²). Server-sourced: the comprehensive digest carries
    /// `comprehensive.bmi` + `comprehensive.bmiClassification` (server enum
    /// `BODY_MASS_INDEX`, derived from weight + height). Also readable from HK
    /// directly (Apple Watch + Health-App write it) when no server is paired.
    case bmi = "bodyMassIndex"
    /// Walking double-support percentage (%) — the fraction of each gait
    /// cycle where both feet are on the ground. Apple Health surfaces this
    /// next to walking asymmetry on the Mobility row. Higher values
    /// indicate slower / more stabilising gait (relevant for fall-risk).
    /// **Server-persisted** — Prisma `MeasurementType.WALKING_DOUBLE_SUPPORT`
    /// (`src/lib/validations/measurement.ts`, %). The `/api/measurements` list
    /// decodes the `WALKING_DOUBLE_SUPPORT` wire rows back to this kind
    /// (`MeasurementDTO.toDomain()`). The series endpoint still doesn't list it,
    /// so detail reads off the list page + HK cache.
    case walkingDoubleSupport = "walkingDoubleSupportPercentage"
    /// Walking steadiness (%) — Apple's fall-risk mobility classifier
    /// (`HKQuantityTypeIdentifierAppleWalkingSteadiness`, iOS 15+). A
    /// percentage (0–100) the iPhone derives while carried during walks;
    /// Apple Health surfaces it on the Mobility row next to asymmetry +
    /// double-support. Server enum `WALKING_STEADINESS` exists since
    /// `v1.4.30`; collected via the HK observer + uploaded over the
    /// `hkIdentifier` batch path. The `/api/measurements/series` route
    /// doesn't list it, so `kindSupportsSeries` stays false and detail
    /// reads off the list page + HK cache — same surface semantics as
    /// `walkingDoubleSupport`. Raw value matches the camelCase form the
    /// server-series key would take; the wire `type` maps in
    /// `MeasurementDTO.swift`.
    case walkingSteadiness = "appleWalkingSteadiness"
    /// Respiratory rate (breaths / min). Apple Watch + supported sensors
    /// write this overnight + on demand; Apple Health surfaces it on the
    /// Respiratory row. Reference range lives in `MeasurementRanges`.
    /// **Server-persisted** — Prisma `MeasurementType.RESPIRATORY_RATE`
    /// (`src/lib/validations/measurement.ts`, breaths/min). The
    /// `/api/measurements` list decodes the `RESPIRATORY_RATE` wire rows back to
    /// this kind (`MeasurementDTO.toDomain()`); it is also on the Spezi observer
    /// upload path (mapped server-side since v1.5.5).
    case respiratoryRate
    /// Environmental audio exposure (dBA) — the ambient sound level the
    /// iPhone / Watch microphone measures. Apple Health surfaces this on the
    /// Hearing row alongside the headphone reading. Lower is healthier.
    /// **Server-persisted** — Prisma `MeasurementType.AUDIO_EXPOSURE_ENV`
    /// (`src/lib/validations/measurement.ts`, dBA). The `/api/measurements` list
    /// decodes the `AUDIO_EXPOSURE_ENV` wire rows back to this kind
    /// (`MeasurementDTO.toDomain()`); detail reads off the list page + HK cache.
    case audioExposureEnvironment = "environmentalAudioExposure"
    /// Headphone audio exposure (dBA) — the playback level via connected
    /// headphones. Apple Health pairs it with the environmental reading.
    /// **Server-persisted** — Prisma `MeasurementType.AUDIO_EXPOSURE_HEADPHONE`
    /// (`src/lib/validations/measurement.ts`, dBA). Same list/HK-cache surface
    /// semantics as the environmental sibling.
    case audioExposureHeadphone = "headphoneAudioExposure"
    /// Active energy burned (kcal) — the day's move-ring contribution Apple
    /// Health surfaces on the Activity row. Cumulative per-day aggregate
    /// (`stats:HK_ID:DAY`). Server **persists** the raw rows (Prisma
    /// `ACTIVE_ENERGY_BURNED`), but the `/api/measurements/series` +
    /// `/api/dashboard/summary` routes don't emit it yet — so
    /// `kindSupportsSeries` stays false and the surface reads off the
    /// `/api/measurements` list page + HK-cached sparkline. Raw value is the
    /// HK camelCase identifier; the wire `type` maps in `MeasurementDTO.swift`.
    case activeEnergy = "activeEnergyBurned"
    /// Flights climbed (count) — stairs ascended, Apple Health Activity row.
    /// Cumulative per-day aggregate. Server persists `FLIGHTS_CLIMBED`; same
    /// list/HK-cache surface semantics as `activeEnergy`.
    case flightsClimbed
    /// Walking + running distance (m) — Apple Health Activity row. Cumulative
    /// per-day aggregate. Server persists `WALKING_RUNNING_DISTANCE`; same
    /// list/HK-cache surface semantics as `activeEnergy`.
    case distanceWalkingRunning
    /// Time in daylight (min, iOS 17+) — minutes spent outdoors in daylight
    /// (iPhone 15+/Apple Watch). Cumulative per-day aggregate. Server persists
    /// `TIME_IN_DAYLIGHT`; same list/HK-cache surface semantics as
    /// `activeEnergy`.
    case timeInDaylight

    // MARK: - v0.11 W21 — web-parity body-composition + cardio additions

    //
    // The web app fully supports these eight kinds (dedicated insights
    // sub-pages + server/Withings ingestion + validation, see
    // `src/lib/validations/measurement.ts` + `src/lib/withings/`), but iOS had
    // ZERO of them — a user with a Withings scale / Body-Scan saw them on web
    // and they were invisible in iOS (W21 / AUDIT-FINAL-qol-webparity P1).
    //
    // **Read/display-only parity.** All eight are sourced server-side
    // (Withings sync for the body-composition + arterial metrics; Apple Health
    // server-prep for the HK-native trio). iOS surfaces them through the
    // existing `/api/measurements` read/list → tile → chart-detail path; none
    // get a manual-entry surface (`toCreateDTOs()` returns `[]` for them) and
    // none are added to the iOS HK collection registry — that would risk
    // sample duplication and isn't needed for the parity gap the audit names.
    // Raw values are the camelCase mirror of the server `MeasurementType`
    // enum; the `MeasurementWireDTO.toDomain()` mapping in `MeasurementDTO`
    // decodes the wire rows back to these kinds.

    /// Fat-free mass (kg) — Withings meastype 5 (Body+, Body Cardio/Comp/Scan).
    /// Algorithmically `weight − fat mass`. Server enum `FAT_FREE_MASS`.
    /// **Server/Withings-sourced only** — no Apple Health identifier.
    case fatFreeMass
    /// Lean body mass (kg) — body-composition counterpart to fat mass.
    /// Server enum `LEAN_BODY_MASS` (HealthKit `leanBodyMass` exists, but iOS
    /// receives this server-side; not collected via the HK registry today).
    case leanBodyMass
    /// Muscle mass (kg) — Withings meastype 76 (Body+ family). Server enum
    /// `MUSCLE_MASS`. **Server/Withings-sourced only** — no Apple Health
    /// identifier.
    case muscleMass
    /// Skin temperature (°C) — Withings meastype 73 (ScanWatch dermal reading).
    /// Server enum `SKIN_TEMPERATURE`. DISTINCT from `bodyTemperature` (surface
    /// temps run ~32 °C, core ~37 °C — sharing a bucket would corrupt
    /// analytics). Apple Health has `appleSleepingWristTemperature`, but iOS
    /// receives this server-side; not collected via the HK registry today.
    case skinTemperature
    /// Pulse-wave velocity (m/s) — Withings meastype 91 (Body Cardio/Scan).
    /// Arterial-stiffness indicator. Server enum `PULSE_WAVE_VELOCITY`.
    /// **Server/Withings-sourced only** — no Apple Health identifier.
    case pulseWaveVelocity
    /// Vascular age (years) — Withings meastype 155 (Body Scan). Composite of
    /// PWV + age. Server enum `VASCULAR_AGE`. **Server/Withings-sourced only**
    /// — no Apple Health identifier.
    case vascularAge
    /// Visceral fat (rating 1–12) — Withings meastype 170 (Body Comp/Scan).
    /// Withings' rating scale, not a percent. Server enum `VISCERAL_FAT`.
    /// **Server/Withings-sourced only** — no Apple Health identifier.
    case visceralFat
    /// Walking heart-rate average (bpm) — daily rollup distinct from
    /// `restingHeartRate` (sleep-window minimum) and spot `pulse`. Server enum
    /// `WALKING_HEART_RATE_AVERAGE` (HealthKit `walkingHeartRateAverage`
    /// exists, but iOS receives this server-side; not collected via the HK
    /// registry today).
    case walkingHeartRate = "walkingHeartRateAverage"
    /// Fat mass (kg) — Withings meastype 8 (Body+ family). The mass form of
    /// body-fat (distinct from `bodyFat` which is a percent), pairs with
    /// `fatFreeMass` so the two reconcile to total weight. Server enum
    /// `FAT_MASS`. **Server/Withings-sourced only** — no Apple Health
    /// identifier; not collected via the HK registry (read/display-only).
    case fatMass

    // MARK: - v0.13.1 IC — v1.10.0 web-parity additive HealthKit signals

    //
    // The web app gained dedicated Insights sub-pages for these seven signals
    // in v1.10.0 (`SUB_PAGE_METRIC` + `metric-status-registry`), but iOS had
    // ZERO of them — a user with an Apple Watch saw e.g. cardio-recovery /
    // wrist-temperature on web and they were invisible on iOS Insights.
    //
    // **Read/display-only parity** (same posture as the W21 body-composition
    // additions): all seven are sourced server-side (Apple Health → server
    // ingest, `apple-health-mapping.ts`); none gets a manual-entry surface
    // (`toCreateDTOs()` → `[]`) and none is collected via the iOS HK observer
    // registry today — so adding them is purely Insights display parity. Raw
    // values are the camelCase mirror of the HealthKit identifier; the wire
    // `type` maps in `MeasurementDTO.toDomain()`. A HK read-type would only be
    // needed if/when iOS collects these locally (out of scope here).

    /// Number of hard falls the iPhone/Watch detected (count/day). Apple
    /// surfaces this on the Mobility row. Fewer is better; zero is the target.
    /// Server enum `FALL_COUNT`.
    case falls = "fallCount"
    /// Estimated six-minute-walk-test distance (m) — Apple's passive estimate
    /// of the clinical 6MWT. Server enum `SIX_MINUTE_WALK_DISTANCE`.
    case sixMinuteWalk = "sixMinuteWalkTestDistance"
    /// Stair ascent speed (m/s) — Apple Mobility row. Faster is fitter.
    /// Server enum `STAIR_ASCENT_SPEED`.
    case stairAscentSpeed
    /// Stair descent speed (m/s) — gait companion to ascent speed. Server enum
    /// `STAIR_DESCENT_SPEED`.
    case stairDescentSpeed
    /// Sleep breathing disturbances — Apple's per-night breathing-disturbance
    /// index (count). Joins the sleep cluster. Fewer is better. Server enum
    /// `BREATHING_DISTURBANCES`.
    case breathingDisturbances
    /// Cardio recovery (bpm) — the heart-rate drop one minute after peak
    /// exercise. Higher is fitter. Server enum `CARDIO_RECOVERY`.
    case cardioRecovery
    /// Overnight wrist temperature (°C) — the absolute skin-side reading Apple
    /// records during sleep (distinct from `skinTemperature` / `bodyTemperature`).
    /// Server enum `WRIST_TEMPERATURE`.
    case wristTemperature
    /// Average heart rate (bpm) — WHOOP-native per-day/-session average HR.
    /// Read-only ingest (no client write path). Server enum `AVERAGE_HEART_RATE`
    /// (v1.12.8). Previously dropped by the tolerant list decoder.
    case averageHeartRate
    /// Max heart rate (bpm) — WHOOP-native per-day/-session peak HR. Read-only.
    /// Server enum `MAX_HEART_RATE` (v1.12.8).
    case maxHeartRate
    /// Sleep disturbance count — WHOOP-native count of awakenings/disturbances
    /// per night. Fewer is better. Read-only. Server enum
    /// `SLEEP_DISTURBANCE_COUNT` (v1.12.8). Joins the sleep cluster.
    case sleepDisturbanceCount

    // MARK: - v0.14.1 W-B189 — v1.17.1 source-fixed render-only signals (#23)

    //
    // Four new server-stored `MeasurementType`s landed LIVE in v1.17.1
    // (`/api/version` 1.17.1). All four are SOURCE-FIXED, server-computed and
    // RENDER-ONLY on iOS — there is no manual-entry surface and no HK-write
    // path (`toCreateDTOs()` → `[]`, not in the iOS HK observer registry). iOS
    // just decodes + displays them through the existing list → tile →
    // chart-detail → insights path, exactly like the W21 / IC additive kinds.
    // Raw values are the camelCase mirror of the server `MeasurementType` enum;
    // the wire `type` maps in `MeasurementDTO.toDomain()`.

    /// Autonomic charge — Polar's per-night autonomic-nervous-system load index
    /// (Nightly Recharge ANS charge, a roughly −10…+10 standardised score).
    /// Server enum `ANS_CHARGE` (v1.17.1). Read/display-only.
    case ansCharge
    /// Cardio load — Polar training load (an arbitrary-unit cumulative strain
    /// score). Server enum `CARDIO_LOAD` (v1.17.1). Read/display-only.
    case cardioLoad
    /// Sleep score — a composite 0–100 nightly sleep-quality score (Oura /
    /// Polar / Fitbit emit this server-side). Server enum `SLEEP_SCORE`
    /// (v1.17.1). DISTINCT from `sleep` (time-asleep duration) — never share a
    /// bucket. Read/display-only.
    case sleepScore
    /// Body-temperature DEVIATION (°C) — Oura's SIGNED nightly offset from the
    /// user's personal baseline (e.g. `+0.3` / `−0.2`), NOT an absolute body
    /// temperature. Server enum `BODY_TEMPERATURE_DEVIATION` (v1.17.1). MUST be
    /// rendered with an explicit sign + a "deviation from baseline" label; it
    /// is categorically NOT `bodyTemperature` / `skinTemperature` /
    /// `wristTemperature` (those are absolute ~32–37 °C readings — sharing a
    /// bucket would corrupt analytics and mislead clinically). Read/display-only.
    case bodyTemperatureDeviation

    // MARK: - v0158 — v1.25 clinical measurement types

    //
    // Four net-new server `MeasurementType`s landed in v1.25
    // (`src/lib/validations/measurement.ts` + `src/lib/signals/registry.ts`).
    // Unlike the W21 / IC / W-B189 read-only additions, three of these are
    // MANUAL clinical signals the user logs by hand (`toCreateDTOs()` emits a
    // wire row + the MeasureSheet exposes a capture input); waist-to-height is
    // render-only for v1. None is HealthKit-backed on iOS today (pain + grip
    // have no native HK type; waist HK round-trip is blocked on a server
    // `apple-health-mapping.ts` entry). Raw values are the camelCase mirror of
    // the server enum; the wire `type` maps in `MeasurementDTO.toDomain()`.

    /// Pain — 0–10 integer NRS (Numeric Rating Scale). Server enum `PAIN_NRS`
    /// (LOINC 72514-3, unit `score`), lower-is-better. **Manual-only** (no
    /// HealthKit type). Captured via a bespoke 0–10 integer picker in the
    /// MeasureSheet — NEVER the decimal text field (the server accepts any 0–10
    /// float, so the integer constraint is a client responsibility).
    case painNRS
    /// Grip strength (kg). Server enum `GRIP_STRENGTH` (0–120), higher-is-better.
    /// **Manual-only** — HealthKit has no grip-strength quantity type. Captured
    /// via the standard kg decimal field.
    case gripStrength
    /// Waist circumference (cm). Server enum `WAIST_CIRCUMFERENCE` (LOINC 8280-0,
    /// 30–250), lower-is-better. **Manual-only for now.** HealthKit has
    /// `HKQuantityTypeIdentifier.waistCircumference`, but the server
    /// `apple-health-mapping.ts` has no waist entry, so an HK-batch upload would
    /// be dropped server-side — HK round-trip is deferred until the server adds
    /// the mapping (see server coord). Captured via the standard cm decimal field.
    case waistCircumference
    /// Waist-to-height ratio (dimensionless, 0.2–1.5). Server enum
    /// `WAIST_TO_HEIGHT`, lower-is-better. **Render-only on iOS for v1.** The
    /// server stores it first-class, but there is no LOINC + no iOS
    /// height-in-capture source, so iOS DECODES + DISPLAYS it (tile / chart if it
    /// arrives) but has NO manual-entry path (`toCreateDTOs()` → `[]`, absent
    /// from the MeasureSheet picker). Manual / derived entry is deferred until a
    /// height source is decided.
    case waistToHeight

    // MARK: - v0.14.1 Build 3 / item 3.3 — the 23 wire types the list decoder dropped

    //
    // Parity audit `05-measurements-labs.md` A2 counted 23 server
    // `MeasurementType`s with no `ServerMeasurementType` pendant; a
    // set-difference of the LIVE `prisma/schema.prisma` `enum MeasurementType`
    // against the iOS enum confirmed EXACTLY those 23 (no more, no fewer, and
    // no iOS-only case that the server does not know). Two of them already had
    // a domain kind — `ACTIVITY_STEPS` → `.steps` and `BODY_MASS_INDEX` →
    // `.bmi` — so only 21 NEW `MetricKind` cases are needed here.
    //
    // The steps case is the one that hurt: the server has stored
    // `ACTIVITY_STEPS` rows all along and the tolerant list decoder threw EVERY
    // one of them away, so the drill-down leaned on a `/series` workaround that
    // stamps a blanket `.appleHealth` source on synthesized rows.
    //
    // **Read/display-only, all 21.** None gets a manual-create arm
    // (`toCreateDTOs()` → `[]`) and none is added to the HK collection
    // registry: they are either server-COMPUTED (the four screener sums),
    // wearable-native ingest (WHOOP / Oura / Polar), or Apple-Health CATEGORY
    // events the app does not author. Build 1 removed nine kinds from the
    // MeasureSheet picker that could never serialize; none of these 21 re-opens
    // one, so the picker is untouched.
    //
    // Units mirror the server `getUnitForType` map
    // (`src/lib/validations/measurement.ts` L264-L396); raw values are the
    // camelCase mirror of the wire token.

    /// PHQ-9 depression-screener SUM score (0–27). Server enum `PHQ9_SCORE`,
    /// unit `score`. Since server v1.27.6 (migration 0225) these rows carry
    /// `source = COMPUTED` — the server derives the sum from the stored
    /// item responses, so the row is READ-ONLY on every surface.
    case phq9Score
    /// GAD-7 anxiety-screener SUM score (0–21). Server enum `GAD7_SCORE`,
    /// `source = COMPUTED`. Read-only, same contract as ``phq9Score``.
    case gad7Score
    /// WHO-5 well-being index (0–25 raw sum). Server enum `WHO5_SCORE`,
    /// `source = COMPUTED`. Read-only. HIGHER is better here — the only
    /// screener of the four whose polarity is inverted.
    case who5Score
    /// SCI (Sleep Condition Indicator) score (0–32). Server enum `SCI_SCORE`,
    /// `source = COMPUTED`. Read-only. Higher is better.
    case sciScore
    /// WHOOP/Oura recovery score (0–100). Server enum `RECOVERY_SCORE`.
    case recoveryScore
    /// Stress score (0–100). Server enum `STRESS_SCORE`. Lower is better.
    case stressScore
    /// Normalised strain score (0–100). Server enum `STRAIN_SCORE` — the
    /// COMPUTED 0–100 normalisation, DELIBERATELY distinct from WHOOP's native
    /// 0–21 ``dayStrain``. Collapsing the two would put a 0–21 reading on a
    /// 0–100 axis; the server keeps them apart and so does iOS.
    case strainScore
    /// Heart-rate variability as RMSSD (ms). Server enum `HRV_RMSSD`.
    /// **NOT** `.hrv` — that case is Apple's SDNN. RMSSD and SDNN are different
    /// statistics over the same NN-interval series and typically differ by tens
    /// of milliseconds, so sharing a bucket would corrupt the trend (same
    /// doctrine as `bodyTemperatureDeviation` vs `bodyTemperature`).
    case hrvRMSSD
    /// WHOOP native day strain (0–21). Server enum `DAY_STRAIN`.
    case dayStrain
    /// WHOOP native per-workout strain (0–21). Server enum `WORKOUT_STRAIN`.
    case workoutStrain
    /// Sleep performance (% of sleep need met). Server enum `SLEEP_PERFORMANCE`.
    case sleepPerformance
    /// Sleep efficiency (% of time in bed actually asleep). Server enum
    /// `SLEEP_EFFICIENCY`.
    case sleepEfficiency
    /// Sleep consistency (% — bed/wake-time regularity). Server enum
    /// `SLEEP_CONSISTENCY`.
    case sleepConsistency
    /// Sleep need (MINUTES). Server enum `SLEEP_NEED`, unit `minutes` (0–1440).
    /// Kept in minutes — unlike `SLEEP_DURATION`, whose list rows are converted
    /// to hours because `MetricKind.sleep` declares `"h"`. This kind declares
    /// `"min"`, so the wire value is a straight passthrough.
    case sleepNeed
    /// Energy expenditure in KILOJOULES. Server enum `ENERGY_EXPENDITURE_KJ`.
    /// Distinct from `.activeEnergy` (kcal) — a 1:4.184 unit difference that
    /// would read as a 4× jump if the two shared a kind.
    case energyExpenditureKJ
    /// Oura resilience LEVEL (1–5 ordinal, not a continuous score). Server enum
    /// `RESILIENCE`, unit `level` — the level ordinal is encoded in the numeric
    /// value (`RESILIENCE_LEVELS`, `src/lib/oura/client`).
    case resilience
    /// Apple Health irregular-rhythm notification. Server enum
    /// `IRREGULAR_RHYTHM_NOTIFICATION`, unit `event`, band `1…1` — a CATEGORICAL
    /// occurrence, so the value is always `1` and the information is the
    /// timestamp, not the magnitude.
    case irregularRhythmNotification
    /// Apple Health high-heart-rate event. Server enum `HIGH_HEART_RATE_EVENT`,
    /// categorical (`1…1`).
    case highHeartRateEvent
    /// Apple Health low-heart-rate event. Server enum `LOW_HEART_RATE_EVENT`,
    /// categorical (`1…1`).
    case lowHeartRateEvent
    /// Apple Health walking-steadiness EVENT (the notification), distinct from
    /// the `.walkingSteadiness` PERCENTAGE. Server enum
    /// `WALKING_STEADINESS_EVENT`, categorical (`1…1`).
    case walkingSteadinessEvent
    /// Breathing-disturbance EVENT, distinct from the `.breathingDisturbances`
    /// COUNT. Server enum `BREATHING_DISTURBANCE_EVENT`, categorical (`1…1`).
    case breathingDisturbanceEvent

    // MARK: - Build 7 / item 7.3 — mood dashboard tile

    //
    // The `/api/dashboard/summary` route emits a `kind: "mood"` tile since server
    // v1.31.0 (#51). Mood is the ONE dashboard metric that is NOT a `Measurement`
    // — the server derives it from the canonical `buildMoodDailySeries` output
    // (the same daily series the web mood analytics reads), emitted only when the
    // account has ever logged a mood (`entryCount > 0`). It therefore has NO
    // server `MeasurementType` / `ServerMeasurementType` pendant, no wire→domain
    // decode arm, and no manual-create arm (`toCreateDTOs()` falls through to
    // `[]`): mood is logged through its own State-of-Mind / `log_mood` path, and
    // this case exists purely so the summary tile decodes + renders (the tolerant
    // `DashboardMetric.SkipUnknown` used to drop it). The `bmi` sibling already
    // had a case (`"bodyMassIndex"`) but the summary sends the short `"bmi"`
    // token — that alias is bridged in `DashboardMetric.init(from:)`.
    case mood

    public var id: String {
        rawValue
    }

    /// Build 3 / item 3.3 — the five CATEGORICAL Apple-Health events whose
    /// server band is `1…1`: the value carries no information, only the
    /// occurrence and its timestamp do. Surfaces that would otherwise print a
    /// meaningless "1" use this to render an occurrence label instead.
    public var isCategoricalEvent: Bool {
        switch self {
        case .irregularRhythmNotification, .highHeartRateEvent, .lowHeartRateEvent,
             .walkingSteadinessEvent, .breathingDisturbanceEvent:
            true
        default:
            false
        }
    }

    public var unit: String {
        switch self {
        case .weight: "kg"
        case .bloodPressure: "mmHg"
        case .pulse: "bpm"
        case .glucose: "mg/dL"
        case .bodyFat: "%"
        case .bodyTemperature: "°C"
        case .spo2: "%"
        case .bodyWater: "kg"
        case .boneMass: "kg"
        case .sleep: "h"
        case .steps: ""
        case .restingHeartRate: "bpm"
        case .hrv: "ms"
        case .vo2Max: "mL/kg·min"
        case .walkingSpeed: "m/s"
        case .walkingAsymmetry: "%"
        case .walkingStepLength: "m"
        case .bmi: "kg/m²"
        case .walkingDoubleSupport: "%"
        case .walkingSteadiness: "%"
        case .respiratoryRate: "br/min"
        case .audioExposureEnvironment, .audioExposureHeadphone: "dBA"
        case .activeEnergy: "kcal"
        case .flightsClimbed: ""
        case .distanceWalkingRunning: "m"
        case .timeInDaylight: "min"
        // v0.11 W21 — web-parity additions.
        case .fatFreeMass, .leanBodyMass, .muscleMass, .fatMass: "kg"
        case .skinTemperature: "°C"
        case .pulseWaveVelocity: "m/s"
        case .vascularAge: "years"
        case .visceralFat: ""
        case .walkingHeartRate: "bpm"
        // v0.13.1 IC — v1.10.0 additive signals (units mirror the server
        // `measurementTypeEnum` unit map + the metric-status registry).
        case .falls: ""
        case .sixMinuteWalk: "m"
        case .stairAscentSpeed, .stairDescentSpeed: "m/s"
        case .breathingDisturbances: ""
        case .cardioRecovery: "bpm"
        case .wristTemperature: "°C"
        // v0.14.6 — v1.12.8 WHOOP-native types (read-only display parity).
        case .averageHeartRate, .maxHeartRate: "bpm"
        case .sleepDisturbanceCount: ""
        // v0.14.1 W-B189 — v1.17.1 source-fixed render-only signals (#23).
        // ANS-charge / cardio-load / sleep-score are unitless scores; the
        // body-temperature DEVIATION carries °C but is a SIGNED offset (see
        // `MetricKindDescriptor.FormatStyle.signedDecimal1`).
        case .ansCharge, .cardioLoad, .sleepScore: ""
        case .bodyTemperatureDeviation: "°C"
        // v0158 — v1.25 clinical types. Pain NRS + waist-to-height ratio are
        // dimensionless (no unit suffix); grip is kg, waist is cm.
        case .painNRS, .waistToHeight: ""
        case .gripStrength: "kg"
        case .waistCircumference: "cm"
        // Build 3 / item 3.3 — units mirror the server `getUnitForType` map.
        // The four screener sums, the recovery/stress/strain scores and the two
        // WHOOP strain readings are unitless `score` values; the five
        // categorical events carry `event` (band `1…1`) and render as an
        // occurrence, so an empty unit is the honest label.
        case .phq9Score, .gad7Score, .who5Score, .sciScore,
             .recoveryScore, .stressScore, .strainScore,
             .dayStrain, .workoutStrain, .resilience,
             .irregularRhythmNotification, .highHeartRateEvent, .lowHeartRateEvent,
             .walkingSteadinessEvent, .breathingDisturbanceEvent: ""
        case .hrvRMSSD: "ms"
        case .sleepPerformance, .sleepEfficiency, .sleepConsistency: "%"
        case .sleepNeed: "min"
        case .energyExpenditureKJ: "kJ"
        // Build 7 / item 7.3 — mood is a unitless daily score; the summary tile
        // reads its label from the server `unitKey` anyway (empty here).
        case .mood: ""
        }
    }

    /// Localised display title. Resolves through `MetricKindDescriptor`'s
    /// `LocalizedStringResource` catalogue so EN-locale users get English
    /// titles ("Weight" / "Blood pressure") instead of the German source
    /// strings. The descriptor entries are the single source of truth for
    /// both DE (source) and EN (translation) — see
    /// `HealthLog/Resources/Localizable.xcstrings`.
    ///
    /// **v0.7.0 / W-LOC-CRITICAL C-1:** prior versions hard-coded the
    /// German strings here, which surfaced "Gewicht" / "Blutdruck" /
    /// "Schlaf" as nav-titles + chart axes on every EN locale. App-Store
    /// EN review would have flagged this; the descriptor route fixes
    /// every ~46 call-site in one hop.
    public var displayName: String {
        String(localized: descriptor.title)
    }
}

/// Tolerant-decoding wrapper used at array-decode sites so a single
/// unknown enum case from the server doesn't reject the whole list
/// (PROJECT_GUIDE.md anti-pattern: "Silent error swallowing — entweder
/// behandeln oder bewusst durchwerfen mit Kontext"). Here we choose
/// "log + continue" — the array survives.
///
/// Use at every decode site that takes a `[MetricKind]`-shaped array
/// of dashboard tiles, sync entries etc. — pre-v0.4.0 the dashboard
/// summary failed wholesale on a single new kind from the server
/// (A4-Audit row 5).
public struct TolerantMetricKind: Decodable, Sendable {
    public let value: MetricKind?

    public init(value: MetricKind?) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if let kind = MetricKind(rawValue: raw) {
            value = kind
        } else {
            HLLog.api.warning("Unknown MetricKind raw value: \(raw, privacy: .public) — dropping from array.")
            value = nil
        }
    }
}

/// Domain-Type für eine Messung. Wert-Container ist enum-basiert, damit BP zwei Werte tragen kann.
///
/// **BP pair-id note:** the server stores Blutdruck als ZWEI Wire-Rows
/// (`BLOOD_PRESSURE_SYS` + `BLOOD_PRESSURE_DIA`) mit geteiltem `externalId`.
/// `MeasurementAggregator.mergeBloodPressure` merged sie zu einem Domain-
/// Measurement, dessen `id` die systolische Wire-ID ist. Die diastolische
/// Peer-ID landet in `bloodPressureDiastolicId`, damit Edit-Pfade beide
/// Server-Rows aktualisieren können (T-1 BP-DIA paired patch).
public struct Measurement: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let kind: MetricKind
    public let recordedAt: Date
    public let value: MeasurementValue
    public let note: String?
    public let source: MeasurementSource
    public let externalUUID: String?
    /// Server-side `BLOOD_PRESSURE_DIA` row id, only set when `kind ==
    /// .bloodPressure` and the merge had both halves on hand. `nil` for
    /// scalar measurements und für BP-Halbpaare die solo aus dem Server
    /// kamen (Aggregator-Fallback). Edit-Pfade fanout PATCH auf beide
    /// Peers nur wenn dieser Wert gesetzt ist — sonst greift der
    /// historische Single-PATCH-Pfad (systolic only).
    public let bloodPressureDiastolicId: String?
    /// Discriminator-Context für Blutzucker-Messungen. Nur belegt wenn
    /// `kind == .glucose` und der Server-Record (oder die User-Eingabe)
    /// einen Context gesetzt hat. Erlaubt Series-Charts + Alerts pro
    /// Context zu gruppieren (T-2, AC10 finding). Für alle anderen Kinds
    /// `nil`. Wire-Key: `glucoseContext` (Server-Schema
    /// `src/lib/validations/measurement.ts`).
    ///
    /// **CU-18 / Server-Migration 0274:** auch auf `kind == .glucose` ist
    /// `nil` ein regulärer Zustand — kein Lesepfad darf einen Kontext
    /// annehmen oder defaulten. Ebenso, wenn der Server ein iOS unbekanntes
    /// Literal schickt: `MeasurementWireDTO` mappt es auf `nil` statt zu
    /// werfen, die Zeile bleibt erhalten und wird ohne Kontext-Label
    /// gerendert.
    public let glucoseContext: GlucoseContext?

    public init(
        id: String,
        kind: MetricKind,
        recordedAt: Date,
        value: MeasurementValue,
        note: String? = nil,
        source: MeasurementSource = .manual,
        externalUUID: String? = nil,
        bloodPressureDiastolicId: String? = nil,
        glucoseContext: GlucoseContext? = nil
    ) {
        self.id = id
        self.kind = kind
        self.recordedAt = recordedAt
        self.value = value
        self.note = note
        self.source = source
        self.externalUUID = externalUUID
        self.bloodPressureDiastolicId = bloodPressureDiastolicId
        self.glucoseContext = glucoseContext
    }

    /// **v1.27.6 (#42) / v1.28.11 (#46) — server-owned rows are read-only.** A
    /// `COMPUTED` measurement (e.g. a PHQ-9 / GAD-7 screening sum score,
    /// re-attributed from `MANUAL` by server migration 0225) is derived
    /// server-side; the provider-ingest sources `STRAVA` / `OURA` / `POLAR` /
    /// `NIGHTSCOUT` are wearable/CGM rows the server owns and never accepts on a
    /// client write path (not in `WRITABLE_MEASUREMENT_SOURCES`). For all of
    /// these, hand-editing or deleting the value is meaningless / would be
    /// rejected, so the list surface gates its Edit/Delete affordances off when
    /// this is `true` — the row renders but never offers a value-edit path.
    ///
    /// Exhaustive over `MeasurementSource` on purpose: adding a source forces a
    /// decision here (compiler-enforced), so a new read-only ingest can't slip
    /// through as accidentally editable. `whoop` / `fitbit` / `googleHealth` stay
    /// in the editable column to preserve their pre-#46 behaviour.
    var isServerDerivedReadOnly: Bool {
        switch source {
        case .computed, .strava, .oura, .polar, .nightscout: true
        case .manual, .appleHealth, .withings, .whoop, .fitbit, .googleHealth, .import_: false
        }
    }
}

public enum MeasurementValue: Codable, Sendable, Hashable {
    case scalar(Double)
    case bloodPressure(systolic: Double, diastolic: Double)

    private enum CodingKeys: String, CodingKey {
        case scalar
        case systolic
        case diastolic
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try container.decodeIfPresent(Double.self, forKey: .systolic),
           let d = try container.decodeIfPresent(Double.self, forKey: .diastolic)
        {
            self = .bloodPressure(systolic: s, diastolic: d)
        } else if let scalar = try container.decodeIfPresent(Double.self, forKey: .scalar) {
            self = .scalar(scalar)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .scalar,
                in: container,
                debugDescription: "MeasurementValue must encode either scalar or systolic+diastolic"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .scalar(v):
            try container.encode(v, forKey: .scalar)
        case let .bloodPressure(s, d):
            try container.encode(s, forKey: .systolic)
            try container.encode(d, forKey: .diastolic)
        }
    }
}

public extension MeasurementValue {
    /// Primary scalar component used for PATCH payloads. For BP returns
    /// systolic; the diastolic peer is updated server-side via the BP-pair
    /// linkage on `externalId`.
    var primaryComponent: Double {
        switch self {
        case let .scalar(v): v
        case let .bloodPressure(s, _): s
        }
    }
}

public enum MeasurementSource: String, Codable, Sendable {
    case manual
    /// Server-Wire-Form: `APPLE_HEALTH`. Domain-Enum behält camelCase, das Coding-
    /// Mapping zu/von Wire findet in `MeasurementDTO.swift` statt.
    case appleHealth
    case withings
    /// Server-Wire-Form: `WHOOP`. Server-owned read-only ingest (recovery/strain/
    /// sleep/HR via BYO-key OAuth). Kein Client-Write-Pfad.
    case whoop
    /// Server-Wire-Form: `FITBIT` (Google-Health-/Fitbit-Provider, v1.12.0).
    /// Server-owned read-only ingest — wie WHOOP/Withings, kein Client-Write-Pfad.
    case fitbit
    /// Server-Wire-Form: `GOOGLE_HEALTH` (Google-Health-API-Provider, Server
    /// v1.27.0). Server-owned read-only ingest — wie WHOOP/Fitbit, kein
    /// Client-Write-Pfad.
    case googleHealth
    /// Server-Wire-Form: `COMPUTED` — server-derived rows (Read-Enum seit v1.10).
    /// Seit Server v1.27.6 tragen Screening-Summenscores (PHQ-9 / GAD-7 / WHO-5)
    /// diese Source statt `MANUAL` (Re-Attribution als Migration 0225).
    /// **Server-derived, read-only:** ein abgeleiteter Score darf NIE einen
    /// Value-Edit/Delete-Pfad anbieten — bearbeiten wäre bedeutungslos (siehe
    /// ``Measurement/isServerDerivedReadOnly``). Ohne diesen Case droppt der
    /// tolerante List-Decoder jede COMPUTED-Zeile still (gleiche Failure-Mode wie
    /// GOOGLE_HEALTH, #40) → die Zeilen verschwinden aus der Liste.
    case computed
    /// Server-Wire-Form: `STRAVA` (Server v1.28.11, iOS #46). Server-owned
    /// read-only Workout-/Aktivitäts-Ingest — kein Client-Write-Pfad (nicht in
    /// `WRITABLE_MEASUREMENT_SOURCES`). Edit/Delete-Affordances sind gated
    /// (siehe ``Measurement/isServerDerivedReadOnly``).
    case strava
    /// Server-Wire-Form: `OURA`. Die App shippt bereits eine Oura-Integration
    /// (`ouraIntegrationStore`). Server-owned read-only ingest — kein
    /// Client-Write-Pfad.
    case oura
    /// Server-Wire-Form: `POLAR`. Die App shippt bereits eine Polar-Integration
    /// (`polarIntegrationStore`). Server-owned read-only ingest — kein
    /// Client-Write-Pfad.
    case polar
    /// Server-Wire-Form: `NIGHTSCOUT`. Die App shippt bereits eine Nightscout-
    /// Integration (`nightscoutIntegrationStore`). Server-owned read-only ingest
    /// (CGM-Glukose) — kein Client-Write-Pfad.
    case nightscout
    case import_ = "import"
}

/// List-Endpoint-Wrapper. Server liefert `{ measurements: [...], meta: {...} }`.
public struct MeasurementListResponse: Codable, Sendable {
    public let measurements: [Measurement]
    public let meta: ListMeta?

    public struct ListMeta: Codable, Sendable {
        public let total: Int?
        public let limit: Int?
        public let offset: Int?
    }
}

/// Series-Endpoint Antwort.
///
/// **W-B187 (#29) — server unit-at-source.** Since server v1.16.16 the
/// `GET /api/measurements/series` payload carries an explicit `unit` token
/// (e.g. glucose `"mg/dL"` | `"mmol/L"`, per the user's preference) and the
/// `points[].value` + `stats` are ALREADY CONVERTED to that unit server-side —
/// iOS must NOT re-convert (no client `convertGlucose` runs on series points;
/// re-converting would be the 18× double-convert hazard). Read `unit` from the
/// payload and use it as the display label; never assume mg/dL. The field is
/// decoded leniently (`decodeIfPresent`) so an older server that omits it keeps
/// today's behaviour (the per-`MetricKind` hardcoded unit). Resolve the display
/// label through ``resolvedUnit(for:)`` so the consumer never hardcodes.
public struct MeasurementSeries: Codable, Sendable {
    public let kind: MetricKind
    public let points: [SeriesPoint]
    public let stats: SeriesStats
    /// W-B187 (#29) — the server-resolved display unit for this series (v1.16.16
    /// unit-at-source). `nil` on an older server / a kind the server doesn't
    /// unit-stamp → the consumer falls back to the per-`MetricKind` default.
    public let unit: String?

    public init(kind: MetricKind, points: [SeriesPoint], stats: SeriesStats, unit: String? = nil) {
        self.kind = kind
        self.points = points
        self.stats = stats
        self.unit = unit
    }

    private enum CodingKeys: String, CodingKey {
        case kind, points, stats, unit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(MetricKind.self, forKey: .kind)
        points = try c.decode([SeriesPoint].self, forKey: .points)
        stats = try c.decode(SeriesStats.self, forKey: .stats)
        // Tolerant: absent OR JSON `null` both decode to `nil` (older server).
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
    }

    /// The display unit label for this series — the server-resolved `unit`
    /// (v1.16.16 unit-at-source) when present, else the per-`MetricKind`
    /// hardcoded default. HONEST-ONLY: the server value is authoritative and is
    /// rendered as-is; iOS never re-converts the pre-converted `points`/`stats`.
    public func resolvedUnit(for kind: MetricKind) -> String {
        if let unit, !unit.isEmpty { return unit }
        return kind.unit
    }
}

public struct SeriesPoint: Codable, Sendable, Identifiable {
    public let id: String
    public let at: Date
    public let value: Double
    public let secondary: Double? // diastolic for BP
}

public struct SeriesStats: Codable, Sendable {
    public let mean: Double
    public let min: Double
    public let max: Double
    public let stdDev: Double
    public let count: Int
}

/// Effective range für Threshold-Checks. Spiegelt Server-Logik aus `src/lib/analytics/effective-range.ts`.
public struct EffectiveRange: Codable, Sendable {
    public let kind: MetricKind
    public let warnLow: Double?
    public let warnHigh: Double?
    public let criticalLow: Double?
    public let criticalHigh: Double?
}

public extension Measurement {
    /// Convenience: scalar-Wert oder für BP der systolische.
    var primaryValue: Double {
        switch value {
        case let .scalar(v): v
        case let .bloodPressure(s, _): s
        }
    }

    /// Severity nach Effective Range. `.ok` wenn keine Bereiche bekannt.
    func severity(against range: EffectiveRange?) -> Severity {
        guard let range else { return .ok }
        let v = primaryValue
        if let lo = range.criticalLow, v < lo { return .critical }
        if let hi = range.criticalHigh, v > hi { return .critical }
        if let lo = range.warnLow, v < lo { return .warning }
        if let hi = range.warnHigh, v > hi { return .warning }
        return .ok
    }
}

public enum Severity: String, Codable, Sendable {
    case ok
    case warning
    case critical
}
