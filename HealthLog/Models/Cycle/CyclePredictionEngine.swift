// Split across `CyclePredictionEngine+Prediction.swift` (day math + robust
// stats + the §1-§5 estimators + the public `predictCycle` pipeline) and
// `CyclePredictionEngine+Phase.swift` (phase mapping + BBT conversion) —
// file_length split, pure code movement. This file keeps the pinned constant
// set and the boundary/input contracts so the parity mapping stays auditable
// per theme.

import Foundation

/// Pure, deterministic menstrual-cycle prediction — the **1:1 offline mirror**
/// of the server's authoritative TypeScript engine
/// (`HealthLog/src/lib/cycle/{day-math,prediction,phase,types}.ts`).
///
/// **Parity contract.** The server materialises `CyclePredictionDTO` from the
/// same canonical inputs the device holds. For the offline calendar to render
/// without a round-trip — and for the server row to match a local recompute —
/// this Swift code MUST produce byte-identical output. Every constant below is
/// annotated with its server name; every rounding step + day-diff mirrors the
/// server exactly. Source of truth: v1.15 contract §7 + the engine-parity
/// clarifications note (2026-06-06).
///
/// **Where this lives / why pure.** Part of `HealthLogCore` (plattform-frei —
/// no HealthKit, no network, no UI, no `Date.now`). Day math is done on
/// `YYYY-MM-DD` strings anchored at noon-UTC (NEVER wall-clock local), exactly
/// like the server, so DST + timezone can never flip a rounded day count.
///
/// **Honesty contract.** Output always carries a date band + confidence; sparse
/// / irregular histories degrade gracefully (wider band, lower confidence)
/// rather than emitting a false-precise hard date. The engine NEVER frames
/// output as contraceptive guidance.
public enum CyclePredictionEngine {
    // MARK: - Pinned constants (server §7 / types.ts — RECONCILED 2026-06-06)

    /// Pinned algorithm constants, mirroring the server's `types.ts` exactly.
    /// Bundled into a value type so tests can pin alternative parameterisations.
    /// The server constant name is given for each so future drift is traceable.
    public struct Tuning: Sendable, Equatable {
        /// `HISTORY_WINDOW_N` — trailing window of completed cycles for length.
        public var historyWindowN: Int
        /// `MIN_CYCLES_TO_PREDICT` — ≥ this many completed cycles for a real
        /// (non-priors) prediction.
        public var minCyclesToPredict: Int
        /// `SIGMA_FLOOR` — floor on robust SD (days); band never zero-width.
        public var sigmaFloor: Double
        /// `MAD_NORMAL_CONST` — `sigma = MAD_NORMAL_CONST * MAD`.
        public var madNormalConst: Double
        /// `Z_BAND` — one-sigma band multiplier (NOT a CI). Deliberately 1.0.
        public var zBand: Double
        /// `HALF_WIDTH_MIN` / `HALF_WIDTH_MAX` — date-band half-width clamp (days).
        public var halfWidthMin: Int
        public var halfWidthMax: Int
        /// `PRIORS_ONLY_HALF_WIDTH` — fixed half-width on the 0-cycle path.
        public var priorsOnlyHalfWidth: Int
        /// `COLD_START_BAND_BONUS` — extra half-width on the single-cycle path.
        public var coldStartBandBonus: Int
        /// `PERIOD_WINDOW_N` — last N cycles feed the period-length estimator.
        public var periodWindowN: Int
        /// `POPULATION_DEFAULT_CYCLE` / `POPULATION_DEFAULT_PERIOD`.
        public var populationDefaultCycle: Int
        public var populationDefaultPeriod: Int
        /// `PERIOD_MIN` / `PERIOD_MAX` — period-length clamp (days).
        public var periodMin: Int
        public var periodMax: Int
        /// `LUTEAL_DEFAULT` / `LUTEAL_MIN` / `LUTEAL_MAX`.
        public var lutealDefault: Int
        public var lutealMin: Int
        public var lutealMax: Int
        /// `FERTILE_PRE` / `FERTILE_POST` — window = ovulation−5 … ovulation+1.
        public var fertilePre: Int
        public var fertilePost: Int
        /// `OUTLIER_K` / `OUTLIER_K_PERIMENOPAUSE` — robust MAD-fence multiplier.
        public var outlierK: Double
        public var outlierKPerimenopause: Double
        /// `HARD_CYCLE_MIN` / `HARD_CYCLE_MAX` — hard physiological bounds.
        public var hardCycleMin: Int
        public var hardCycleMax: Int
        /// `MISSED_LOG_FACTOR` — length ≥ this × median ⇒ probable missed-log.
        public var missedLogFactor: Double
        /// `TEMP_SHIFT_C_MANUAL` / `TEMP_SHIFT_C_PASSIVE` — BBT rise thresholds.
        public var tempShiftCManual: Double
        public var tempShiftCPassive: Double
        /// `HALF_WIDTH_MULT_SYMPTOTHERMAL` / `_TEMP_TREND` — confirm multipliers.
        public var halfWidthMultSymptothermal: Double
        public var halfWidthMultTempTrend: Double
        /// `SYMPTOTHERMAL_AGREE_DAYS` — temp-shift ↔ mucus-peak tolerance.
        public var symptothermalAgreeDays: Int
        /// `BBT_WINDOW` — trailing lookback (days) for symptothermal detectors.
        public var bbtWindow: Int
        /// `CONFIDENCE_MIN` / `CONFIDENCE_MAX` — confidence scalar clamp.
        public var confidenceMin: Double
        public var confidenceMax: Double
        /// `CONFIDENCE_LABEL_LOW_MAX` / `_HIGH_MIN` — label cut points.
        public var confidenceLabelLowMax: Double
        public var confidenceLabelHighMin: Double
        /// `ADHERENCE_FLOOR` / `ADHERENCE_SLOPE` — `c = floor + slope*density`.
        public var adherenceFloor: Double
        public var adherenceSlope: Double
        /// `LOG_SPARSITY_SCALE` — max band widening from sparse logging.
        public var logSparsityScale: Double

