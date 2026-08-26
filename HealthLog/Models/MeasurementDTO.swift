import Foundation

/// Wire-Format des Servers (Prisma). MUSS bit-genau zum Server-Schema passen,
/// siehe `src/lib/validations/measurement.ts`.
public struct MeasurementWireDTO: Codable, Sendable, Identifiable {
    public let id: String
    public let userId: String?
    public let type: ServerMeasurementType
    public let value: Double
    /// **v0.14 — explicit canonical unit token from the server (`MeasurementResource.unit`,
    /// `openapi.yaml`).** The server states the row's unit explicitly so the client never
    /// has to guess. For `SLEEP_DURATION` on the `/api/measurements` LIST path the server
    /// emits the per-NIGHT time-asleep total in `unit: "minutes"` (`getUnitForType`
    /// → `unitMap["SLEEP_DURATION"] == "minutes"`); `toDomain()` converts to the app's
    /// hours display ONLY when the unit is minutes — no hardcoded ×60 guard. Optional so
    /// older fixtures / write-paths that don't carry a unit still decode.
    public let unit: String?
    public let measuredAt: Date
    public let notes: String?
    public let source: ServerMeasurementSource?
    /// **CU-18 / Server-Migration 0274 — nullbar AUCH auf `BLOOD_GLUCOSE`.**
    /// Der Kontext war schon immer `Optional`, aber bis Migration 0274 trug
    /// jede Glukose-Zeile garantiert einen der vier Werte. Seit 0274 darf er
    /// auf einer `BLOOD_GLUCOSE`-Zeile schlicht `null` sein — kein Lesepfad
    /// darf daraus einen Default erfinden (siehe `toDomain()`; die UI zeigt
    /// dann "Kein Kontext", nicht "Nüchtern").
    ///
    /// **Asymmetrie:** `POST /api/measurements` (Einzelanlage) verlangt den
    /// Kontext weiterhin — der Schreibpfad (`MeasurementCreateDTO`) bleibt
    /// unverändert.
    public let glucoseContext: GlucoseContext?
    public let externalId: String?
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(
        id: String,
        userId: String? = nil,
        type: ServerMeasurementType,
        value: Double,
        unit: String? = nil,
        measuredAt: Date,
        notes: String? = nil,
        source: ServerMeasurementSource? = nil,
        glucoseContext: GlucoseContext? = nil,
        externalId: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.userId = userId
        self.type = type
        self.value = value
        self.unit = unit
        self.measuredAt = measuredAt
        self.notes = notes
        self.source = source
        self.glucoseContext = glucoseContext
        self.externalId = externalId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, userId, type, value, unit, measuredAt, notes, source
        case glucoseContext, externalId, createdAt, updatedAt
    }

