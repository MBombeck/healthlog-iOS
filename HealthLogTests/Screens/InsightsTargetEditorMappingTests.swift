@testable import HealthLog
import Testing

/// v0.11 W-B — contract tests for the per-metric target band editor and the
/// target payload it edits. Pins the two pure mappings the metric page joins on:
///
///   • `MetricChartMath.targetType(for:)` — `MetricKind` → server target type;
///   • `InsightsTargetBandEditorSheet.editableMetrics(forTargetType:)` — target
///     type → the editable `ThresholdMetric`(s) (BP fans out to sys + dia;
///     derived targets resolve to an empty list so no dead "adjust" button
///     renders).
///
/// 1.4 B4 — the inline target reference panel these mappings were first written
/// for had no caller and was deleted, together with its `titleKind(forTargetType:)`
/// title lookup; both mappings below stay live on `InsightsMetricScreen`.
@Suite("Insights target editor — kind ⇄ target ⇄ editor mappings")
struct InsightsTargetEditorMappingTests {
    @Test("MetricKind maps to the server target type the targets payload keys on")
    func kindToTargetType() {
        #expect(MetricChartMath.targetType(for: .weight) == "WEIGHT")
        #expect(MetricChartMath.targetType(for: .pulse) == "PULSE")
        #expect(MetricChartMath.targetType(for: .restingHeartRate) == "RESTING_HR")
        #expect(MetricChartMath.targetType(for: .steps) == "ACTIVITY_STEPS")
        #expect(MetricChartMath.targetType(for: .bodyFat) == "BODY_FAT")
        #expect(MetricChartMath.targetType(for: .sleep) == "SLEEP_DURATION")
        #expect(MetricChartMath.targetType(for: .bloodPressure) == "BLOOD_PRESSURE")
    }

    @Test("Metrics without a configured target type resolve to nil")
    func kindWithoutTargetIsNil() {
        // Glucose / temperature etc. have no numeric target on the tile path;
        // the metric page shows no target band for them.
        #expect(MetricChartMath.targetType(for: .glucose) == nil)
        #expect(MetricChartMath.targetType(for: .bodyTemperature) == nil)
    }

    @Test("Blood pressure fans out to the systolic + diastolic editable pair")
    func bloodPressureEditableMetrics() {
        let metrics = InsightsTargetBandEditorSheet.editableMetrics(forTargetType: "BLOOD_PRESSURE")
        #expect(metrics == [.bloodPressureSys, .bloodPressureDia])
    }

    @Test("Single-band metrics resolve to exactly one editable threshold")
    func singleBandEditableMetrics() {
        #expect(InsightsTargetBandEditorSheet.editableMetrics(forTargetType: "WEIGHT") == [.weight])
        #expect(InsightsTargetBandEditorSheet.editableMetrics(forTargetType: "PULSE") == [.pulse])
        #expect(InsightsTargetBandEditorSheet.editableMetrics(forTargetType: "RESTING_HR") == [.pulse])
        #expect(InsightsTargetBandEditorSheet.editableMetrics(forTargetType: "BODY_FAT") == [.bodyFat])
        #expect(InsightsTargetBandEditorSheet.editableMetrics(forTargetType: "SLEEP_DURATION") == [.sleepDuration])
        #expect(InsightsTargetBandEditorSheet.editableMetrics(forTargetType: "ACTIVITY_STEPS") == [.activitySteps])
    }

    @Test("Derived / non-editable targets yield no editable metrics (no dead adjust button)")
    func derivedTargetsHaveNoEditor() {
        // Mood, compliance, BMI are derived or server-computed — the adjust
        // affordance must not appear for them.
        #expect(InsightsTargetBandEditorSheet.editableMetrics(forTargetType: "MOOD_SCORE").isEmpty)
        #expect(InsightsTargetBandEditorSheet.editableMetrics(forTargetType: "MOOD_STABILITY").isEmpty)
        #expect(InsightsTargetBandEditorSheet.editableMetrics(forTargetType: "MEDICATION_COMPLIANCE").isEmpty)
        #expect(InsightsTargetBandEditorSheet.editableMetrics(forTargetType: "BMI").isEmpty)
    }
}