        public init(
            historyWindowN: Int = 12, // HISTORY_WINDOW_N
            minCyclesToPredict: Int = 2, // MIN_CYCLES_TO_PREDICT
            sigmaFloor: Double = 1.0, // SIGMA_FLOOR
            madNormalConst: Double = 1.4826, // MAD_NORMAL_CONST
            zBand: Double = 1.0, // Z_BAND
            halfWidthMin: Int = 1, // HALF_WIDTH_MIN
            halfWidthMax: Int = 14, // HALF_WIDTH_MAX
            priorsOnlyHalfWidth: Int = 4, // PRIORS_ONLY_HALF_WIDTH
            coldStartBandBonus: Int = 3, // COLD_START_BAND_BONUS
            periodWindowN: Int = 6, // PERIOD_WINDOW_N
            populationDefaultCycle: Int = 28, // POPULATION_DEFAULT_CYCLE
            populationDefaultPeriod: Int = 5, // POPULATION_DEFAULT_PERIOD
            periodMin: Int = 1, // PERIOD_MIN
            periodMax: Int = 10, // PERIOD_MAX
            lutealDefault: Int = 14, // LUTEAL_DEFAULT
            lutealMin: Int = 10, // LUTEAL_MIN
            lutealMax: Int = 16, // LUTEAL_MAX
            fertilePre: Int = 5, // FERTILE_PRE
            fertilePost: Int = 1, // FERTILE_POST
            outlierK: Double = 3.0, // OUTLIER_K
            outlierKPerimenopause: Double = 4.0, // OUTLIER_K_PERIMENOPAUSE
            hardCycleMin: Int = 21, // HARD_CYCLE_MIN
            hardCycleMax: Int = 45, // HARD_CYCLE_MAX
            missedLogFactor: Double = 1.75, // MISSED_LOG_FACTOR
            tempShiftCManual: Double = 0.2, // TEMP_SHIFT_C_MANUAL
            tempShiftCPassive: Double = 0.15, // TEMP_SHIFT_C_PASSIVE
            halfWidthMultSymptothermal: Double = 0.6, // HALF_WIDTH_MULT_SYMPTOTHERMAL
            halfWidthMultTempTrend: Double = 0.75, // HALF_WIDTH_MULT_TEMP_TREND
            symptothermalAgreeDays: Int = 2, // SYMPTOTHERMAL_AGREE_DAYS
            bbtWindow: Int = 40, // BBT_WINDOW
            confidenceMin: Double = 0.05, // CONFIDENCE_MIN
            confidenceMax: Double = 0.98, // CONFIDENCE_MAX
            confidenceLabelLowMax: Double = 0.4, // CONFIDENCE_LABEL_LOW_MAX
            confidenceLabelHighMin: Double = 0.7, // CONFIDENCE_LABEL_HIGH_MIN
            adherenceFloor: Double = 0.4, // ADHERENCE_FLOOR
            adherenceSlope: Double = 0.6, // ADHERENCE_SLOPE
            logSparsityScale: Double = 0.5 // LOG_SPARSITY_SCALE
        ) {
            self.historyWindowN = historyWindowN
            self.minCyclesToPredict = minCyclesToPredict
            self.sigmaFloor = sigmaFloor
            self.madNormalConst = madNormalConst
            self.zBand = zBand
            self.halfWidthMin = halfWidthMin
            self.halfWidthMax = halfWidthMax
            self.priorsOnlyHalfWidth = priorsOnlyHalfWidth
            self.coldStartBandBonus = coldStartBandBonus
            self.periodWindowN = periodWindowN
            self.populationDefaultCycle = populationDefaultCycle
            self.populationDefaultPeriod = populationDefaultPeriod
            self.periodMin = periodMin
            self.periodMax = periodMax
            self.lutealDefault = lutealDefault
            self.lutealMin = lutealMin
            self.lutealMax = lutealMax
            self.fertilePre = fertilePre
            self.fertilePost = fertilePost
            self.outlierK = outlierK
            self.outlierKPerimenopause = outlierKPerimenopause
            self.hardCycleMin = hardCycleMin
            self.hardCycleMax = hardCycleMax
            self.missedLogFactor = missedLogFactor
            self.tempShiftCManual = tempShiftCManual
            self.tempShiftCPassive = tempShiftCPassive
            self.halfWidthMultSymptothermal = halfWidthMultSymptothermal
            self.halfWidthMultTempTrend = halfWidthMultTempTrend
            self.symptothermalAgreeDays = symptothermalAgreeDays
            self.bbtWindow = bbtWindow
            self.confidenceMin = confidenceMin
            self.confidenceMax = confidenceMax
            self.confidenceLabelLowMax = confidenceLabelLowMax
            self.confidenceLabelHighMin = confidenceLabelHighMin
            self.adherenceFloor = adherenceFloor
            self.adherenceSlope = adherenceSlope
            self.logSparsityScale = logSparsityScale
        }

