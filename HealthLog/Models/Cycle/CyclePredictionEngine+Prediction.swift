import Foundation

/// Day math, robust statistics, the §1/§2 estimators, the §4 symptothermal /
/// temperature-trend detectors, the §3 confidence factors and the public
/// `predictCycle` pipeline — moved verbatim out of
/// `CyclePredictionEngine.swift` so the engine file stays under SwiftLint's
/// `file_length` ceiling (pure code movement, no behavior change). Every
/// member keeps its original access level; the server-parity annotations
/// travel with the code.
extension CyclePredictionEngine {
    // MARK: - Output contract (mirrors CyclePredictionResult / CyclePredictionDTO)

    public struct Prediction: Sendable, Equatable {
        public var method: PredictionMethod
        /// Point estimate of the next period's first day, `YYYY-MM-DD`.
        public var nextPeriodStart: String
        /// Low/high ends of the one-sigma date band (NOT a CI), `YYYY-MM-DD`.
        public var nextPeriodStartLow: String
        public var nextPeriodStartHigh: String
        /// Predicted next period-bar length (days), clamped [1,10].
        public var predictedPeriodLength: Int
        /// Fertile window (ovulation−5 … ovulation+1). Caller goal-gates display.
        public var fertileWindowStart: String?
        public var fertileWindowEnd: String?
        public var predictedOvulation: String?
        public var ovulationConfirmed: Bool
        /// Confidence scalar in [0.05, 0.98], rounded to 2 dp.
        public var confidence: Double
        public var confidenceLabel: ConfidenceLabel
        /// Completed cycle lengths used (post outlier-exclusion).
        public var cyclesObserved: Int
        /// `cyclesObserved < 3` → "still learning" UI state.
        public var stillLearning: Bool
        public var estimatedCycleLength: Int
        /// Robust SD of cycle length (days), ≥ SIGMA_FLOOR, rounded to 2 dp.
        public var estimatedCycleSd: Double

        public init(
            method: PredictionMethod,
            nextPeriodStart: String,
            nextPeriodStartLow: String,
            nextPeriodStartHigh: String,
            predictedPeriodLength: Int,
            fertileWindowStart: String?,
            fertileWindowEnd: String?,
            predictedOvulation: String?,
            ovulationConfirmed: Bool,
            confidence: Double,
            confidenceLabel: ConfidenceLabel,
            cyclesObserved: Int,
            stillLearning: Bool,
            estimatedCycleLength: Int,
            estimatedCycleSd: Double
        ) {
            self.method = method
            self.nextPeriodStart = nextPeriodStart
            self.nextPeriodStartLow = nextPeriodStartLow
            self.nextPeriodStartHigh = nextPeriodStartHigh
            self.predictedPeriodLength = predictedPeriodLength
            self.fertileWindowStart = fertileWindowStart
            self.fertileWindowEnd = fertileWindowEnd
            self.predictedOvulation = predictedOvulation
            self.ovulationConfirmed = ovulationConfirmed
            self.confidence = confidence
            self.confidenceLabel = confidenceLabel
            self.cyclesObserved = cyclesObserved
            self.stillLearning = stillLearning
            self.estimatedCycleLength = estimatedCycleLength
            self.estimatedCycleSd = estimatedCycleSd
        }
    }

    // MARK: - Day math (mirrors day-math.ts — noon-UTC anchored, round-half-up)

    /// Milliseconds in one calendar day (`MS_PER_DAY`).
    static let msPerDay: Double = 86_400_000

    /// Parse `YYYY-MM-DD` → epoch-ms anchored at **noon UTC** (`parseDayMs`).
    /// Returns nil on a malformed string (caller treats as a parity bug input).
    static func parseDayMs(_ date: String) -> Double? {
        let parts = date.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var c = DateComponents()
        c.year = y
        c.month = m
        c.day = d
        c.hour = 12
        c.minute = 0
        c.second = 0
        guard let date = utcCalendar.date(from: c) else { return nil }
        return date.timeIntervalSince1970 * 1000
    }

    /// Whole-day difference `a - b`, positive when `a` is later (`dayDiff`).
    /// Rounds the ms quotient half-up so the noon anchor stays DST-stable.
    static func dayDiff(_ a: String, _ b: String) -> Int {
        guard let ma = parseDayMs(a), let mb = parseDayMs(b) else { return 0 }
        return Int(roundHalf((ma - mb) / msPerDay))
    }