    /// **CU-18 — tolerant `glucoseContext`-Decode.** `GlucoseContext` ist ein
    /// geschlossenes Vier-Fall-Enum ohne Unbekannt-Fall (bewusst: es speist die
    /// Picker über `CaseIterable`, ein Sammelfall würde dort als Auswahl
    /// auftauchen). Ein neues Server-Literal warf deshalb MITTEN im
    /// `MeasurementWireDTO`-Decode: auf der Listenroute fing
    /// `TolerantMeasurementWire` das ab und verwarf die ganze Zeile, jeder
    /// Einzel-Measurement-Decode (`POST`/`PATCH`-Response, `GET …/{id}`) fiel
    /// hart als `HLError.decoding` um.
    ///
    /// Der Decoder liest das Feld daher als rohen String und mappt es
    /// nachgelagert: unbekanntes Literal → `nil` + Log-Warnung, **die Zeile
    /// überlebt vollständig**. Wir erfinden keinen Kontext — lieber gar kein
    /// Label als ein falsches. Alle übrigen Felder behalten exakt das
    /// synthetisierte Verhalten (unbekannter `type`/`source` wirft weiterhin,
    /// dafür existiert der Listen-Tolerant-Wrapper).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        userId = try c.decodeIfPresent(String.self, forKey: .userId)
        type = try c.decode(ServerMeasurementType.self, forKey: .type)
        value = try c.decode(Double.self, forKey: .value)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        measuredAt = try c.decode(Date.self, forKey: .measuredAt)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        source = try c.decodeIfPresent(ServerMeasurementSource.self, forKey: .source)
        glucoseContext = Self.decodeGlucoseContext(from: c)
        externalId = try c.decodeIfPresent(String.self, forKey: .externalId)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    /// Reads `glucoseContext` as a raw string and maps it onto the closed enum.
    /// `null` / absent / unknown literal → `nil`, never a throw.
    private static func decodeGlucoseContext(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> GlucoseContext? {
        // `try?` flacht `String??` auf `String?` ab: sowohl ein Wurf (Feld ist
        // kein String) als auch `null`/Abwesenheit landen hier auf `nil`.
        guard let literal = try? container.decodeIfPresent(String.self, forKey: .glucoseContext) else {
            return nil
        }
        if let context = GlucoseContext(rawValue: literal) { return context }
        HLLog.api.warning(
            "Unknown glucoseContext literal \(literal, privacy: .public) — row kept, context dropped"
        )
        return nil
    }
}

public enum ServerMeasurementType: String, Codable, Sendable, CaseIterable {
    case weight = "WEIGHT"
    case bloodPressureSystolic = "BLOOD_PRESSURE_SYS"
    case bloodPressureDiastolic = "BLOOD_PRESSURE_DIA"
    case bloodGlucose = "BLOOD_GLUCOSE"
    case pulse = "PULSE"
    case oxygenSaturation = "OXYGEN_SATURATION"
    case bodyFat = "BODY_FAT"
    case bodyTemperature = "BODY_TEMPERATURE"
    case totalBodyWater = "TOTAL_BODY_WATER"
    case boneMass = "BONE_MASS"
    /// Mobility-Risk-Indikator (HKQuantityTypeIdentifierAppleWalkingSteadiness).
    /// **Per-sample** wire row (R10 confirmed — kein cumulative, separate
    /// HK-STATS scope). Server-Enum-Add seit `v1.4.30`. iOS hat heute keine
    /// Tile / kein Chart-Surface dafür; der enum-Wert dient primär dem
    /// Categorisation-Overlay (`activity`-Bucket) + dem HK-Permission-Picker.
    case walkingSteadiness = "WALKING_STEADINESS"
    /// Audio-Exposure-Event (HKCategoryTypeIdentifierAudioExposureEvent).
    /// **Per-sample** wire row (R10 confirmed). Server-Enum-Add seit
    /// `v1.4.30`. Wie WALKING_STEADINESS heute ohne iOS-Surface; trägt nur
    /// die Picker-Gruppe `hearing` mit.
    case audioExposureEvent = "AUDIO_EXPOSURE_EVENT"
    /// Resting heart rate. Server-Enum seit v1.4.30 (`cardiovascular`-Bucket).
    /// Per-sample row — `HKAnchoredObjectQuery` liefert sie hourly.
    case restingHeartRate = "RESTING_HEART_RATE"
    /// Heart-rate variability (Apple SDNN). Server-Enum seit v1.4.30
    /// (`cardiovascular`-Bucket). Per-sample row.
    case heartRateVariability = "HEART_RATE_VARIABILITY"
    /// Cardio Fitness (VO₂ max). Server-Enum seit v1.4.30
    /// (`activity`-Bucket). Per-sample row — HK aktualisiert den Wert nur
    /// nach validem Outdoor-Workout.
    case vo2Max = "VO2_MAX"
    /// **v0.8.3 W-D — render-backlog Aktivitäts-Aggregate.** Diese vier
    /// HK-Typen sammelt + uploadet die App seit v1.4.23 und der Server
    /// persistiert sie als rohe `MeasurementType`-Rows — sie waren nur
    /// nie display-seitig verdrahtet. Mit dem `MetricKind`-Pendant decodet
    /// die `/api/measurements`-Liste sie jetzt zu Domain-Measurements, sodass
    /// Chart-Detail + Measurements-Liste sie zeigen. Die
    /// `/api/measurements/series`- und `/api/dashboard/summary`-Routen führen
    /// sie noch nicht (siehe `kindSupportsSeries == false`); History rendert
    /// daher aus der Listen-Page + HK-Cache. Wire-Keys spiegeln die Server-
    /// Prisma-Enum-Werte (`src/lib/validations/measurement.ts`).
    case activeEnergyBurned = "ACTIVE_ENERGY_BURNED"
    case flightsClimbed = "FLIGHTS_CLIMBED"
    case walkingRunningDistance = "WALKING_RUNNING_DISTANCE"
    case timeInDaylight = "TIME_IN_DAYLIGHT"
    /// **v0.8.4 W-WALK — Gait-Aggregate, jetzt server-persistiert.** Der
    /// Server (v1.6.0) mappt `HKQuantityTypeIdentifierWalkingSpeed` →
    /// `WALKING_SPEED` (m/s) und `HKQuantityTypeIdentifierWalkingStepLength`
    /// → `WALKING_STEP_LENGTH` (m) in `apple-health-mapping.ts` + Batch-
    /// Validator. Die App sammelt + uploadet beide seit v0.5.2 über den
    /// `hkIdentifier`-Batch-Pfad; sie waren nur per
    /// `HealthKitServerSupportConfig` gated (silent skip). Mit dem Server-
    /// Mapping fällt das Gate, und diese zwei Wire-Keys lassen die
    /// `/api/measurements`-Liste die Rows zu Domain-Measurements
    /// (`MetricKind.walkingSpeed` / `.walkingStepLength`) decodieren statt
    /// sie tolerant zu droppen. Wie die übrigen Gait-Metriken führt der
    /// `/api/measurements/series`-Enum sie noch nicht → `kindSupportsSeries`
    /// bleibt false, Detail rendert aus Listen-Page + HK-Cache.
    case walkingSpeed = "WALKING_SPEED"
    case walkingStepLength = "WALKING_STEP_LENGTH"
    /// **v0.11 W21 — web-parity body-composition + cardio additions.** The
    /// server has persisted + validated these eight `MeasurementType`s for a
    /// while (Withings sync for the body-composition + arterial metrics, see
    /// `src/lib/validations/measurement.ts` + `src/lib/withings/`), but iOS had
    /// no `ServerMeasurementType` / `MetricKind` pendant — so every
    /// `GET /api/measurements` page that carried one of these rows dropped it
    /// via the tolerant decoder and the user saw a metric on web that was
    /// invisible on iOS. Adding the wire cases + `MetricKind` mapping lets the
    /// list path decode them to Domain-Measurements that render in the
    /// measurements list, chart-detail + insights long-tail. Read/display-only:
    /// none have a manual-create surface (`toCreateDTOs()` → `[]`) and none are
    /// collected through the iOS HK observer path.
    case fatFreeMass = "FAT_FREE_MASS"
    case leanBodyMass = "LEAN_BODY_MASS"
    case muscleMass = "MUSCLE_MASS"
    case skinTemperature = "SKIN_TEMPERATURE"
    case pulseWaveVelocity = "PULSE_WAVE_VELOCITY"
    case vascularAge = "VASCULAR_AGE"
    case visceralFat = "VISCERAL_FAT"
    case walkingHeartRateAverage = "WALKING_HEART_RATE_AVERAGE"
    case fatMass = "FAT_MASS"
    /// **v0.13.1 IC — v1.10.0 web-parity additive HealthKit signals.** The
    /// server persists + validates these seven `MeasurementType`s (Apple Health
    /// → server ingest, `apple-health-mapping.ts`, since v1.10.0), but iOS had
    /// no `ServerMeasurementType` / `MetricKind` pendant — so a `GET
    /// /api/measurements` page carrying one of these rows dropped it via the
    /// tolerant decoder and the metric never lit up its Insights pill even when
    /// the user had history. Adding the wire cases + the `MetricKind` mapping
    /// lets the list path decode them to Domain-Measurements. Read/display-only:
    /// no manual-create surface, not collected via the iOS HK observer registry.
    case cardioRecovery = "CARDIO_RECOVERY"
    case wristTemperature = "WRIST_TEMPERATURE"
    case fallCount = "FALL_COUNT"
    case sixMinuteWalkDistance = "SIX_MINUTE_WALK_DISTANCE"
    case stairAscentSpeed = "STAIR_ASCENT_SPEED"
    case stairDescentSpeed = "STAIR_DESCENT_SPEED"
    case breathingDisturbances = "BREATHING_DISTURBANCES"
    /// **v0.14.6 — v1.12.8 WHOOP-native read-types (migration 0125).** Without
    /// these wire cases the tolerant list decoder silently dropped every
    /// `AVERAGE_HEART_RATE` / `MAX_HEART_RATE` / `SLEEP_DISTURBANCE_COUNT` row —
    /// invisible on iOS while visible on web (same data-loss class as the WHOOP
    /// source case). Read-only ingest; no client write path.
    case averageHeartRate = "AVERAGE_HEART_RATE"
    case maxHeartRate = "MAX_HEART_RATE"
    case sleepDisturbanceCount = "SLEEP_DISTURBANCE_COUNT"
    /// **v0.14.1 W-B189 — v1.17.1 source-fixed render-only signals (#23).** The
    /// server stores + emits these four `MeasurementType`s LIVE since v1.17.1
    /// (Polar ANS-charge / cardio-load, Oura/Polar/Fitbit sleep-score, Oura
    /// body-temperature DEVIATION). Without these wire cases the tolerant list
    /// decoder silently dropped every row — visible on web, invisible on iOS.
    /// `BODY_TEMPERATURE_DEVIATION` is a SIGNED °C OFFSET from baseline, NOT an
    /// absolute body temperature — it maps to its OWN `MetricKind`, never to
    /// `bodyTemperature`. Read-only ingest; no client write path.
    case ansCharge = "ANS_CHARGE"
    case cardioLoad = "CARDIO_LOAD"
    case sleepScore = "SLEEP_SCORE"
    case bodyTemperatureDeviation = "BODY_TEMPERATURE_DEVIATION"
    /// **v0.11 marathon — sleep + 5 sibling read-types the list decoder dropped.**
    /// The server has persisted + validated all six of these `MeasurementType`s
    /// for a while (`src/lib/validations/measurement.ts` — `SLEEP_DURATION`
    /// line 9, `AUDIO_EXPOSURE_ENV`/`AUDIO_EXPOSURE_HEADPHONE` lines 32-33,
    /// `RESPIRATORY_RATE` line 39, `WALKING_ASYMMETRY`/`WALKING_DOUBLE_SUPPORT`
    /// lines 43-44), but iOS had no `ServerMeasurementType` pendant — so every
    /// `GET /api/measurements` page carrying one of these rows dropped it via the
    /// tolerant decoder (`TolerantMeasurementWire` "Dropping … unsupported type").
    /// Operator hit this hardest on SLEEP: "Bei Schlaf werden keine Messwerte
    /// angezeigt — auch nicht unter 'Daten'." Adding the wire cases + the
    /// `MetricKind` mapping lets the list path decode them to Domain-Measurements.
    ///
    /// **SLEEP unit (v0.14 / v1.11.5 contract):** the LIVE `/api/measurements`
    /// LIST now collapses `SLEEP_DURATION` to ONE per-NIGHT row carrying the
    /// night's TIME ASLEEP (CORE+DEEP+REM, IN_BED/AWAKE excluded, session-
    /// clustered, source-deduped) — NOT per-stage rows. The row carries an
    /// explicit `unit: "minutes"` (`getUnitForType("SLEEP_DURATION")`). The iOS
    /// `.durationHM` formatter + `MetricKind.sleep.unit == "h"` expect HOURS, so
    /// `toDomain()` reads the explicit `unit` and converts minutes → hours via
    /// `sleepHours(from:unit:)` — no hardcoded ÷60 guard. (The dashboard summary
    /// + `series?kind=sleep` surfaces send the same per-night total already in
    /// HOURS with `unit: "h"`; those are handled in their own decoders.)
    case sleepDuration = "SLEEP_DURATION"
    case respiratoryRate = "RESPIRATORY_RATE"
    case audioExposureEnvironment = "AUDIO_EXPOSURE_ENV"
    case audioExposureHeadphone = "AUDIO_EXPOSURE_HEADPHONE"
    case walkingAsymmetry = "WALKING_ASYMMETRY"
    case walkingDoubleSupport = "WALKING_DOUBLE_SUPPORT"
    /// **v0158 — v1.25 clinical measurement types.** Four net-new server
    /// `MeasurementType`s (`src/lib/validations/measurement.ts` L134-137 +
    /// unit map L376-379 + sane bands L580-587). `PAIN_NRS` (score, 0–10, LOINC
    /// 72514-3) and `WAIST_CIRCUMFERENCE` (cm, 30–250, LOINC 8280-0) are manual
    /// clinical signals; `GRIP_STRENGTH` (kg, 0–120) is manual + HK-less;
    /// `WAIST_TO_HEIGHT` (ratio, 0.2–1.5) is server-stored but render-only on iOS
    /// (no manual-create arm). Wire format = SCREAMING_SNAKE.
    case painNRS = "PAIN_NRS"
    case gripStrength = "GRIP_STRENGTH"
    case waistCircumference = "WAIST_CIRCUMFERENCE"
    case waistToHeight = "WAIST_TO_HEIGHT"

