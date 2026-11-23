import Foundation

/// #1343 / #191 (server 1.49.0) — the watch's own figures for one session,
/// `performance` on `GET /api/workouts/{id}`: training effect, training load,
/// recovery time, sweat loss, average power and the running dynamics.
///
/// Additive and read-only: an older server sends no key, a workout without any
/// figure sends `null`, and each figure is `null` when the watch did not
/// compute it (the server already drops implausible values,
/// `src/lib/workouts/performance-metrics.ts`). The decode never throws: a
/// figure that is not a finite number reads as absent, and a block that is not
/// an object reads as empty, so the workout always survives.
public struct WorkoutPerformanceDTO: Decodable, Sendable, Equatable {
    /// Aerobic training effect, 0 to 5.
    public let aerobicTrainingEffect: Double?
    /// Anaerobic training effect, 0 to 5.
    public let anaerobicTrainingEffect: Double?
    /// The watch's training load score.
    public let trainingLoad: Double?
    /// Minutes until the watch considers the person recovered.
    public let recoveryTimeMin: Double?
    /// Estimated sweat loss, millilitres.
    public let sweatLossMl: Double?
    /// Average power, watts.
    public let avgPowerW: Double?
    /// Running dynamics: bounce per step, millimetres.
    public let avgVerticalOscillationMm: Double?
    /// Running dynamics: ground contact time per step, milliseconds.
    public let avgGroundContactTimeMs: Double?
    /// Running dynamics: the left foot's share of ground contact, percent.
    public let avgGroundContactBalancePct: Double?

    public init(
        aerobicTrainingEffect: Double? = nil,
        anaerobicTrainingEffect: Double? = nil,
        trainingLoad: Double? = nil,
        recoveryTimeMin: Double? = nil,
        sweatLossMl: Double? = nil,
        avgPowerW: Double? = nil,
        avgVerticalOscillationMm: Double? = nil,
        avgGroundContactTimeMs: Double? = nil,
        avgGroundContactBalancePct: Double? = nil
    ) {
        self.aerobicTrainingEffect = aerobicTrainingEffect
        self.anaerobicTrainingEffect = anaerobicTrainingEffect
        self.trainingLoad = trainingLoad
        self.recoveryTimeMin = recoveryTimeMin
        self.sweatLossMl = sweatLossMl
        self.avgPowerW = avgPowerW
        self.avgVerticalOscillationMm = avgVerticalOscillationMm
        self.avgGroundContactTimeMs = avgGroundContactTimeMs
        self.avgGroundContactBalancePct = avgGroundContactBalancePct
    }

    private enum CodingKeys: String, CodingKey {
        case aerobicTrainingEffect, anaerobicTrainingEffect, trainingLoad, recoveryTimeMin
        case sweatLossMl, avgPowerW, avgVerticalOscillationMm, avgGroundContactTimeMs
        case avgGroundContactBalancePct
    }

    public init(from decoder: any Decoder) {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        func figure(_ key: CodingKeys) -> Double? {
            guard let value = try? c?.decodeIfPresent(Double.self, forKey: key), value.isFinite else { return nil }
            return value
        }
        aerobicTrainingEffect = figure(.aerobicTrainingEffect)
        anaerobicTrainingEffect = figure(.anaerobicTrainingEffect)
        trainingLoad = figure(.trainingLoad)
        recoveryTimeMin = figure(.recoveryTimeMin)
        sweatLossMl = figure(.sweatLossMl)
        avgPowerW = figure(.avgPowerW)
        avgVerticalOscillationMm = figure(.avgVerticalOscillationMm)
        avgGroundContactTimeMs = figure(.avgGroundContactTimeMs)
        avgGroundContactBalancePct = figure(.avgGroundContactBalancePct)
    }

    /// Whether any figure is there to show.
    public var hasFigures: Bool {
        [
            aerobicTrainingEffect, anaerobicTrainingEffect, trainingLoad, recoveryTimeMin, sweatLossMl,
            avgPowerW, avgVerticalOscillationMm, avgGroundContactTimeMs, avgGroundContactBalancePct
        ].contains { $0 != nil }
    }
}