    /// `YYYY-MM-DD` string `n` days after `date` (`addDays`), off the noon anchor.
    static func addDays(_ date: String, _ n: Int) -> String {
        guard let ms = parseDayMs(date) else { return date }
        let shifted = Date(timeIntervalSince1970: (ms + Double(n) * msPerDay) / 1000)
        let comps = utcCalendar.dateComponents([.year, .month, .day], from: shifted)
        let y = comps.year ?? 0, m = comps.month ?? 0, d = comps.day ?? 0
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// Round-half-UP to `k` decimals (`roundHalf`) ↔ `.toNearestOrAwayFromZero`.
    static func roundHalf(_ x: Double, _ k: Int = 0) -> Double {
        guard x.isFinite else { return x }
        let factor = pow(10.0, Double(k))
        return (x * factor).rounded(.toNearestOrAwayFromZero) / factor
    }

    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return cal
    }()

    // MARK: - Robust statistics (mirror prediction.ts)

    /// Median (`median`). Even count → mean of the two central order statistics
    /// (NOT rounded — fractional precision flows through the band math).
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .nan }
        let s = values.sorted()
        let mid = s.count / 2
        return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
    }

    /// Median absolute deviation about a centre (`mad`).
    static func mad(_ values: [Double], centre: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        return median(values.map { abs($0 - centre) })
    }

    private static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        min(hi, max(lo, x))
    }

    private static func clampInt(_ x: Int, _ lo: Int, _ hi: Int) -> Int {
        min(hi, max(lo, x))
    }

    // MARK: - §1 cycle-length estimation

    struct LengthEstimate: Equatable {
        var lengthFractional: Double
        var lengthRounded: Int
        var sigma: Double
        var cv: Double
        var cyclesObserved: Int
    }

    /// Completed lengths = diffs of consecutive sorted starts (`completedLengths`).
    static func completedLengths(_ cycles: [CycleInput]) -> [Int] {
        let starts = cycles.map(\.startDate).sorted { dayDiff($0, $1) < 0 }
        guard starts.count >= 2 else { return [] }
        var lengths: [Int] = []
        for i in 0 ..< (starts.count - 1) {
            lengths.append(dayDiff(starts[i + 1], starts[i]))
        }
        return lengths
    }

    /// §1 + §5 — robust median+MAD over the trailing window with 3-MAD outlier
    /// exclusion + missed-log detection (`estimateCycleLength`).
    static func estimateCycleLength(
        _ lengths: [Int],
        goal: CycleTrackingGoal,
        tuning: Tuning
    ) -> LengthEstimate {
        let ls = Array(lengths.suffix(tuning.historyWindowN)).map(Double.init)
        if ls.isEmpty {
            return LengthEstimate(
                lengthFractional: .nan, lengthRounded: 0,
                sigma: tuning.sigmaFloor, cv: 0, cyclesObserved: 0
            )
        }

        let preMedian = median(ls)
        let sigmaPre = tuning.madNormalConst * mad(ls, centre: preMedian)
        let k = goal == .perimenopause ? tuning.outlierKPerimenopause : tuning.outlierK
        let fenceLow = preMedian - k * sigmaPre
        let fenceHigh = preMedian + k * sigmaPre
        let missedLogThreshold = tuning.missedLogFactor * preMedian

        let kept = ls.filter { length in
            let beyondFence = sigmaPre > 0 && (length < fenceLow || length > fenceHigh)
            let beyondHard = length < Double(tuning.hardCycleMin) || length > Double(tuning.hardCycleMax)
            let missedLog = length >= missedLogThreshold
            return !(beyondFence || beyondHard || missedLog)
        }
        let usable = kept.count >= 1 ? kept : ls

        let lengthFractional = median(usable)
        let lengthRounded = Int(roundHalf(lengthFractional))
        let sigmaRaw = tuning.madNormalConst * mad(usable, centre: lengthFractional)
        let sigma = sigmaRaw > 0 ? sigmaRaw : tuning.sigmaFloor
        let cv = lengthFractional > 0 ? sigma / lengthFractional : 0
        // cyclesObserved counts KEPT lengths — excluded outliers erode
        // confidence but don't bias the point estimate (parity note §2).
        return LengthEstimate(
            lengthFractional: lengthFractional,
            lengthRounded: lengthRounded,
            sigma: sigma,
            cv: cv,
            cyclesObserved: kept.count
        )
    }

    // MARK: - §2 period-length estimation

    /// Maximal contiguous bleeding run from `startDate`; a single dry day does
    /// not break it, a ≥2-day gap does (`observedPeriodLength`).
    static func observedPeriodLength(
        _ startDate: String,
        dayLogs: [DayLogInput],
        tuning: Tuning
    ) -> Int {
        var bleedingByDate: Set<String> = []
        for log in dayLogs where log.flow?.isBleeding ?? false {
            bleedingByDate.insert(log.date)
        }
        guard bleedingByDate.contains(startDate) else { return 0 }
        var lastBleeding = 0
        var gap = 0
        // 1:1 server parity (`prediction.ts` `observedPeriodLength`): walk forward
        // up to `PERIOD_MAX + 1` days; the run breaks on a >=2-day gap. The earlier
        // A360-5 M-4 "fix" tightened this to `0 ... periodMax` and BROKE parity —
        // the server still iterates `0 <= offset <= PERIOD_MAX + 1`, so an offline
        // iOS prediction would visibly jump when the authoritative server value
        // lands. Keep the bounds identical to the server; if the bound is ever
        // tightened, change the SERVER first and port.
        for offset in 0 ... (tuning.periodMax + 1) {
            let date = addDays(startDate, offset)
            if bleedingByDate.contains(date) {
                lastBleeding = offset
                gap = 0
            } else {
                gap += 1
                if gap >= 2 { break }
            }
        }
        return lastBleeding + 1
    }

    /// §2 — robust period-length over the last 6 cycles, clamped [1,10]
    /// (`estimatePeriodLength`).
    static func estimatePeriodLength(
        _ cycles: [CycleInput],
        dayLogs: [DayLogInput],
        profile: CycleProfileInput,
        tuning: Tuning
    ) -> Int {
        let sorted = cycles.sorted { dayDiff($0.startDate, $1.startDate) < 0 }
        let recent = Array(sorted.suffix(tuning.periodWindowN))
        var observed: [Double] = []
        for c in recent {
            if let end = c.periodEndDate {
                let len = dayDiff(end, c.startDate) + 1
                if len >= tuning.periodMin { observed.append(Double(len)) }
            } else {
                let len = observedPeriodLength(c.startDate, dayLogs: dayLogs, tuning: tuning)
                if len >= tuning.periodMin { observed.append(Double(len)) }
            }
        }
        if observed.isEmpty {
            let prior = Double(profile.typicalPeriodLength ?? tuning.populationDefaultPeriod)
            return clampInt(Int(roundHalf(prior)), tuning.periodMin, tuning.periodMax)
        }
        return clampInt(Int(roundHalf(median(observed))), tuning.periodMin, tuning.periodMax)
    }

    // MARK: - §4 luteal resolution

    /// Clamp luteal to [LUTEAL_MIN, LUTEAL_MAX] (`clampLuteal`).
    static func clampLuteal(_ raw: Int, tuning: Tuning) -> Int {
        clampInt(raw, tuning.lutealMin, tuning.lutealMax)
    }

    /// Resolve luteal from profile override or default (`resolveLuteal`).
    static func resolveLuteal(_ profile: CycleProfileInput, tuning: Tuning) -> Int {
        clampLuteal(profile.lutealPhaseLength ?? tuning.lutealDefault, tuning: tuning)
    }

    // MARK: - §4 symptothermal + temperature-trend detection

    /// §4.2(a) sensiplan 3-over-6 BBT rule (`detectTempShift`).
    /// Returns the confirmed ovulation day (day before the first elevated reading).
    static func detectTempShift(_ dayLogs: [DayLogInput], thresholdC: Double) -> String? {
        let temps = dayLogs
            .compactMap { log -> (date: String, t: Double)? in
                guard let t = log.basalBodyTempC else { return nil }
                return (log.date, t)
            }
            .sorted { dayDiff($0.date, $1.date) < 0 }
        guard temps.count >= 9 else { return nil }
        var i = temps.count - 3
        while i >= 6 {
            let baseline = temps[(i - 6) ..< i]
            let sixMax = baseline.map(\.t).max() ?? -.infinity
            let rise = [temps[i], temps[i + 1], temps[i + 2]]
            let allAbove = rise.allSatisfy { $0.t > sixMax }
            let thirdClears = roundHalf(rise[2].t - sixMax, 2) >= thresholdC
            if allAbove, thirdClears {
                return addDays(rise[0].date, -1)
            }
            i -= 1
        }
        return nil
    }

    /// §4.2(b) cervical-mucus peak = last egg-white/watery day (`detectMucusPeak`).
    static func detectMucusPeak(_ dayLogs: [DayLogInput]) -> String? {
        let peaks = dayLogs
            .filter { $0.cervicalMucus == .eggWhite || $0.cervicalMucus == .watery }
            .map(\.date)
            .sorted { dayDiff($0, $1) < 0 }
        return peaks.last
    }

    /// §4.2 symptothermal confirmation: temp-shift + mucus-peak agree within
    /// ±2 days (`confirmSymptothermal`).
    static func confirmSymptothermal(_ dayLogs: [DayLogInput], tuning: Tuning) -> String? {
        guard let shift = detectTempShift(dayLogs, thresholdC: tuning.tempShiftCManual),
              let peak = detectMucusPeak(dayLogs) else { return nil }
        if abs(dayDiff(shift, peak)) <= tuning.symptothermalAgreeDays {
            return shift
        }
        return nil
    }

    /// §4.3 passive TEMPERATURE_TREND: 3-of-4 nights ≥ +0.15°C above the
    /// trailing 6-night mean (`detectTemperatureTrend`).
    static func detectTemperatureTrend(_ nights: [NightlyTempInput], tuning: Tuning) -> String? {
        let series = nights.sorted { dayDiff($0.date, $1.date) < 0 }
        guard series.count >= 10 else { return nil }
        var i = 6
        while i + 3 < series.count {
            let trailing = series[(i - 6) ..< i]
            let mean = trailing.reduce(0.0) { $0 + $1.valueC } / Double(trailing.count)
            let window = Array(series[i ..< (i + 4)])
            let elevated = window.filter { roundHalf($0.valueC - mean, 2) >= tuning.tempShiftCPassive }.count
            if elevated >= 3 {
                return addDays(window[0].date, -1)
            }
            i += 1
        }
        return nil
    }

    // MARK: - §3 confidence factors

    /// §3(b) cycle-count factor (`countFactor`).
    static func countFactor(_ cyclesObserved: Int) -> Double {
        if cyclesObserved <= 0 { return 0.2 }
        if cyclesObserved == 1 { return 0.35 }
        if cyclesObserved == 2 { return 0.55 }
        if cyclesObserved <= 5 { return 0.75 }
        return 1.0
    }

    /// §3(b) regularity factor from the coefficient of robust variation (`varianceFactor`).
    static func varianceFactor(_ cv: Double) -> Double {
        if cv <= 0.05 { return 1.0 }
        if cv <= 0.09 { return 0.85 }
        if cv <= 0.14 { return 0.65 }
        if cv <= 0.2 { return 0.45 }
        return 0.25
    }

    /// §3 logging-density factors (`adherenceFactors`).
    static func adherenceFactors(
        lastStart: String,
        estimatedLength: Double,
        dayLogs: [DayLogInput],
        today: String,
        tuning: Tuning
    ) -> (cAdherence: Double, logSparsity: Double) {
        let sinceStart = max(0, dayDiff(today, lastStart))
        // A360-5 M-3 — clamp the value itself to ≥ 1. On the cycle-start day
        // (`sinceStart == 0`) the old `min(0, …)` resolved 0, and although the
        // density division below guards with `max(1, …)`, the loop filter
        // (`offset > expectedDays`) used the un-clamped 0 → day-0 observations
        // were excluded and a NaN could surface at the call-site. Clamping here
        // fixes both the filter window and the division denominator.
        let expectedDays = max(1, min(sinceStart, Int(roundHalf(estimatedLength))))
        var loggedDays = 0
        for log in dayLogs {
            let offset = dayDiff(log.date, lastStart)
            if offset < 0 || offset > expectedDays { continue }
            let hasObservation = log.flow != nil || log.basalBodyTempC != nil
                || log.ovulationTest != nil || log.cervicalMucus != nil
            if hasObservation { loggedDays += 1 }
        }
        let density = clamp(Double(loggedDays) / Double(max(1, expectedDays)), 0, 1)
        let cAdherence = tuning.adherenceFloor + tuning.adherenceSlope * density
        let logSparsity = (1 - density) * tuning.logSparsityScale
        return (cAdherence, logSparsity)
    }

    /// §3 confidence → label (`confidenceLabel`).
    static func confidenceLabel(_ confidence: Double, tuning: Tuning) -> ConfidenceLabel {
        if confidence < tuning.confidenceLabelLowMax { return .low }
        if confidence > tuning.confidenceLabelHighMin { return .high }
        return .medium
    }

    // MARK: - Public API — predictCycle (1:1 server parity)

    /// §1–§5 — compute the cycle prediction. Pure + deterministic. The fertile
    /// window is ALWAYS returned; goal-gating (hiding it for non-conception
    /// goals) is the caller's responsibility (mirrors the server).
    ///
    /// - Parameters:
    ///   - cycles: confirmed (non-predicted) cycles; order-independent.
    ///   - dayLogs: all day logs the device holds (period + symptothermal).
    ///   - profile: user priors + mode flags.
    ///   - today: `YYYY-MM-DD` reference day (adherence density / window scoping).
    ///   - nights: optional nightly passive-temperature series.
    /// - Returns: the materialised prediction (never nil — falls back to priors).
    public static func predictCycle(
        cycles: [CycleInput],
        dayLogs: [DayLogInput] = [],
        profile: CycleProfileInput = CycleProfileInput(),
        today: String,
        nights: [NightlyTempInput] = [],
        tuning: Tuning = .default
    ) -> Prediction {
        let lengths = completedLengths(cycles)
        let lutealLength = resolveLuteal(profile, tuning: tuning)
        let sortedStarts = cycles.map(\.startDate).sorted { dayDiff($0, $1) < 0 }
        let lastConfirmedStart = sortedStarts.last ?? today

        // -------- 0-cycle priors-only cold start (§5) --------
        if lengths.isEmpty {
            let estLen = profile.typicalCycleLength ?? tuning.populationDefaultCycle
            let periodLen = clampInt(
                Int(roundHalf(Double(profile.typicalPeriodLength ?? tuning.populationDefaultPeriod))),
                tuning.periodMin, tuning.periodMax
            )
            let nextStart = addDays(lastConfirmedStart, estLen)
            let predictedOvulation = addDays(nextStart, -lutealLength)
            return finalize(
                method: .calendar,
                nextStart: nextStart,
                halfWidth: tuning.priorsOnlyHalfWidth,
                predictedPeriodLength: periodLen,
                predictedOvulation: predictedOvulation,
                ovulationConfirmed: false,
                confidence: 0.2,
                cyclesObserved: 0,
                estimatedCycleLength: estLen,
                estimatedCycleSd: tuning.sigmaFloor,
                tuning: tuning
            )
        }

        // -------- robust estimation (§1, §2) --------
        let est = estimateCycleLength(lengths, goal: profile.goal, tuning: tuning)
        let periodLen = estimatePeriodLength(cycles, dayLogs: dayLogs, profile: profile, tuning: tuning)

        // -------- calendar baseline next-period point estimate (§1) --------
        var method: PredictionMethod = .calendar
        var nextStart = addDays(lastConfirmedStart, est.lengthRounded)
        var predictedOvulation = addDays(nextStart, -lutealLength)
        var ovulationConfirmed = false
        var confirmMultiplier = 1.0

        // -------- §4 method ladder + blend (confirmed-current overrides) --------
        let windowStart = addDays(lastConfirmedStart, -tuning.bbtWindow)
        let isInCurrentWindow: (String) -> Bool = { date in
            dayDiff(date, windowStart) >= 0 && dayDiff(today, date) >= 0
        }
        let currentDayLogs = dayLogs.filter { isInCurrentWindow($0.date) }
        let currentNights = nights.filter { isInCurrentWindow($0.date) }
        let symptoOvulation = confirmSymptothermal(currentDayLogs, tuning: tuning)
        let trendOvulation = symptoOvulation != nil ? nil : detectTemperatureTrend(currentNights, tuning: tuning)

        if let sympto = symptoOvulation {
            let confirmedNextStart = addDays(sympto, lutealLength)
            if dayDiff(confirmedNextStart, today) >= 0 {
                predictedOvulation = sympto
                nextStart = confirmedNextStart
                ovulationConfirmed = true
                confirmMultiplier = tuning.halfWidthMultSymptothermal
                // parity note §1: BLENDED when prior history exists, else bare.
                method = lengths.isEmpty ? .symptothermal : .blended
            }
        } else if let trend = trendOvulation {
            let confirmedNextStart = addDays(trend, lutealLength)
            if dayDiff(confirmedNextStart, today) >= 0 {
                predictedOvulation = trend
                nextStart = confirmedNextStart
                ovulationConfirmed = true
                confirmMultiplier = tuning.halfWidthMultTempTrend
                method = lengths.isEmpty ? .temperatureTrend : .blended
            }
        }

        // -------- §3 band half-width --------
        let (cAdherence, logSparsity) = adherenceFactors(
            lastStart: lastConfirmedStart,
            estimatedLength: est.lengthFractional,
            dayLogs: dayLogs,
            today: today,
            tuning: tuning
        )
        let adherencePenalty = 1 + logSparsity
        // parity note §3: round raw band → × confirm factor → + cold-start bonus
        // → round → clamp. Match this order or drift a day on edge cases.
        var halfWidth = roundHalf(tuning.zBand * est.sigma * adherencePenalty) * confirmMultiplier
        if est.cyclesObserved == 1 { halfWidth += Double(tuning.coldStartBandBonus) }
        let halfWidthClamped = clampInt(Int(roundHalf(halfWidth)), tuning.halfWidthMin, tuning.halfWidthMax)

        // -------- §3 confidence scalar --------
        let cCount = countFactor(est.cyclesObserved)
        let cVariance = varianceFactor(est.cv)
        let confidence = clamp(cCount * cVariance * cAdherence, tuning.confidenceMin, tuning.confidenceMax)

        return finalize(
            method: method,
            nextStart: nextStart,
            halfWidth: halfWidthClamped,
            predictedPeriodLength: periodLen,
            predictedOvulation: predictedOvulation,
            ovulationConfirmed: ovulationConfirmed,
            confidence: confidence,
            cyclesObserved: est.cyclesObserved,
            estimatedCycleLength: est.lengthRounded,
            estimatedCycleSd: roundHalf(est.sigma, 2),
            tuning: tuning
        )
    }

    /// Assemble the result, deriving the band + fertile window (`finalize`).
    private static func finalize(
        method: PredictionMethod,
        nextStart: String,
        halfWidth: Int,
        predictedPeriodLength: Int,
        predictedOvulation: String,
        ovulationConfirmed: Bool,
        confidence: Double,
        cyclesObserved: Int,
        estimatedCycleLength: Int,
        estimatedCycleSd: Double,
        tuning: Tuning
    ) -> Prediction {
        let hw = clampInt(halfWidth, tuning.halfWidthMin, tuning.halfWidthMax)
        let conf = roundHalf(confidence, 2)
        return Prediction(
            method: method,
            nextPeriodStart: nextStart,
            nextPeriodStartLow: addDays(nextStart, -hw),
            nextPeriodStartHigh: addDays(nextStart, hw),
            predictedPeriodLength: predictedPeriodLength,
            fertileWindowStart: addDays(predictedOvulation, -tuning.fertilePre),
            fertileWindowEnd: addDays(predictedOvulation, tuning.fertilePost),
            predictedOvulation: predictedOvulation,
            ovulationConfirmed: ovulationConfirmed,
            confidence: conf,
            confidenceLabel: confidenceLabel(conf, tuning: tuning),
            cyclesObserved: cyclesObserved,
            stillLearning: cyclesObserved < 3,
            estimatedCycleLength: estimatedCycleLength,
            estimatedCycleSd: estimatedCycleSd
        )
    }
}