    // MARK: - Build 3 / item 3.3 — the 23 wire types the list decoder dropped

    //
    // **Verified against the LIVE server enum, not the audit prose.** A
    // set-difference of `prisma/schema.prisma` `enum MeasurementType` (76
    // members) against this enum returned EXACTLY the 23 tokens below — the
    // audit's count holds — and the reverse difference was EMPTY, i.e. iOS
    // carried no phantom type the server does not know.
    //
    // Until now every one of these rows was silently dropped by
    // `TolerantMeasurementWire` ("Dropping … unsupported type"). The most
    // costly was `ACTIVITY_STEPS`: the server has stored step rows since
    // forever and the list decoder threw all of them away, forcing the
    // drill-down onto a `/series` workaround whose synthesized rows carry a
    // blanket `.appleHealth` source (`MeasurementsRepository+Cumulative.swift`).
    //
    // All 23 are READ-ONLY ingest: `toCreateDTOs()` returns `[]` for every one
    // and the MeasureSheet picker is deliberately NOT re-opened (Build 1
    // removed nine kinds that could never serialize; none of these makes one of
    // those genuinely enterable).

    /// Daily step count. Server enum `ACTIVITY_STEPS`, unit `steps`
    /// (band 0–200 000). Maps onto the EXISTING `MetricKind.steps`.
    case activitySteps = "ACTIVITY_STEPS"
    /// Body Mass Index (kg/m², band 8–70). Server enum `BODY_MASS_INDEX`.
    /// Maps onto the EXISTING `MetricKind.bmi`.
    case bodyMassIndex = "BODY_MASS_INDEX"
    /// PHQ-9 / GAD-7 / WHO-5 / SCI screener SUM scores. Since v1.27.6
    /// (migration 0225) these carry `source = COMPUTED`, which the source enum
    /// already decodes — but without these TYPE cases the rows were dropped one
    /// step earlier, so the screening history was invisible on iOS regardless.
    case phq9Score = "PHQ9_SCORE"
    case gad7Score = "GAD7_SCORE"
    case who5Score = "WHO5_SCORE"
    case sciScore = "SCI_SCORE"
    /// Wearable score classes (WHOOP / Oura / Polar ingest).
    case recoveryScore = "RECOVERY_SCORE"
    case stressScore = "STRESS_SCORE"
    /// The COMPUTED 0–100 strain normalisation — distinct from WHOOP's native
    /// 0–21 ``dayStrain`` / ``workoutStrain``, which map to their own kinds.
    case strainScore = "STRAIN_SCORE"
    /// HRV as RMSSD (ms). Distinct from `HEART_RATE_VARIABILITY` (Apple SDNN) —
    /// different statistic, different magnitude; they must not share a kind.
    case hrvRMSSD = "HRV_RMSSD"
    case dayStrain = "DAY_STRAIN"
    case workoutStrain = "WORKOUT_STRAIN"
    case sleepPerformance = "SLEEP_PERFORMANCE"
    case sleepEfficiency = "SLEEP_EFFICIENCY"
    case sleepConsistency = "SLEEP_CONSISTENCY"
    /// Sleep need in MINUTES (server unit `minutes`). `MetricKind.sleepNeed`
    /// declares `"min"` too, so unlike `SLEEP_DURATION` there is no conversion.
    case sleepNeed = "SLEEP_NEED"
    /// Energy expenditure in KILOJOULES — never folded into
    /// `ACTIVE_ENERGY_BURNED` (kcal); the 4.184× difference would read as a
    /// step change in the chart.
    case energyExpenditureKJ = "ENERGY_EXPENDITURE_KJ"
    /// Oura resilience LEVEL (1–5 ordinal encoded in the numeric value).
    case resilience = "RESILIENCE"
    /// The five CATEGORICAL Apple-Health events (server band `1…1`). The value
    /// is always `1`; the information is the occurrence + its timestamp.
    case irregularRhythmNotification = "IRREGULAR_RHYTHM_NOTIFICATION"
    case highHeartRateEvent = "HIGH_HEART_RATE_EVENT"
    case lowHeartRateEvent = "LOW_HEART_RATE_EVENT"
    /// The walking-steadiness EVENT, distinct from the `WALKING_STEADINESS`
    /// percentage that already had a case.
    case walkingSteadinessEvent = "WALKING_STEADINESS_EVENT"
    /// The breathing-disturbance EVENT, distinct from the
    /// `BREATHING_DISTURBANCES` count that already had a case.
    case breathingDisturbanceEvent = "BREATHING_DISTURBANCE_EVENT"
}

public extension ServerMeasurementType {
    // swiftlint:disable cyclomatic_complexity
    /// The iOS `MetricKind` this server `MeasurementType` token maps to, or `nil`
    /// for a server type that has **no chartable `MetricKind`** (an HK
    /// category/event type that must never land on a numeric axis). Single source
    /// of truth for the wire→domain kind mapping — `toDomain()` reads it and
    /// **drops** a `nil`-kind row (same tolerant "Dropping unsupported type"
    /// contract as `TolerantMeasurementWire`), BP's two wire rows both collapse to
    /// `.bloodPressure` here (the pairing into one domain row happens in
    /// `toDomain()`), and the v1.25 clinical-signal cards use it to resolve a
    /// localized label from a bare type token without re-implementing the switch.
    /// Adding a `ServerMeasurementType` case forces a new arm here
    /// (compiler-enforced exhaustiveness) — the one audit point. A new
    /// non-chartable server type gets `nil` here rather than a fabricated axis.
    var metricKind: MetricKind? {
        switch self {
        case .weight: .weight
        case .bloodPressureSystolic: .bloodPressure
        case .bloodPressureDiastolic: .bloodPressure
        case .bloodGlucose: .glucose
        case .pulse: .pulse
        case .oxygenSaturation: .spo2
        case .bodyFat: .bodyFat
        case .bodyTemperature: .bodyTemperature
        case .totalBodyWater: .bodyWater
        case .boneMass: .boneMass
        case .walkingSteadiness: .walkingSteadiness
        // AUDIO fix — `audioExposureEvent` is an HK category/event type with NO
        // chartable `MetricKind` (`InsightsMetricTabStrip` documents it as
        // deliberately unchartable). The prior `.sleep` arm was a sleeping lie:
        // the day the server emits such a row it would land in the Schlaf list +
        // chart. `nil` is the honest, forward-safe seam — `toDomain()` drops the
        // row like the tolerant decoder drops an unknown type.
        case .audioExposureEvent: nil
        case .restingHeartRate: .restingHeartRate
        case .heartRateVariability: .hrv
        case .vo2Max: .vo2Max
        case .activeEnergyBurned: .activeEnergy
        case .flightsClimbed: .flightsClimbed
        case .walkingRunningDistance: .distanceWalkingRunning
        case .timeInDaylight: .timeInDaylight
        case .walkingSpeed: .walkingSpeed
        case .walkingStepLength: .walkingStepLength
        case .fatFreeMass: .fatFreeMass
        case .leanBodyMass: .leanBodyMass
        case .muscleMass: .muscleMass
        case .skinTemperature: .skinTemperature
        case .pulseWaveVelocity: .pulseWaveVelocity
        case .vascularAge: .vascularAge
        case .visceralFat: .visceralFat
        case .walkingHeartRateAverage: .walkingHeartRate
        case .fatMass: .fatMass
        case .cardioRecovery: .cardioRecovery
        case .wristTemperature: .wristTemperature
        case .fallCount: .falls
        case .sixMinuteWalkDistance: .sixMinuteWalk
        case .stairAscentSpeed: .stairAscentSpeed
        case .stairDescentSpeed: .stairDescentSpeed
        case .breathingDisturbances: .breathingDisturbances
        case .averageHeartRate: .averageHeartRate
        case .maxHeartRate: .maxHeartRate
        case .sleepDisturbanceCount: .sleepDisturbanceCount
        case .ansCharge: .ansCharge
        case .cardioLoad: .cardioLoad
        case .sleepScore: .sleepScore
        case .bodyTemperatureDeviation: .bodyTemperatureDeviation
        case .sleepDuration: .sleep
        case .respiratoryRate: .respiratoryRate
        case .audioExposureEnvironment: .audioExposureEnvironment
        case .audioExposureHeadphone: .audioExposureHeadphone
        case .walkingAsymmetry: .walkingAsymmetry
        case .walkingDoubleSupport: .walkingDoubleSupport
        // v0158 — v1.25 clinical measurement types.
        case .painNRS: .painNRS
        case .gripStrength: .gripStrength
        case .waistCircumference: .waistCircumference
        case .waistToHeight: .waistToHeight
        // Build 3 / item 3.3 — the 23 previously-dropped wire types. Two reuse
        // an existing domain kind; the other 21 got their own so no two
        // physically different readings share an axis.
        case .activitySteps: .steps
        case .bodyMassIndex: .bmi
        case .phq9Score: .phq9Score
        case .gad7Score: .gad7Score
        case .who5Score: .who5Score
        case .sciScore: .sciScore
        case .recoveryScore: .recoveryScore
        case .stressScore: .stressScore
        case .strainScore: .strainScore
        case .hrvRMSSD: .hrvRMSSD
        case .dayStrain: .dayStrain
        case .workoutStrain: .workoutStrain
        case .sleepPerformance: .sleepPerformance
        case .sleepEfficiency: .sleepEfficiency
        case .sleepConsistency: .sleepConsistency
        case .sleepNeed: .sleepNeed
        case .energyExpenditureKJ: .energyExpenditureKJ
        case .resilience: .resilience
        case .irregularRhythmNotification: .irregularRhythmNotification
        case .highHeartRateEvent: .highHeartRateEvent
        case .lowHeartRateEvent: .lowHeartRateEvent
        case .walkingSteadinessEvent: .walkingSteadinessEvent
        case .breathingDisturbanceEvent: .breathingDisturbanceEvent
        }
    }

