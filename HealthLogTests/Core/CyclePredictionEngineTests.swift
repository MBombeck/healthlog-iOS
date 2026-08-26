import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Parity tests for the pure `CyclePredictionEngine` (HealthLogCore).
///
/// The engine is the 1:1 offline mirror of the server's TypeScript engine
/// (`HealthLog/src/lib/cycle/*.ts`). These tests assert against the **pinned
/// server constants** (v1.15 contract §7 + the engine-parity clarifications)
/// and port the server's `__tests__/{day-math,prediction,phase}.test.ts`
/// expectations: same inputs → same outputs. All day math is `YYYY-MM-DD`
/// strings anchored at noon-UTC, so the assertions are timezone-independent.
@Suite("CyclePredictionEngine")
struct CyclePredictionEngineTests {
    typealias Engine = CyclePredictionEngine

    private let baseProfile = Engine.CycleProfileInput(goal: .tryingToConceive)

    /// Build a chain of cycles from an anchor, each `gaps[i]` days apart
    /// (mirrors the server fixture helper `cyclesFromGaps`).
    private func cyclesFromGaps(_ anchor: String, _ gaps: [Int]) -> [Engine.CycleInput] {
        var starts = [anchor]
        for g in gaps {
            starts.append(Engine.addDays(starts[starts.count - 1], g))
        }
        return starts.enumerated().map { i, start in
            Engine.CycleInput(
                startDate: start,
                endDate: i < starts.count - 1 ? starts[i + 1] : nil
            )
        }
    }

    // MARK: - Day math (port of day-math.test.ts)

    @Test("dayDiff is noon-UTC anchored and round-half-up stable across DST")
    func dayMath() {
        #expect(Engine.dayDiff("2024-01-02", "2024-01-01") == 1)
        #expect(Engine.dayDiff("2024-01-01", "2024-01-02") == -1)
        #expect(Engine.dayDiff("2024-01-01", "2024-01-01") == 0)
        // DST spring-forward (US) / fall-back must not shift the day count.
        #expect(Engine.dayDiff("2024-03-11", "2024-03-10") == 1) // spring forward
        #expect(Engine.dayDiff("2024-11-04", "2024-11-03") == 1) // fall back
        #expect(Engine.addDays("2024-01-31", 1) == "2024-02-01")
        #expect(Engine.addDays("2024-03-10", 1) == "2024-03-11")
        #expect(Engine.addDays("2024-01-01", -1) == "2023-12-31")
    }

    @Test("roundHalf is round-half-away-from-zero to k decimals")
    func roundHalfRule() {
        #expect(Engine.roundHalf(2.5) == 3)
        #expect(Engine.roundHalf(-2.5) == -3) // away from zero on a tie
        #expect(Engine.roundHalf(2.345, 2) == 2.35)
        #expect(Engine.roundHalf(-2.345, 2) == -2.35)
    }

    @Test("BBT °F → °C rounds to 2dp BEFORE any rule")
    func bbtConversion() {
        // 98.6°F = 37.00°C
        #expect(Engine.fahrenheitToCelsius2dp(98.6) == 37.0)
        // 97.7°F = (97.7-32)/1.8 = 36.5°C
        #expect(Engine.fahrenheitToCelsius2dp(97.7) == 36.5)
    }

    // MARK: - Robust statistics (port of prediction.test.ts)

    @Test("median: odd + even (even = unrounded mean of two central)")
    func medianRule() {
        #expect(Engine.median([28, 30, 29]) == 29)
        #expect(Engine.median([28, 30]) == 29)
        #expect(Engine.median([28, 31]) == 29.5)
        #expect(Engine.median([]).isNaN)
    }

    @Test("regular 28-day user: median 28, MAD 0 → sigma floor 1.0")
    func estimatorRegular() {
        let est = Engine.estimateCycleLength([28, 28, 28, 28, 28, 28], goal: .tryingToConceive, tuning: .default)
        #expect(est.lengthRounded == 28)
        #expect(est.sigma == 1.0) // SIGMA_FLOOR (MAD = 0)
        #expect(est.cyclesObserved == 6)
        #expect(abs(est.cv - 1.0 / 28.0) < 1e-9)
    }

