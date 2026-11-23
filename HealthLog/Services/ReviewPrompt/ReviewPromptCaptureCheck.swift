import Foundation

/// **Is a just-recorded value one to stay quiet after?**
///
/// Only a value checked against the user's own range and found inside it is
/// calm. Anything else is flagged: out of range, a range not known yet, and
/// every kind that has no range at all (temperature, pain, resting pulse, HRV,
/// breathing rate and the like). The app sets no medical limits of its own.
/// A low mood is flagged too.
enum ReviewPromptCaptureCheck {
    /// Moods at or below this score (1 lousy … 5 great) are not a moment to ask.
    static let lowMoodCeiling = 2

    static func isFlagged(moodScore: Int) -> Bool {
        moodScore <= lowMoodCeiling
    }

    static func isFlagged(_ measurement: Measurement, band: (ThresholdMetric) -> ThresholdRange?) -> Bool {
        guard let checks = rangeChecks(for: measurement) else { return true }
        return checks.contains { metric, value in
            guard let range = band(metric) else { return true }
            return value < range.min || value > range.max
        }
    }

    /// The values a measurement is held against, each with the range it
    /// belongs to. `nil` for kinds without a range.
    static func rangeChecks(for measurement: Measurement) -> [(ThresholdMetric, Double)]? {
        switch (measurement.kind, measurement.value) {
        case let (.bloodPressure, .bloodPressure(systolic, diastolic)):
            [(.bloodPressureSys, systolic), (.bloodPressureDia, diastolic)]
        case let (.weight, .scalar(value)):
            [(.weight, value)]
        case let (.pulse, .scalar(value)):
            [(.pulse, value)]
        case let (.glucose, .scalar(value)):
            [(glucoseMetric(for: measurement.glucoseContext), value)]
        case let (.spo2, .scalar(value)):
            [(.oxygenSaturation, percent(value))]
        case let (.bodyFat, .scalar(value)):
            [(.bodyFat, percent(value))]
        case let (.bodyWater, .scalar(value)):
            [(.totalBodyWater, value)]
        case let (.boneMass, .scalar(value)):
            [(.boneMass, value)]
        default:
            nil
        }
    }

    private static func glucoseMetric(for context: GlucoseContext?) -> ThresholdMetric {
        switch context {
        case .fasting: .bloodGlucoseFasting
        case .afterMeal: .bloodGlucosePostprandial
        case .bedtime: .bloodGlucoseBedtime
        case .random, nil: .bloodGlucoseRandom
        }
    }

    /// Percentages travel as a fraction on some paths; the ranges are in percent.
    private static func percent(_ value: Double) -> Double {
        value <= 1 ? value * 100 : value
    }
}