    // swiftlint:enable cyclomatic_complexity
}

public enum ServerMeasurementSource: String, Codable, Sendable {
    case manual = "MANUAL"
    /// Server-Schema (`measurementSourceEnum`) verwendet `APPLE_HEALTH`. Früher
    /// `HEALTHKIT` — diese Wire-Form rejected der Server seit v1.4.x mit 422.
    case appleHealth = "APPLE_HEALTH"
    case withings = "WITHINGS"
    /// Server-owned read-only ingest (BYO-key OAuth, v1.11.5). Ohne diesen Case
    /// droppt der tolerante List-Decoder jede WHOOP-Zeile still → Mess-Count
    /// divergiert vom Server.
    case whoop = "WHOOP"
    /// Google-Health-/Fitbit-Provider (v1.12.0). Exakte Wire-Schreibweise —
    /// Drift = stiller Decode-Drop (siehe `v1.12.0-server-to-ios-fitbit-source-heads-up`).
    case fitbit = "FITBIT"
    /// Google-Health-API-Provider (Server v1.27.0, Issue #401). Liest Fitbit/
    /// Pixel-Watch-Daten über den Google-Account; läuft NEBEN dem klassischen
    /// `FITBIT`-Provider. Server-owned read-only — der Server nimmt die Source
    /// auf keinem Client-Write-Pfad an. Ohne diesen Case droppt der tolerante
    /// List-Decoder jede GOOGLE_HEALTH-Zeile still → Mess-Count divergiert.
    case googleHealth = "GOOGLE_HEALTH"
    /// Server-derived rows (Read-Enum seit v1.10). Seit v1.27.6 tragen Screening-
    /// Summenscores (PHQ-9 / GAD-7 / WHO-5) diese Source statt `MANUAL` (Migration
    /// 0225). Server-owned read-only — kein Client-Write-Pfad. Ohne diesen Case
    /// droppt der tolerante List-Decoder jede COMPUTED-Zeile still (gleiche
    /// Failure-Mode wie GOOGLE_HEALTH, #40) → die Screening-Zeilen verschwinden.
    case computed = "COMPUTED"
    /// Strava-Provider (Server v1.28.11, iOS #46). Read-only Workout-/Aktivitäts-
    /// Ingest — trägt auf Workout-Rows (`GET /api/sync/changes`, `GET
    /// /api/workouts`) und mit-attribuierten Measurement-Rows. Server-owned, kein
    /// Client-Write-Pfad (nicht in `WRITABLE_MEASUREMENT_SOURCES`). Ohne diesen
    /// Case droppt der tolerante List-Decoder jede STRAVA-Zeile still (gleiche
    /// Failure-Mode wie GOOGLE_HEALTH, #40).
    case strava = "STRAVA"
    /// Oura-Ring-Provider. Die App shippt bereits eine Oura-Integration
    /// (`ouraIntegrationStore`). Server-owned read-only ingest (Recovery/Sleep/
    /// HR). Kein Client-Write-Pfad. Exakte Wire-Schreibweise — Drift = stiller
    /// Decode-Drop.
    case oura = "OURA"
    /// Polar-Provider. Die App shippt bereits eine Polar-Integration
    /// (`polarIntegrationStore`). Server-owned read-only ingest (Cardio-Load/
    /// ANS-Charge/HR). Kein Client-Write-Pfad.
    case polar = "POLAR"
    /// Nightscout-Provider. Die App shippt bereits eine Nightscout-Integration
    /// (`nightscoutIntegrationStore`). Server-owned read-only ingest (CGM-Glukose).
    /// Kein Client-Write-Pfad.
    case nightscout = "NIGHTSCOUT"
    case import_ = "IMPORT"
}

/// Discriminator-Context für Blutzucker-Messungen. Source of Truth: Server-
/// `MeasurementContext`-Enum (`src/lib/validations/measurement.ts`). Server-
/// Wire akzeptiert die vier camelCase-Mappings (FASTING / BEFORE_MEAL /
/// AFTER_MEAL / BEDTIME) auf POST + PATCH und persistiert sie pro Glucose-
/// Row, sodass Series-Charts + Alerts pro Context gruppieren können.
///
/// **Display-Strings (DE primary):** "Nüchtern" / "Vor Mahlzeit" /
/// "Nach Mahlzeit" / "Schlafenszeit". Englische Lokalisierung lebt in
/// `Localizable.xcstrings` — Display wird über `LocalizedStringResource`
/// in `displayResource` aufgelöst, nicht über `displayName` (hardcoded
/// PROJECT_GUIDE.md-Anti-Pattern).
///
/// **HK-Mapping:** Apple's `HKMetadataKeyBloodGlucoseMealTime` nimmt eines
/// von `HKBloodGlucoseMealTime.preprandial` / `.postprandial`. Map:
/// fasting + beforeMeal → `.preprandial`, afterMeal → `.postprandial`,
/// bedtime → kein HK-Pendant (kein metadataValue gesetzt). Siehe
/// `HealthKitService.writeMeasurement` für den Schreibpfad.
///
/// **CU-18 — bewusst GESCHLOSSEN, Toleranz sitzt am Lesepfad.** Das Enum hat
/// keinen Unbekannt-Fall, weil `allCases` die Kontext-Picker in
/// `MeasureSheetView` / `EditMeasurementSheet` speist — ein Sammelfall wäre
/// dort eine anwählbare Option. Ein künftiges Server-Literal fängt statt
/// dessen `MeasurementWireDTO.init(from:)` ab (String-Decode → `nil`), sodass
/// die Messzeile überlebt statt verworfen zu werden.
public enum GlucoseContext: String, Codable, Sendable, CaseIterable, Identifiable {
    case fasting = "FASTING"
    case beforeMeal = "BEFORE_MEAL"
    case afterMeal = "AFTER_MEAL"
    case bedtime = "BEDTIME"