        /// The reconcile target — defaults that match the server engine 1:1.
        public static let `default` = Tuning()
    }

    // MARK: - Boundary enums (string raw-values match the Prisma enums 1:1)

    /// `FlowLevel` (types.ts). Raw values match the Prisma enum members.
    public enum FlowLevel: String, Sendable, Equatable, Codable, CaseIterable {
        case none = "NONE"
        case spotting = "SPOTTING"
        case light = "LIGHT"
        case medium = "MEDIUM"
        case heavy = "HEAVY"

        /// Bleeding day = flow in {SPOTTING, LIGHT, MEDIUM, HEAVY} (server `isBleeding`).
        public var isBleeding: Bool {
            switch self {
            case .spotting, .light, .medium, .heavy: true
            case .none: false
            }
        }
    }

    /// `OvulationTest` (types.ts).
    public enum OvulationTest: String, Sendable, Equatable, Codable, CaseIterable {
        case negative = "NEGATIVE"
        case positiveLHSurge = "POSITIVE_LH_SURGE"
        case estrogenSurge = "ESTROGEN_SURGE"
        case indeterminate = "INDETERMINATE"
    }

    /// `CervicalMucus` (types.ts).
    public enum CervicalMucus: String, Sendable, Equatable, Codable, CaseIterable {
        case dry = "DRY"
        case sticky = "STICKY"
        case creamy = "CREAMY"
        case watery = "WATERY"
        case eggWhite = "EGG_WHITE"
    }

