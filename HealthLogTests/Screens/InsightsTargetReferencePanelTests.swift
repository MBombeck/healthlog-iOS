@testable import HealthLog
import Testing

/// v0.11 W-B — contract tests for the inline per-metric target reference panel
/// (the iOS twin of the web `MetricTargetSummary`) and its contextual band
/// editor. Pins the two pure mappings the panel + ChartDetailScreen join on:
///
///   • `MetricChartMath.targetType(for:)` — `MetricKind` → server target type;
///   • `InsightsTargetBandEditorSheet.editableMetrics(forTargetType:)` — target
///     type → the editable `ThresholdMetric`(s) (BP fans out to sys + dia;
///     derived targets resolve to an empty list so no dead "adjust" button
///     renders).
@Suite("Insights target reference panel — kind ⇄ target ⇄ editor mappings")
struct InsightsTargetReferencePanelTests {
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

    @Test("Metrics without a configured target type resolve to nil (panel self-suppresses)")
    func kindWithoutTargetIsNil() {
        // Glucose / temperature etc. have no numeric target on the tile path;
        // the inline panel must render nothing for them.
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

    /// #51 — the editor-sheet title MUST be the LOCALIZED `kind.displayName`
    /// (descriptor route, `Measurement.swift:240`), NOT the server
    /// `TargetItem.label` (an English wire string, `InsightsTargetsDTO.swift:46`).
    /// The operator saw "Blood Pressure" on a German device because the call
    /// site passed `target.label`. Both call sites now title via the kind: the
    /// metric page passes `kind.displayName` directly; the inline panel maps the
    /// server target type back to its kind via `titleKind(forTargetType:)`.
    @Test("Editor title resolves to the localized kind display name, not the server label")
    func editorTitleUsesLocalizedKindDisplayName() {
        // BP — the explicit operator gripe.
        let bpKind = InsightsTargetBandEditorSheet.titleKind(forTargetType: "BLOOD_PRESSURE")
        #expect(bpKind == .bloodPressure)
        // The title comes from the localized descriptor route, NOT the raw
        // server wire constant. `displayName` resolves through the xcstrings
        // catalog ("Blood pressure" / "Blutdruck"), never the verbatim
        // server-English "Blood Pressure" label.
        #expect(bpKind?.displayName == MetricKind.bloodPressure.displayName)
        #expect(bpKind?.displayName != "Blood Pressure")

        // The other editable target types each own a single kind whose
        // localized display name titles the sheet.
        #expect(InsightsTargetBandEditorSheet.titleKind(forTargetType: "WEIGHT") == .weight)
        #expect(InsightsTargetBandEditorSheet.titleKind(forTargetType: "PULSE") == .pulse)
        #expect(InsightsTargetBandEditorSheet.titleKind(forTargetType: "RESTING_HR") == .restingHeartRate)
        #expect(InsightsTargetBandEditorSheet.titleKind(forTargetType: "ACTIVITY_STEPS") == .steps)
        #expect(InsightsTargetBandEditorSheet.titleKind(forTargetType: "BODY_FAT") == .bodyFat)
        #expect(InsightsTargetBandEditorSheet.titleKind(forTargetType: "SLEEP_DURATION") == .sleep)
        // Derived / non-editable types own no single kind → fall back to label.
        #expect(InsightsTargetBandEditorSheet.titleKind(forTargetType: "BMI") == nil)
    }
}