    public var id: String {
        rawValue
    }

    /// Localized label for picker rows + chart annotations. Resolved against
    /// `Localizable.xcstrings`; DE primary, EN secondary.
    public var displayResource: LocalizedStringResource {
        switch self {
        case .fasting: LocalizedStringResource("Fasting", comment: "Glucose context — fasting")
        case .beforeMeal: LocalizedStringResource("Before meal", comment: "Glucose context — before meal")
        case .afterMeal: LocalizedStringResource("After meal", comment: "Glucose context — after meal")
        case .bedtime: LocalizedStringResource("Bedtime", comment: "Glucose context — bedtime")
        }
    }
}

// MARK: - Domain ↔ Wire Mapping

public extension MeasurementWireDTO {
    /// Mappt Server-Wire zu Client-Domain. BP wird vom Client paarweise zusammengeführt
    /// (zwei Wire-Records → ein Domain-Measurement) — siehe `Domain.merge(_:)`.
    ///
    /// The wire→`MetricKind` mapping lives on `ServerMeasurementType.metricKind`
    /// (single source of truth, compiler-enforced exhaustive) so it can be reused
    /// by the v1.25 clinical-signal cards without re-implementing the switch.
    ///
    /// **Failable (AUDIO fix):** a wire type whose `metricKind` is `nil` (a
    /// non-chartable HK category/event type, today only `AUDIO_EXPOSURE_EVENT`)
    /// has no domain representation, so `toDomain()` returns `nil` and the caller
    /// drops the row — the same "Dropping unsupported type" tolerance the list
    /// decoder already applies to a type the enum doesn't know at all.
    func toDomain() -> Measurement? {
        guard let kind = type.metricKind else {
            HLLog.api.warning(
                "Dropping measurement wire row — type \(type.rawValue, privacy: .private) has no chartable MetricKind"
            )
            return nil
        }
        let domainValue: MeasurementValue = if type == .bloodPressureSystolic {
            .bloodPressure(systolic: value, diastolic: 0)
        } else if type == .bloodPressureDiastolic {
            .bloodPressure(systolic: 0, diastolic: value)
        } else if type == .sleepDuration {
            // v0.14 — read the server's EXPLICIT `unit` instead of a hardcoded
            // ÷60 guard. Against the LIVE v1.11.5 contract the
            // `/api/measurements` LIST collapses `SLEEP_DURATION` to ONE
            // per-NIGHT row carrying the night's TIME ASLEEP (CORE+DEEP+REM)
            // with `unit: "minutes"` (server `getUnitForType("SLEEP_DURATION")`
            // → "minutes"). `MetricKind.sleep`'s `.durationHM` formatter +
            // `kind.unit == "h"` expect HOURS, so we convert minutes → hours.
            // If a surface ever sends the value already in hours (`unit: "h"`,
            // as the dashboard summary + series routes do) it's a passthrough —
            // no double-divide. Default to the minutes assumption when the unit
            // is absent (legacy fixtures / the historical list shape).
            .scalar(Self.sleepHours(from: value, unit: unit))
        } else if type == .bloodGlucose {
            // W-B183 — DEFENSIVE glucose unit-at-source guard ahead of server
            // v1.17. `MetricKind.glucose.unit` hardcodes "mg/dL" and every
            // glucose surface interprets the domain scalar AS mg/dL. Today's
            // production (server ≤ v1.16.x) sends glucose WITHOUT a `unit`
            // token, so the absent-unit path MUST stay a verbatim passthrough.
            // When v1.17 starts stamping per-value units we normalise mmol/L →
            // mg/dL (×18.0182) so the domain scalar is always mg/dL and the
            // hardcoded display unit never lies. An unrecognised token is the
            // dangerous case: rather than apply a wrong ~18× factor we keep the
            // raw server value (no scaling) + log — see `glucoseMgdl(from:unit:)`.
            .scalar(Self.glucoseMgdl(from: value, unit: unit))
        } else {
            .scalar(value)
        }
        return Measurement(
            id: id,
            kind: kind,
            recordedAt: measuredAt,
            value: domainValue,
            note: notes,
            source: source.flatMap { $0.toDomain() } ?? .manual,
            externalUUID: externalId,
            // T-2: hydrate glucose-context from the server wire so chart-
            // groupers + edit-sheets can read it off the Domain model
            // without round-tripping the wire DTO. Only meaningful when
            // `type == .bloodGlucose`; server already keeps it `nil` on
            // every other row.
            //
            // CU-18: verbatim pass-through — auch auf einer `BLOOD_GLUCOSE`-
            // Zeile bleibt `nil` `nil` (Server-Migration 0274 erlaubt das).
            // Kein Default, kein "wahrscheinlich nüchtern".
            glucoseContext: glucoseContext
        )
    }