    /// `CyclePhase` (types.ts).
    public enum CyclePhase: String, Sendable, Equatable, Codable, CaseIterable {
        case menstrual = "MENSTRUAL"
        case follicular = "FOLLICULAR"
        case ovulatory = "OVULATORY"
        case luteal = "LUTEAL"
    }

    /// `PredictionMethod` (types.ts). CALENDAR is the MVP baseline; the
    /// symptothermal / temperature-trend / blended ladder mirrors the server.
    public enum PredictionMethod: String, Sendable, Equatable, Codable, CaseIterable {
        case calendar = "CALENDAR"
        case symptothermal = "SYMPTOTHERMAL"
        case temperatureTrend = "TEMPERATURE_TREND"
        case blended = "BLENDED"
    }

    /// `CycleTrackingGoal` (types.ts).
    public enum CycleTrackingGoal: String, Sendable, Equatable, Codable, CaseIterable {
        case generalHealth = "GENERAL_HEALTH"
        case avoidPregnancy = "AVOID_PREGNANCY"
        case tryingToConceive = "TRYING_TO_CONCEIVE"
        case perimenopause = "PERIMENOPAUSE"
        case off = "OFF"
    }

    /// `ConfidenceLabel` (types.ts).
    public enum ConfidenceLabel: String, Sendable, Equatable, Codable, CaseIterable {
        case low
        case medium
        case high
    }

    // MARK: - Input contracts (mirror types.ts)

    /// One confirmed (or predicted) cycle. `startDate` is the first bleeding day.
    /// COMPLETED only when a later cycle's `startDate` exists (known length).
    public struct CycleInput: Sendable, Equatable {
        public var startDate: String
        public var endDate: String?
        public var periodEndDate: String?
        public var ovulationDate: String?
        public var ovulationConfirmed: Bool

        public init(
            startDate: String,
            endDate: String? = nil,
            periodEndDate: String? = nil,
            ovulationDate: String? = nil,
            ovulationConfirmed: Bool = false
        ) {
            self.startDate = startDate
            self.endDate = endDate
            self.periodEndDate = periodEndDate
            self.ovulationDate = ovulationDate
            self.ovulationConfirmed = ovulationConfirmed
        }
    }

    /// One day's observations (the HealthKit / manual sync unit).
    /// `basalBodyTempC` MUST already be °C rounded to 2 dp (server contract).
    public struct DayLogInput: Sendable, Equatable {
        public var date: String
        public var flow: FlowLevel?
        public var basalBodyTempC: Double?
        public var ovulationTest: OvulationTest?
        public var cervicalMucus: CervicalMucus?

        public init(
            date: String,
            flow: FlowLevel? = nil,
            basalBodyTempC: Double? = nil,
            ovulationTest: OvulationTest? = nil,
            cervicalMucus: CervicalMucus? = nil
        ) {
            self.date = date
            self.flow = flow
            self.basalBodyTempC = basalBodyTempC
            self.ovulationTest = ovulationTest
            self.cervicalMucus = cervicalMucus
        }
    }

    /// One nightly passive-temperature reading (Apple Watch wrist/skin temp).
    public struct NightlyTempInput: Sendable, Equatable {
        public var date: String
        public var valueC: Double

        public init(date: String, valueC: Double) {
            self.date = date
            self.valueC = valueC
        }
    }

    /// User priors + mode flags (`CycleProfileInput`). All optional defaults.
    public struct CycleProfileInput: Sendable, Equatable {
        public var goal: CycleTrackingGoal
        public var typicalCycleLength: Int?
        public var typicalPeriodLength: Int?
        public var lutealPhaseLength: Int?
        public var predictionEnabled: Bool
        public var rawChartMode: Bool

        public init(
            goal: CycleTrackingGoal = .generalHealth,
            typicalCycleLength: Int? = nil,
            typicalPeriodLength: Int? = nil,
            lutealPhaseLength: Int? = nil,
            predictionEnabled: Bool = true,
            rawChartMode: Bool = false
        ) {
            self.goal = goal
            self.typicalCycleLength = typicalCycleLength
            self.typicalPeriodLength = typicalPeriodLength
            self.lutealPhaseLength = lutealPhaseLength
            self.predictionEnabled = predictionEnabled
            self.rawChartMode = rawChartMode
        }
    }
}