    @Test("irregular user: high MAD widens sigma = 1.4826 * MAD")
    func estimatorIrregular() {
        // lengths 24,28,32,26,30,28 → median 28, devs 4,0,4,2,2,0 → MAD 2.
        let est = Engine.estimateCycleLength([24, 28, 32, 26, 30, 28], goal: .tryingToConceive, tuning: .default)
        #expect(est.lengthRounded == 28)
        #expect(abs(est.sigma - 1.4826 * 2) < 1e-9) // 2.9652
    }

    @Test("excludes a missed-log outlier from the estimate but counts it against confidence")
    func estimatorOutlierExcluded() {
        // 28,28,29,28,28 + a wild 60 (missed-log: >= 1.75*28 = 49).
        let est = Engine.estimateCycleLength([28, 28, 29, 28, 28, 60], goal: .tryingToConceive, tuning: .default)
        #expect(est.lengthRounded == 28)
        #expect(est.cyclesObserved == 5) // 60 excluded
    }

    @Test("hard-bounds: a 14-day length is always an outlier candidate")
    func estimatorHardBounds() {
        let est = Engine.estimateCycleLength([28, 28, 14, 28, 29], goal: .tryingToConceive, tuning: .default)
        #expect(est.cyclesObserved == 4) // 14 < HARD_CYCLE_MIN 21
        #expect(est.lengthRounded == 28)
    }

    @Test("perimenopause widens the fence (OUTLIER_K 4 keeps ≥ as many)")
    func estimatorPerimenopause() {
        let lengths = [28, 30, 26, 40, 24, 32]
        let normal = Engine.estimateCycleLength(lengths, goal: .tryingToConceive, tuning: .default)
        let peri = Engine.estimateCycleLength(lengths, goal: .perimenopause, tuning: .default)
        #expect(peri.cyclesObserved >= normal.cyclesObserved)
    }

    // MARK: - Period length (§2)

    @Test("contiguous 5-day bleeding run")
    func periodRun() {
        let logs = [
            Engine.DayLogInput(date: "2024-01-01", flow: .medium),
            Engine.DayLogInput(date: "2024-01-02", flow: .heavy),
            Engine.DayLogInput(date: "2024-01-03", flow: .medium),
            Engine.DayLogInput(date: "2024-01-04", flow: .light),
            Engine.DayLogInput(date: "2024-01-05", flow: .spotting)
        ]
        #expect(Engine.observedPeriodLength("2024-01-01", dayLogs: logs, tuning: .default) == 5)
    }

    /// 1:1 server parity (`prediction.ts` `observedPeriodLength`): the lookahead
    /// walks `0 <= offset <= periodMax + 1`. For a continuous bleeding run longer
    /// than that window, `lastBleeding` caps at `periodMax + 1` and the inclusive
    /// `lastBleeding + 1` count is `periodMax + 2`. The earlier A360-5 M-4 "fix"
    /// tightened the bound to `0 ... periodMax`, which BROKE server parity (the
    /// server still iterates to `periodMax + 1`); BH-final-diff H1 reverted it.
    @Test("Observed period length matches server lookahead bound (periodMax + 1)")
    func periodLengthMatchesServerBound() {
        // 14 consecutive bleeding days from the start — far longer than the
        // lookahead window. The server walks offsets 0...(periodMax + 1) and
        // returns the inclusive count `periodMax + 2`.
        let logs = (0 ..< 14).map { offset in
            Engine.DayLogInput(date: Engine.addDays("2024-01-01", offset), flow: .medium)
        }
        let observed = Engine.observedPeriodLength("2024-01-01", dayLogs: logs, tuning: .default)
        // lastBleeding caps at offset `periodMax + 1`; inclusive count = +2.
        #expect(observed == Engine.Tuning.default.periodMax + 2)
    }

    // MARK: - Adherence density (§3) — A360-5 M-3 NaN guard