    /// Normalises a server `SLEEP_DURATION` value into the app's HOURS display
    /// unit, driven by the row's EXPLICIT `unit` token (v0.14 / v1.11.5).
    ///
    /// **v0.14.2 M5 — exhaustive over KNOWN sleep units; safe default.** The
    /// prior version divided ANY non-hour token by 60, so a `"ns"`/`"ms"`/`"s"`
    /// row (the sleep DTO universe also carries `"ns"` — `SleepNightDTO.asleepns`
    /// + the server `getUnitForType` history) would have produced a wildly wrong
    /// "hours" value (7 h shown as billions). The switch is now explicit over
    /// every sub-hour unit the contract can carry, with sub-minute units scaled
    /// by their real factor:
    ///
    /// - `"h"` / `"hour"` / `"hours"` / `"hr"` → already hours → passthrough.
    /// - `"minutes"` / `"min"` (the LIVE `/api/measurements` LIST per-night
    ///   shape, `getUnitForType("SLEEP_DURATION") == "minutes"`) → ÷ 60.
    /// - `"s"` / `"sec"` / `"seconds"` → ÷ 3600.
    /// - `"ms"` → ÷ 3.6e6. `"ns"` → ÷ 3.6e12.
    /// - absent → assume minutes (the canonical `SLEEP_DURATION` LIST unit) so
    ///   legacy fixtures / write-paths that omit `unit` stay correct.
    /// - genuinely unknown token → log + assume minutes (current behaviour, but
    ///   now explicit) rather than blindly ÷ 60 on a unit we don't recognise.
    static func sleepHours(from value: Double, unit: String?) -> Double {
        switch unit?.lowercased() {
        case "h", "hour", "hours", "hr": return value
        case "minutes", "minute", "min", nil: return value / 60.0
        case "s", "sec", "secs", "second", "seconds": return value / 3600.0
        case "ms", "millisecond", "milliseconds": return value / 3_600_000.0
        case "ns", "nanosecond", "nanoseconds": return value / 3_600_000_000_000.0
        case let other:
            HLLog.api.warning(
                "sleepHours: unknown SLEEP_DURATION unit \(other ?? "<nil>", privacy: .private) — assuming minutes"
            )
            return value / 60.0
        }
    }

