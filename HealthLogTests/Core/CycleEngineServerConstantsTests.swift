import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// The on-device cycle engine against the server's constants, not its own.
///
/// The values below are copied from the server's `src/lib/cycle/types.ts`
/// (HealthLog v1.47.2). When the server moves a constant, this list is the one
/// place to update, and the engine has to follow before the suite is green.
@Suite("Cycle engine tuning matches the server constants")
struct CycleEngineServerConstantsTests {
    typealias Engine = CyclePredictionEngine

    @Test("Every tuning default equals its server constant")
    func tuningMatchesServer() {
        let tuning = Engine.Tuning.default
        #expect(tuning.historyWindowN == 12) // HISTORY_WINDOW_N
        #expect(tuning.minCyclesToPredict == 2) // MIN_CYCLES_TO_PREDICT
        #expect(tuning.sigmaFloor == 1.0) // SIGMA_FLOOR
        #expect(tuning.madNormalConst == 1.4826) // MAD_NORMAL_CONST
        #expect(tuning.zBand == 1.0) // Z_BAND
        #expect(tuning.halfWidthMin == 1) // HALF_WIDTH_MIN
        #expect(tuning.halfWidthMax == 14) // HALF_WIDTH_MAX
        #expect(tuning.priorsOnlyHalfWidth == 4) // PRIORS_ONLY_HALF_WIDTH
        #expect(tuning.coldStartBandBonus == 3) // COLD_START_BAND_BONUS
        #expect(tuning.periodWindowN == 6) // PERIOD_WINDOW_N
        #expect(tuning.populationDefaultCycle == 28) // POPULATION_DEFAULT_CYCLE
        #expect(tuning.populationDefaultPeriod == 5) // POPULATION_DEFAULT_PERIOD
        #expect(tuning.periodMin == 1) // PERIOD_MIN
        #expect(tuning.periodMax == 10) // PERIOD_MAX
        #expect(tuning.lutealDefault == 14) // LUTEAL_DEFAULT
        #expect(tuning.lutealMin == 10) // LUTEAL_MIN
        #expect(tuning.lutealMax == 16) // LUTEAL_MAX
        #expect(tuning.fertilePre == 5) // FERTILE_PRE
        #expect(tuning.fertilePost == 1) // FERTILE_POST
        #expect(tuning.outlierK == 3.0) // OUTLIER_K
        #expect(tuning.outlierKPerimenopause == 4.0) // OUTLIER_K_PERIMENOPAUSE
        #expect(tuning.hardCycleMin == 21) // HARD_CYCLE_MIN
        #expect(tuning.hardCycleMax == 60) // HARD_CYCLE_MAX
        #expect(tuning.missedLogFactor == 1.75) // MISSED_LOG_FACTOR
        #expect(tuning.tempShiftCManual == 0.2) // TEMP_SHIFT_C_MANUAL
        #expect(tuning.tempShiftCPassive == 0.15) // TEMP_SHIFT_C_PASSIVE
        #expect(tuning.halfWidthMultSymptothermal == 0.6) // HALF_WIDTH_MULT_SYMPTOTHERMAL
        #expect(tuning.halfWidthMultTempTrend == 0.75) // HALF_WIDTH_MULT_TEMP_TREND
        #expect(tuning.symptothermalAgreeDays == 2) // SYMPTOTHERMAL_AGREE_DAYS
        #expect(tuning.bbtWindow == 40) // BBT_WINDOW
        #expect(tuning.confidenceMin == 0.05) // CONFIDENCE_MIN
        #expect(tuning.confidenceMax == 0.98) // CONFIDENCE_MAX
        #expect(tuning.confidenceLabelLowMax == 0.4) // CONFIDENCE_LABEL_LOW_MAX
        #expect(tuning.confidenceLabelHighMin == 0.7) // CONFIDENCE_LABEL_HIGH_MIN
        #expect(tuning.adherenceFloor == 0.4) // ADHERENCE_FLOOR
        #expect(tuning.adherenceSlope == 0.6) // ADHERENCE_SLOPE
        #expect(tuning.logSparsityScale == 0.5) // LOG_SPARSITY_SCALE
    }

    @Test("Long but steady cycles up to 60 days count towards the estimate")
    func longSteadyCyclesAreKept() {
        // Median 51, MAD 1: no fence and no missed-log hit, only the hard cap
        // could drop them, and at 45 it dropped every one.
        let est = Engine.estimateCycleLength([50, 52, 51, 50, 52], goal: .tryingToConceive, tuning: .default)
        #expect(est.cyclesObserved == 5)
        #expect(est.lengthRounded == 51)
    }

    @Test("60 days is still kept, 61 days is cut by the hard cap")
    func hardCapBoundary() {
        // Median 60, MAD 1, fence 55.6 to 64.4: 61 and 62 sit inside the fence,
        // so only HARD_CYCLE_MAX removes them.
        let est = Engine.estimateCycleLength([58, 62, 60, 61, 59], goal: .tryingToConceive, tuning: .default)
        #expect(est.cyclesObserved == 3)
        #expect(est.lengthRounded == 59)
    }

    @Test("A wild length in a regular history is still dropped as a missed log")
    func missedLogStillExcluded() {
        let est = Engine.estimateCycleLength([28, 28, 29, 28, 28, 58], goal: .tryingToConceive, tuning: .default)
        #expect(est.cyclesObserved == 5)
        #expect(est.lengthRounded == 28)
    }
}