    /// A360-5 M-3 — on the cycle-start day (`today == lastStart`, sinceStart 0)
    /// the density division must NOT yield NaN. Pre-fix `expectedDays` resolved
    /// to 0 and the loop filter excluded the day-0 observation; the guard now
    /// clamps `expectedDays` to ≥ 1 so the math is finite and a same-day
    /// observation counts.
    @Test("M-3: adherence density is finite on the cycle-start day (day 0)")
    func adherenceDensityFiniteOnStartDay() {
        let start = "2024-01-01"
        let logs = [
            Engine.DayLogInput(date: start, flow: .medium)
        ]
        let factors = Engine.adherenceFactors(
            lastStart: start,
            estimatedLength: 28,
            dayLogs: logs,
            today: start, // sinceStart == 0
            tuning: .default
        )
        #expect(factors.cAdherence.isFinite)
        #expect(factors.logSparsity.isFinite)
        // The single same-day observation now counts against a clamped
        // denominator of 1 → density 1 → adherence at its slope ceiling.
        let t = Engine.Tuning.default
        #expect(abs(factors.cAdherence - (t.adherenceFloor + t.adherenceSlope)) < 1e-9)
        #expect(abs(factors.logSparsity - 0) < 1e-9)
    }

    /// Day-0 with NO observation must also stay finite (density 0), not NaN.
    @Test("M-3: adherence density finite on day 0 with no observation")
    func adherenceDensityFiniteOnStartDayNoLog() {
        let start = "2024-01-01"
        let factors = Engine.adherenceFactors(
            lastStart: start,
            estimatedLength: 28,
            dayLogs: [],
            today: start,
            tuning: .default
        )
        #expect(factors.cAdherence.isFinite)
        #expect(factors.logSparsity.isFinite)
        let t = Engine.Tuning.default
        // density 0 → adherence at floor, sparsity at full scale.
        #expect(abs(factors.cAdherence - t.adherenceFloor) < 1e-9)
        #expect(abs(factors.logSparsity - t.logSparsityScale) < 1e-9)
    }

    // MARK: - Predict: 0/1/2 cycles (stillLearning + cold start)

    @Test("0 cycles → priors-only CALENDAR, population default 28, stillLearning")
    func zeroCycles() {
        let cycles = [Engine.CycleInput(startDate: "2026-01-01")]
        let p = Engine.predictCycle(cycles: cycles, profile: baseProfile, today: "2026-01-10")
        #expect(p.method == .calendar)
        #expect(p.estimatedCycleLength == 28) // POPULATION_DEFAULT_CYCLE
        #expect(p.cyclesObserved == 0)
        #expect(p.stillLearning == true)
        #expect(p.nextPeriodStart == "2026-01-29") // 01-01 + 28
        // PRIORS_ONLY_HALF_WIDTH = 4.
        #expect(p.nextPeriodStartLow == "2026-01-25")
        #expect(p.nextPeriodStartHigh == "2026-02-02")
        #expect(p.predictedPeriodLength == 5) // POPULATION_DEFAULT_PERIOD
        #expect(p.confidence == 0.2)
    }

    @Test("1 cycle → cold-start band bonus, stillLearning")
    func oneCycle() {
        // One completed length of 28.
        let cycles = cyclesFromGaps("2026-01-01", [28])
        let p = Engine.predictCycle(cycles: cycles, profile: baseProfile, today: "2026-02-01")
        #expect(p.cyclesObserved == 1)
        #expect(p.stillLearning == true)
        #expect(p.estimatedCycleLength == 28)
        #expect(p.nextPeriodStart == "2026-02-26") // 01-29 + 28
        // sigma floors at 1.0 (single length, MAD 0) → raw band round(1)=1;
        // confirmMult 1 → +COLD_START_BAND_BONUS 3 → round → 4 (× penalty if
        // sparse logging widens it). At minimum it exceeds the 1-cycle floor.
        #expect(p.nextPeriodStartHigh > p.nextPeriodStart)
        let hw = Engine.dayDiff(p.nextPeriodStartHigh, p.nextPeriodStart)
        #expect(hw >= 4) // cold-start bonus present
    }