    /// **W-B183 — DEFENSIVE glucose unit normaliser, ahead of server v1.17
    /// unit-at-source.** Normalises a server `BLOOD_GLUCOSE` value into the
    /// app's canonical mg/dL domain, driven by the row's EXPLICIT `unit` token.
    ///
    /// The whole iOS glucose stack (`MetricKind.glucose.unit == "mg/dL"`,
    /// every tile/chart/insights interpreter) treats the domain scalar AS
    /// mg/dL. Today's production server (≤ v1.16.x) sends glucose WITHOUT a
    /// `unit` token, so the absent-unit path is a verbatim passthrough — zero
    /// behaviour change for the only case in production. When v1.17 starts
    /// stamping per-value units this converts the two real-world glucose units:
    ///
    /// - `"mg/dl"` / `"mgdl"` / `"mg/dL"` (case-insensitive) → already mg/dL →
    ///   passthrough.
    /// - `"mmol/l"` / `"mmoll"` / `"mmol"` → ×18.0182 (the IFCC molar-mass
    ///   factor for glucose) so the domain scalar lands in mg/dL.
    /// - absent (`nil`) → assume mg/dL (today's production shape) → passthrough.
    /// - genuinely UNKNOWN token → log + return the RAW value UNSCALED. We
    ///   deliberately prefer showing the server's number under our mg/dL label
    ///   over applying a guessed conversion: a wrong ×18 (or ÷18) factor on a
    ///   clinical glucose reading is a far worse failure than a unit-label
    ///   mismatch the operator can eyeball. Never silently mis-scale.
    static func glucoseMgdl(from value: Double, unit: String?) -> Double {
        // IFCC conversion factor mmol/L → mg/dL for glucose (molar mass
        // 180.156 g/mol ÷ 10). 1 mmol/L == 18.0182 mg/dL.
        let mmolToMgdl = 18.0182
        switch unit?.lowercased().replacingOccurrences(of: " ", with: "") {
        case "mg/dl", "mgdl", "mgperdl", nil:
            return value
        case "mmol/l", "mmoll", "mmol", "mmolperl":
            return value * mmolToMgdl
        case let other:
            HLLog.api.warning(
                "glucoseMgdl: unknown BLOOD_GLUCOSE unit \(other ?? "<nil>", privacy: .private) — returning raw value unscaled (no guessed conversion)"
            )
            return value
        }
    }
}

public extension ServerMeasurementSource {
    func toDomain() -> MeasurementSource {
        switch self {
        case .manual: .manual
        case .appleHealth: .appleHealth
        case .withings: .withings
        case .whoop: .whoop
        case .fitbit: .fitbit
        case .googleHealth: .googleHealth
        case .computed: .computed
        case .strava: .strava
        case .oura: .oura
        case .polar: .polar
        case .nightscout: .nightscout
        case .import_: .import_
        }
    }
}

public extension MeasurementSource {
    var wire: ServerMeasurementSource {
        switch self {
        case .manual: .manual
        case .appleHealth: .appleHealth
        case .withings: .withings
        case .whoop: .whoop
        case .fitbit: .fitbit
        case .googleHealth: .googleHealth
        case .computed: .computed
        case .strava: .strava
        case .oura: .oura
        case .polar: .polar
        case .nightscout: .nightscout
        case .import_: .import_
        }
    }
}

/// Eingaben-Schema: was iOS dem Server schickt. Ein einzelner Datenpunkt.
public struct MeasurementCreateDTO: Encodable, Sendable {
    public let type: ServerMeasurementType
    public let value: Double
    public let measuredAt: Date
    public let notes: String?
    public let source: ServerMeasurementSource?
    public let glucoseContext: GlucoseContext?
    public let externalId: String?

    public init(
        type: ServerMeasurementType,
        value: Double,
        measuredAt: Date,
        notes: String? = nil,
        source: ServerMeasurementSource? = nil,
        glucoseContext: GlucoseContext? = nil,
        externalId: String? = nil
    ) {
        self.type = type
        self.value = value
        self.measuredAt = measuredAt
        self.notes = notes
        self.source = source
        self.glucoseContext = glucoseContext
        self.externalId = externalId
    }
}

/// Server-List-Response.
///
/// **v0.6.2.1 — tolerant `measurements` decode (F3 drill-down fix).** The
/// Prisma `MeasurementType` enum on the server is a superset of
/// `ServerMeasurementType` here — it also carries `ACTIVITY_STEPS`,
/// `SLEEP_DURATION`, `ACTIVE_ENERGY_BURNED`, `FLIGHTS_CLIMBED`,
/// `WALKING_RUNNING_DISTANCE`, `AUDIO_EXPOSURE_*` and any future
/// server-only type. Whenever an
/// HK-batch upload (or Withings sync) populates one of those rows, every
/// drill-down that calls `GET /api/measurements?limit=400` saw the whole
/// `[MeasurementWireDTO]` decode reject with `dataCorrupted` on the
/// unknown enum case, leaving the user staring at "Daten konnten nicht
/// gelesen werden" with an empty list. Operator hit this on the Steps
/// chart (845 entries) on 2026-05-24.
///
/// Same tolerant pattern as `TolerantMetricKind` (v0.4.0 A4-Audit row 5)
/// — log + drop unknown rows, keep the array intact for the known
/// metrics the iOS surfaces actually render.
public struct MeasurementListWireResponse: Codable, Sendable {
    public let measurements: [MeasurementWireDTO]
    public let meta: MeasurementListResponse.ListMeta?

