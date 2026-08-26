@testable import HealthLog
import Testing

/// v1.21.0 gap-driver surfacing: the `IllnessVitalLabel` helper that the
/// recovery-gap + insights captions use to NAME the server's `gapDriverType`.
/// Locks the known-vital mappings, the new `FUNCTIONAL_IMPACT` symptom case,
/// and the forward-compat fallback for an unknown driver string.
@Suite("Illness gap-driver label")
struct IllnessGapDriverLabelTests {
    @Test("Known vitals resolve to their localized label")
    func knownVitals() {
        #expect(IllnessVitalLabel.label(for: "RESTING_HEART_RATE")
            == String(localized: "illness.vital.restingHeartRate"))
        #expect(IllnessVitalLabel.label(for: "HEART_RATE_VARIABILITY")
            == String(localized: "illness.vital.hrv"))
        #expect(IllnessVitalLabel.label(for: "OXYGEN_SATURATION")
            == String(localized: "illness.vital.spo2"))
    }

    @Test("FUNCTIONAL_IMPACT resolves to the symptom label")
    func functionalImpactDriver() {
        #expect(IllnessVitalLabel.label(for: "FUNCTIONAL_IMPACT")
            == String(localized: "illness.vital.functionalImpact"))
    }

    @Test("An unknown driver string falls back to a title-cased rendering")
    func unknownDriverFallback() {
        #expect(IllnessVitalLabel.label(for: "SOME_FUTURE_METRIC") == "Some Future Metric")
    }
}