    @Test("2 cycles → real prediction, still <3 so stillLearning")
    func twoCycles() {
        let cycles = cyclesFromGaps("2026-01-01", [28, 28]) // two completed lengths
        let p = Engine.predictCycle(cycles: cycles, profile: baseProfile, today: "2026-02-26")
        #expect(p.cyclesObserved == 2)
        #expect(p.stillLearning == true) // <3
        #expect(p.estimatedCycleLength == 28)
        #expect(p.nextPeriodStart == "2026-03-26") // 02-26 + 28
    }

    // MARK: - Regular 28-day → exact dates + ovulation + fertile window

    @Test("regular 28-day → next date, one-sigma band, ovulation, fertile window")
    func regular28Day() {
        let cycles = cyclesFromGaps("2026-01-01", [28, 28, 28]) // 3 completed lengths
        let p = Engine.predictCycle(cycles: cycles, profile: baseProfile, today: "2026-03-26")
        #expect(p.estimatedCycleLength == 28)
        #expect(p.estimatedCycleSd == 1.0) // SIGMA_FLOOR
        #expect(p.nextPeriodStart == "2026-04-23") // last start 03-26 + 28
        // Ovulation = next − luteal(14) = 04-09; not confirmed.
        #expect(p.predictedOvulation == "2026-04-09")
        #expect(p.ovulationConfirmed == false)
        // Fertile window = ovulation−5 … ovulation+1 = 04-04 … 04-10.
        #expect(p.fertileWindowStart == "2026-04-04")
        #expect(p.fertileWindowEnd == "2026-04-10")
        #expect(p.cyclesObserved == 3)
        #expect(p.stillLearning == false)
        #expect(p.method == .calendar)
    }

    @Test("order-independent: unsorted cycle inputs give the same result")
    func orderIndependent() {
        let sorted = cyclesFromGaps("2026-01-01", [28, 28, 28])
        let shuffled = [sorted[2], sorted[0], sorted[3], sorted[1]]
        let a = Engine.predictCycle(cycles: sorted, profile: baseProfile, today: "2026-03-26")
        let b = Engine.predictCycle(cycles: shuffled, profile: baseProfile, today: "2026-03-26")
        #expect(a == b)
    }

    // MARK: - Irregular → MAD-driven band widening

    @Test("irregular cycles widen the band vs regular")
    func irregularWidensBand() {
        let regular = Engine.predictCycle(
            cycles: cyclesFromGaps("2026-01-01", [28, 28, 28, 28]),
            profile: baseProfile, today: "2026-04-23"
        )
        let irregular = Engine.predictCycle(
            cycles: cyclesFromGaps("2026-01-01", [24, 32, 26, 30]),
            profile: baseProfile, today: "2026-04-23"
        )
        let regHW = Engine.dayDiff(regular.nextPeriodStartHigh, regular.nextPeriodStart)
        let irrHW = Engine.dayDiff(irregular.nextPeriodStartHigh, irregular.nextPeriodStart)
        #expect(irrHW > regHW) // higher MAD → wider one-sigma band
        #expect(irregular.confidence < regular.confidence)
    }

    // MARK: - Luteal override

    @Test("profile lutealPhaseLength overrides the default in ovulation back-calc")
    func lutealOverride() {
        var profile = baseProfile
        profile.lutealPhaseLength = 12
        let p = Engine.predictCycle(
            cycles: cyclesFromGaps("2026-01-01", [28, 28, 28]),
            profile: profile, today: "2026-03-26"
        )
        // next 04-23, luteal 12 → ovulation 04-11 (vs 04-09 at default 14).
        #expect(p.predictedOvulation == "2026-04-11")
        #expect(p.fertileWindowStart == "2026-04-06") // ov − 5
        #expect(p.fertileWindowEnd == "2026-04-12") // ov + 1
    }

    @Test("out-of-range luteal override is clamped to [10,16]")
    func lutealClamp() {
        var profile = baseProfile
        profile.lutealPhaseLength = 99 // clamps to 16
        let p = Engine.predictCycle(
            cycles: cyclesFromGaps("2026-01-01", [28, 28, 28]),
            profile: profile, today: "2026-03-26"
        )
        #expect(p.predictedOvulation == "2026-04-07") // next 04-23 − 16
    }

