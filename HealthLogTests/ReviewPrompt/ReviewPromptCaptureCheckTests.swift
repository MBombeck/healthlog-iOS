import Foundation
@testable import HealthLog
import Testing

/// Pins which just-recorded values keep the review prompt quiet.
@Suite("Review prompt capture check")
struct ReviewPromptCaptureCheckTests {
    private let ranges: [ThresholdMetric: ThresholdRange] = [
        .weight: ThresholdRange(min: 60, max: 90),
        .bloodPressureSys: ThresholdRange(min: 90, max: 135),
        .bloodPressureDia: ThresholdRange(min: 60, max: 85),
        .bloodGlucoseFasting: ThresholdRange(min: 70, max: 100),
        .bloodGlucoseRandom: ThresholdRange(min: 70, max: 140),
        .oxygenSaturation: ThresholdRange(min: 94, max: 100)
    ]

    private func measurement(
        _ kind: MetricKind,
        _ value: MeasurementValue,
        context: GlucoseContext? = nil
    ) -> HealthLog.Measurement {
        HealthLog.Measurement(
            id: "m",
            kind: kind,
            recordedAt: Date(timeIntervalSince1970: 1_800_000_000),
            value: value,
            note: nil,
            source: .manual,
            glucoseContext: context
        )
    }

    private func flagged(_ value: HealthLog.Measurement) -> Bool {
        ReviewPromptCaptureCheck.isFlagged(value) { ranges[$0] }
    }

    @Test("In range is not flagged, either side out of range is")
    func scalarRange() {
        #expect(!flagged(measurement(.weight, .scalar(75))))
        #expect(!flagged(measurement(.weight, .scalar(60))))
        #expect(flagged(measurement(.weight, .scalar(59.9))))
        #expect(flagged(measurement(.weight, .scalar(95))))
    }

    @Test("Blood pressure is flagged when either number leaves its range")
    func bloodPressure() {
        #expect(!flagged(measurement(.bloodPressure, .bloodPressure(systolic: 120, diastolic: 80))))
        #expect(flagged(measurement(.bloodPressure, .bloodPressure(systolic: 150, diastolic: 80))))
        #expect(flagged(measurement(.bloodPressure, .bloodPressure(systolic: 120, diastolic: 95))))
    }

    @Test("Glucose is held against the range of its context")
    func glucoseContext() {
        #expect(flagged(measurement(.glucose, .scalar(120), context: .fasting)))
        #expect(!flagged(measurement(.glucose, .scalar(120), context: nil)))
        #expect(!flagged(measurement(.glucose, .scalar(120), context: .random)))
    }

    @Test("A value whose range is unknown is flagged")
    func unknownRange() {
        #expect(flagged(measurement(.pulse, .scalar(70))))
        #expect(flagged(measurement(.glucose, .scalar(120), context: .afterMeal)))
    }

    @Test("Oxygen saturation reads a fraction as percent")
    func fractionAsPercent() {
        #expect(!flagged(measurement(.spo2, .scalar(0.97))))
        #expect(flagged(measurement(.spo2, .scalar(0.88))))
        #expect(!flagged(measurement(.spo2, .scalar(97))))
    }

    @Test("Body water and bone mass are held against their ranges")
    func bodyComposition() {
        let wide: (ThresholdMetric) -> ThresholdRange? = { _ in ThresholdRange(min: 1, max: 60) }
        #expect(!ReviewPromptCaptureCheck.isFlagged(measurement(.bodyWater, .scalar(40)), band: wide))
        #expect(ReviewPromptCaptureCheck.isFlagged(measurement(.bodyWater, .scalar(80)), band: wide))
        #expect(!ReviewPromptCaptureCheck.isFlagged(measurement(.boneMass, .scalar(3)), band: wide))
        #expect(ReviewPromptCaptureCheck.isFlagged(measurement(.boneMass, .scalar(0.5)), band: wide))
    }

    /// The kinds a value can be checked for. Everything else, including any
    /// kind added later, must stay flagged.
    private let checkable: Set<MetricKind> = [
        .bloodPressure, .weight, .pulse, .glucose, .spo2, .bodyFat, .bodyWater, .boneMass
    ]

    @Test("Only a checked kind inside its range is calm, every other kind is flagged")
    func everyKind() {
        let anything: (ThresholdMetric) -> ThresholdRange? = { _ in
            ThresholdRange(min: -.greatestFiniteMagnitude, max: .greatestFiniteMagnitude)
        }
        for kind in MetricKind.allCases {
            let value: MeasurementValue = kind == .bloodPressure
                ? .bloodPressure(systolic: 120, diastolic: 80)
                : .scalar(50)
            let flagged = ReviewPromptCaptureCheck.isFlagged(measurement(kind, value), band: anything)
            #expect(flagged == !checkable.contains(kind), "\(kind)")
        }
    }

    @Test("Temperature, pain, resting pulse, HRV, and breathing rate are never a moment to ask")
    func noRangeKinds() {
        for kind in [MetricKind.bodyTemperature, .painNRS, .restingHeartRate, .hrv, .respiratoryRate, .steps] {
            #expect(flagged(measurement(kind, .scalar(1))), "\(kind)")
            #expect(ReviewPromptCaptureCheck.rangeChecks(for: measurement(kind, .scalar(1))) == nil)
        }
    }

    @Test("Lousy and bad moods are flagged, okay and better are not")
    func moods() {
        #expect(ReviewPromptCaptureCheck.isFlagged(moodScore: 1))
        #expect(ReviewPromptCaptureCheck.isFlagged(moodScore: 2))
        #expect(!ReviewPromptCaptureCheck.isFlagged(moodScore: 3))
        #expect(!ReviewPromptCaptureCheck.isFlagged(moodScore: 5))
    }
}
