import SwiftUI
import WidgetKit

/// **HealthLog widget-extension bundle.**
///
/// The single `@main` entry for the `dev.healthlog.app.widgets` extension.
/// Today it vends only the medication-reminder Live Activity
/// (``MedicationLiveActivityWidget``). The structure is deliberately a
/// `WidgetBundle` so the sibling waves (interactive Home/Lock-Screen
/// widgets, a `ControlWidget` for Control Center / Action Button, StandBy
/// rendering) drop in as additional entries here with no target-level
/// rework — that is the whole point of landing the extension foundation
/// now.
@main
struct HealthLogWidgetsBundle: WidgetBundle {
    var body: some Widget {
        // ActivityKit ships on every iOS 18 device (our floor), so the
        // Live Activity widget is always part of the bundle — no
        // availability gate needed, which also keeps the
        // `@WidgetBundleBuilder` body non-empty.
        MedicationLiveActivityWidget()
        // #190 — the Activity the push relay starts and updates.
        RelayDoseLiveActivityWidget()
        // Interactive Home / Lock-Screen widgets.
        // Both paint from the App Group snapshot the app writes
        // (`WidgetSnapshotWriter`); the next-dose widget carries an
        // inline `MarkMedicationTakenIntent` button on the Home sizes.
        NextDoseWidget()
        ComplianceWidget()
        // iOS 18 Controls (Control Center / Lock Screen /
        // Action Button). `CaptureControl` opens the capture flow
        // (`OpenCaptureIntent`, opensApp); `MarkNextDoseControl` one-tap marks
        // the next due dose taken (`MarkNextDoseTakenIntent`, reading the
        // shared snapshot). `ControlWidget` is iOS 18 — our floor — so no
        // availability gate is needed.
        CaptureControl()
        MarkNextDoseControl()
        // The "Stimmung erfassen" control (opens the mood
        // quick-entry sheet) + the interactive mood glance / quick-log widget.
        LogMoodControl()
        MoodWidget()
        // v0.15 companion-#3 — the Personal Health Score ring (systemSmall +
        // accessoryCircular) + the latest-measurement glance (systemSmall +
        // accessoryRectangular + accessoryInline). Both paint from the same App
        // Group snapshot the app writes (`WidgetSnapshotWriter`); no network in
        // the widget process, server values mirrored verbatim (no recompute).
        HealthScoreWidget()
        LatestMeasurementWidget()
    }
}