    // MARK: - BBT °F input flows through the symptothermal layer as °C

    @Test("BBT °F input converted to °C 2dp before the 3-over-6 rule")
    func bbtFahrenheitInput() {
        /// Six baseline + three elevated. Use °F, convert at the boundary.
        func log(_ date: String, fahrenheit: Double, mucus: Engine.CervicalMucus? = nil) -> Engine.DayLogInput {
            Engine.DayLogInput(
                date: date,
                basalBodyTempC: Engine.fahrenheitToCelsius2dp(fahrenheit),
                cervicalMucus: mucus
            )
        }
        // Baseline ~97.0°F (36.11°C), rise ~97.7°F (36.5°C) → clears 0.2°C.
        var logs: [Engine.DayLogInput] = []
        let baseDates = (1 ... 6).map { String(format: "2026-04-%02d", $0) }
        for d in baseDates {
            logs.append(log(d, fahrenheit: 97.0))
        }
        logs.append(log("2026-04-07", fahrenheit: 97.7, mucus: .eggWhite)) // rise day 1 + mucus peak
        logs.append(log("2026-04-08", fahrenheit: 97.8))
        logs.append(log("2026-04-09", fahrenheit: 97.9))
        // The 3-over-6 confirms ovulation = day before first elevated = 04-06,
        // mucus peak = 04-07 (within ±2). Verify the detector fires on °C input.
        let shift = Engine.detectTempShift(logs, thresholdC: 0.2)
        #expect(shift == "2026-04-06")
        let sympto = Engine.confirmSymptothermal(logs, tuning: .default)
        #expect(sympto == "2026-04-06")
    }

    // MARK: - Phase assignment (port of phase.test.ts)

    @Test("phase boundaries: menstrual / follicular / ovulatory / luteal")
    func phaseBoundaries() {
        // 28-day cycle, period 5, luteal 14 → ovulation = start + (28−14) = +14.
        let cycle = Engine.PhaseCycle(
            startDate: "2026-01-01",
            nextStart: "2026-01-29",
            ovulationDate: nil,
            periodLength: 5,
            lutealLength: 14
        )
        // Day 1..5 menstrual.
        #expect(Engine.phaseForDay("2026-01-01", cycle: cycle).phase == .menstrual)
        #expect(Engine.phaseForDay("2026-01-05", cycle: cycle).phase == .menstrual)
        // Day 6 follicular.
        #expect(Engine.phaseForDay("2026-01-06", cycle: cycle).phase == .follicular)
        // Ovulation offset = 14 → ovulatory window [13,15] = 2026-01-14..16.
        #expect(Engine.phaseForDay("2026-01-14", cycle: cycle).phase == .ovulatory)
        #expect(Engine.phaseForDay("2026-01-15", cycle: cycle).phase == .ovulatory)
        #expect(Engine.phaseForDay("2026-01-16", cycle: cycle).phase == .ovulatory)
        // Day after ovulatory → luteal.
        #expect(Engine.phaseForDay("2026-01-17", cycle: cycle).phase == .luteal)
        #expect(Engine.phaseForDay("2026-01-28", cycle: cycle).phase == .luteal)
        // dayOfCycle is 1-based.
        #expect(Engine.phaseForDay("2026-01-01", cycle: cycle).dayOfCycle == 1)
        #expect(Engine.phaseForDay("2026-01-28", cycle: cycle).dayOfCycle == 28)
        // Outside the window → nil.
        #expect(Engine.phaseForDay("2026-01-29", cycle: cycle).phase == nil)
        #expect(Engine.phaseForDay("2025-12-31", cycle: cycle).phase == nil)
    }

    @Test("phaseSeries spans the inclusive range")
    func phaseSeriesSpan() {
        let cycle = Engine.PhaseCycle(
            startDate: "2026-01-01", nextStart: "2026-01-29",
            periodLength: 5, lutealLength: 14
        )
        let series = Engine.phaseSeries(from: "2026-01-01", to: "2026-01-05", cycle: cycle)
        #expect(series.count == 5)
        #expect(series.allSatisfy { $0.phase == .menstrual })
    }
}
