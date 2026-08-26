// swiftlint:disable large_tuple
// The tuple budget is intentionally relaxed for this file: the phase API
// returns a (phase, dayOfCycle) tuple to mirror the server's `phaseForDay`
// return shape, and the daily series rows carry (date, phase, dayOfCycle).

import Foundation

/// Phase assignment (mirrors phase.ts) + the BBT °F → °C boundary conversion —
/// moved verbatim out of `CyclePredictionEngine.swift` so the engine file
/// stays under SwiftLint's `file_length` ceiling (pure code movement, no
/// behavior change).
public extension CyclePredictionEngine {
    // MARK: - Phase assignment (mirrors phase.ts)

    /// A resolved cycle window the phase mapper needs (`PhaseCycle`).
    struct PhaseCycle: Sendable, Equatable {
        public var startDate: String
        public var nextStart: String
        public var ovulationDate: String?
        public var periodLength: Int?
        public var lutealLength: Int?

        public init(
            startDate: String,
            nextStart: String,
            ovulationDate: String? = nil,
            periodLength: Int? = nil,
            lutealLength: Int? = nil
        ) {
            self.startDate = startDate
            self.nextStart = nextStart
            self.ovulationDate = ovulationDate
            self.periodLength = periodLength
            self.lutealLength = lutealLength
        }
    }

    /// Map a date to its phase within a cycle + the 1-based day-of-cycle
    /// (`phaseForDay`). Returns `(nil, nil)` when outside `[start, nextStart)`.
    ///
    /// Boundaries (parity with phase.ts):
    /// - MENSTRUAL = [0, P̂−1]; OVULATORY = [ov−1, ov+1]; FOLLICULAR = after
    ///   menstrual before ovulatory; LUTEAL = after ovulatory to day before next.
    /// - Precedence MENSTRUAL > OVULATORY > FOLLICULAR/LUTEAL (bleeding wins).
    static func phaseForDay(
        _ date: String,
        cycle: PhaseCycle,
        tuning: Tuning = .default
    ) -> (phase: CyclePhase?, dayOfCycle: Int?) {
        let offsetFromStart = dayDiff(date, cycle.startDate)
        let cycleLength = dayDiff(cycle.nextStart, cycle.startDate)
        if offsetFromStart < 0 || offsetFromStart >= cycleLength {
            return (nil, nil)
        }
        let dayOfCycle = offsetFromStart + 1
        let periodLength = cycle.periodLength ?? tuning.populationDefaultPeriod
        let lutealLength = clampLuteal(cycle.lutealLength ?? tuning.lutealDefault, tuning: tuning)
        let ovulationDate = cycle.ovulationDate
            ?? addDays(cycle.startDate, cycleLength - lutealLength)
        let menstrualEnd = periodLength - 1
        let ovulationOffset = dayDiff(ovulationDate, cycle.startDate)
        let ovulatoryStart = ovulationOffset - 1
        let ovulatoryEnd = ovulationOffset + 1

        if offsetFromStart <= menstrualEnd {
            return (.menstrual, dayOfCycle)
        }
        if offsetFromStart >= ovulatoryStart, offsetFromStart <= ovulatoryEnd {
            return (.ovulatory, dayOfCycle)
        }
        if offsetFromStart < ovulatoryStart {
            return (.follicular, dayOfCycle)
        }
        return (.luteal, dayOfCycle)
    }

    /// Daily phase series across `[from, to]` inclusive for a single cycle
    /// (`phaseSeries`). Days outside the window carry `phase: nil`.
    static func phaseSeries(
        from: String,
        to: String,
        cycle: PhaseCycle,
        tuning: Tuning = .default
    ) -> [(date: String, phase: CyclePhase?, dayOfCycle: Int?)] {
        let span = dayDiff(to, from)
        var out: [(date: String, phase: CyclePhase?, dayOfCycle: Int?)] = []
        guard span >= 0 else { return out }
        for i in 0 ... span {
            let date = addDays(from, i)
            let r = phaseForDay(date, cycle: cycle, tuning: tuning)
            out.append((date, r.phase, r.dayOfCycle))
        }
        return out
    }

    // MARK: - BBT °F → °C conversion (server contract: round 2dp BEFORE any rule)

    /// Convert °F → °C `(F-32)/1.8` rounded to 2 dp BEFORE any rule consumes it
    /// (server contract §7 / parity note). Use this at the HealthKit/manual
    /// ingestion boundary so `DayLogInput.basalBodyTempC` is always 2-dp °C.
    static func fahrenheitToCelsius2dp(_ f: Double) -> Double {
        roundHalf((f - 32) / 1.8, 2)
    }
}

// swiftlint:enable large_tuple