    public init(measurements: [MeasurementWireDTO], meta: MeasurementListResponse.ListMeta? = nil) {
        self.measurements = measurements
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case measurements
        case meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tolerant = try container.decode([TolerantMeasurementWire].self, forKey: .measurements)
        measurements = tolerant.compactMap(\.value)
        meta = try container.decodeIfPresent(MeasurementListResponse.ListMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(measurements, forKey: .measurements)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

/// Tolerant element wrapper used inside `MeasurementListWireResponse` so a
/// single row carrying a `type` outside `ServerMeasurementType` (e.g.
/// `ACTIVITY_STEPS` until the iOS enum catches up) doesn't reject the whole
/// 400-row page. Mirrors `TolerantMetricKind`'s "log + continue" contract.
private struct TolerantMeasurementWire: Decodable {
    let value: MeasurementWireDTO?

    init(from decoder: Decoder) throws {
        do {
            value = try MeasurementWireDTO(from: decoder)
        } catch {
            // Best-effort surface the offending `type` for diagnostics —
            // every other field is uninteresting once the enum check fails.
            let container = try? decoder.container(keyedBy: DiagnosticKey.self)
            let rawType = try? container?.decodeIfPresent(String.self, forKey: .type)
            HLLog.api.warning(
                "Dropping measurement wire row with unsupported type \(rawType ?? "<unknown>", privacy: .public)"
            )
            value = nil
        }
    }

    private enum DiagnosticKey: String, CodingKey {
        case type
    }
}

/// Aggregator: nimmt eine Liste BP-getrennter Wire-Records und führt sie zu Domain-Measurements
/// zusammen (gleicher `measuredAt` + gleiche `source` → eine BP-Messung).
public enum MeasurementAggregator {
    public static func mergeBloodPressure(_ wires: [MeasurementWireDTO]) -> [Measurement] {
        var byDate: [Date: (sys: MeasurementWireDTO?, dia: MeasurementWireDTO?)] = [:]
        var others: [Measurement] = []
        for wire in wires {
            switch wire.type {
            case .bloodPressureSystolic:
                byDate[wire.measuredAt, default: (nil, nil)].sys = wire
            case .bloodPressureDiastolic:
                byDate[wire.measuredAt, default: (nil, nil)].dia = wire
            default:
                // AUDIO fix — a non-chartable wire row (`toDomain() == nil`) is
                // dropped here, exactly like the tolerant list decoder drops an
                // unknown type. A BP row never hits this branch.
                if let measurement = wire.toDomain() {
                    others.append(measurement)
                }
            }
        }
        var bps: [Measurement] = []
        for (_, pair) in byDate {
            if let sys = pair.sys, let dia = pair.dia {
                bps.append(Measurement(
                    id: sys.id, // primary id is systolic
                    kind: .bloodPressure,
                    recordedAt: sys.measuredAt,
                    value: .bloodPressure(systolic: sys.value, diastolic: dia.value),
                    note: sys.notes ?? dia.notes,
                    source: sys.source?.toDomain() ?? .manual,
                    externalUUID: sys.externalId,
                    // T-1: carry both peer ids so edit-paths can fan-out a
                    // paired PATCH that updates BOTH server rows. Without
                    // this the diastolic peer silently keeps its old value
                    // on every BP edit (per AC10 audit finding).
                    bloodPressureDiastolicId: dia.id
                ))
            } else if let only = pair.sys ?? pair.dia, let measurement = only.toDomain() {
                // `only` is always a BP wire row, whose `metricKind` is non-nil,
                // so `toDomain()` never returns nil here — the `if let` is just
                // the compiler contract now that `toDomain()` is failable.
                bps.append(measurement)
            }
        }
        return (others + bps).sorted(by: { $0.recordedAt > $1.recordedAt })
    }
}

/// Patch body for `PATCH /api/measurements/[id]`. All fields optional —
/// server applies only the keys that are present.
///
/// **BP-pair semantics (T-1):** `value` is the systolic component on the
/// systolic-row PATCH und der `diastolic`-Wert (wenn gesetzt) trägt den
/// diastolischen Wert für den paired-PATCH auf die `BLOOD_PRESSURE_DIA`-
/// Peer-Row. Das `diastolic`-Feld wird *nicht* an den Server geschickt —
/// es ist nur eine clientseitige Intent-Trag-Hilfe, die das Repository
/// in zwei einzelne wire-PATCH-Calls fanoutet. Custom `CodingKeys` filtern
/// es aus der serialisierten JSON.
public struct MeasurementPatch: Codable, Sendable {
    public let value: Double?
    public let measuredAt: Date?
    public let notes: String?
    /// Client-side intent for BP pair-update. Suppressed from JSON
    /// serialization (server does not accept it on `PATCH
    /// /api/measurements/[id]`). The repo fans out by issuing a second
    /// PATCH against the diastolic peer with `value = diastolic` instead.
    public let diastolic: Double?
    /// Client-side intent for glucose-context edits (T-2). Suppressed from
    /// JSON serialization — server-side `MeasurementPatch` Zod-schema in
    /// `src/lib/validations/measurement.ts` currently only accepts value /
    /// measuredAt / notes (server-team flagged as SB-25 to add this on
    /// PATCH post-v1.4.30). Until then the context survives via two paths:
    ///
    /// 1. **Edit-Sheet → optimistic-write:** the UI carries
    ///    `glucoseContext` through the optimistic `Measurement` injected
    ///    into the store snapshot, so the row visually reflects the new
    ///    context immediately. On the wire only value/measuredAt/notes go
    ///    out — the server-persisted context stays at its original value.
    /// 2. **Outbox-replay survives via the pair-aware payload in
    ///    `OutboxQueue.Payloads.UpdateMeasurement`** (`glucoseContext`
    ///    field). Replay re-hydrates the patch with the persisted intent.
    public let glucoseContext: GlucoseContext?

    public init(
        value: Double? = nil,
        measuredAt: Date? = nil,
        notes: String? = nil,
        diastolic: Double? = nil,
        glucoseContext: GlucoseContext? = nil
    ) {
        self.value = value
        self.measuredAt = measuredAt
        self.notes = notes
        self.diastolic = diastolic
        self.glucoseContext = glucoseContext
    }

    private enum WireCodingKeys: String, CodingKey {
        case value
        case measuredAt
        case notes
    }

    /// Wire encoding: emit value / measuredAt / notes only. `diastolic`
    /// (T-1) und `glucoseContext` (T-2) sind intentional suppressed —
    /// beide sind client-side fan-out / intent-Signale, keine server-
    /// accepted fields. Server schema:
    /// `src/lib/validations/measurement.ts` only knows the three wire keys.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireCodingKeys.self)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(measuredAt, forKey: .measuredAt)
        try container.encodeIfPresent(notes, forKey: .notes)
    }

    /// Wire decoding: read the three documented server fields. `diastolic`
    /// + `glucoseContext` are only ever populated client-side (Edit-Sheet
    /// → repo), so when decoding from persisted outbox payloads or wire
    /// responses we keep them `nil`. Outbox round-trips that need these
    /// fields use the pair-aware payload in
    /// `OutboxQueue.Payloads.UpdateMeasurement`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireCodingKeys.self)
        value = try container.decodeIfPresent(Double.self, forKey: .value)
        measuredAt = try container.decodeIfPresent(Date.self, forKey: .measuredAt)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        diastolic = nil
        glucoseContext = nil
    }
}

/// Request body for `DELETE /api/measurements/by-external-ids` — bulk
/// reconciliation when HK deletes propagate from the system Health app.
public struct ExternalIDBatch: Codable, Sendable {
    public let externalIds: [String]
    public init(externalIds: [String]) {
        self.externalIds = externalIds
    }
}
