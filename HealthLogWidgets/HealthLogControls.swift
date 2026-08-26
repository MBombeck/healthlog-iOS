import AppIntents
import SwiftUI
import WidgetKit

/// **v0.8.4 WWIDGET-3 — iOS 18 Controls (Control Center / Lock Screen /
/// Action Button).**
///
/// Two `ControlWidget`s registered in ``HealthLogWidgetsBundle``, both riding
/// the already-shipped App Intents + App Group snapshot:
///
/// - ``CaptureControl`` — a `ControlWidgetButton` bound to ``OpenCaptureIntent``
///   (`openAppWhenRun = true`): foregrounds the app straight into the capture
///   flow. The hardware Action Button (15 Pro+/16) and Control Center get a
///   one-press jump to logging.
/// - ``MarkNextDoseControl`` — a `ControlWidgetButton` bound to
///   ``MarkNextDoseTakenIntent``: one-press "next dose taken" without leaving
///   the current surface, reading the next due dose from the shared
///   ``WidgetSnapshot`` and recording it through the same server-first path
///   as every other "Genommen" affordance.
///
/// Both use `StaticControlConfiguration` — neither needs per-instance user
/// configuration (the next-dose control resolves "next" dynamically from the
/// snapshot; capture is parameterless). Display names + SF Symbols below;
/// the EN+DE display strings live in the extension's own
/// `Localizable.xcstrings`.
struct CaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetKind.captureControl) {
            ControlWidgetButton(action: OpenCaptureIntent()) {
                Label {
                    Text("control.capture.title")
                } icon: {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
        .displayName(LocalizedStringResource("control.capture.display_name"))
        .description(LocalizedStringResource("control.capture.description"))
    }
}

struct MarkNextDoseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetKind.markNextDoseControl) {
            ControlWidgetButton(action: MarkNextDoseTakenIntent()) {
                Label {
                    Text("control.next_dose_taken.title")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
            }
            .tint(LAColor.accent)
        }
        .displayName(LocalizedStringResource("control.next_dose_taken.display_name"))
        .description(LocalizedStringResource("control.next_dose_taken.description"))
    }
}

/// **v0.10.0 W-Mood-B** — the "Stimmung erfassen" control: tap → opens the
/// app's mood quick-entry sheet (``LogMoodControlIntent``, opensApp). One
/// neutral, monochrome tile that reaches the mood picker from Control Center /
/// Lock Screen / the hardware Action Button — exactly one mood control (no
/// five-button proliferation, per the restraint guardrail).
struct LogMoodControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetKind.logMoodControl) {
            ControlWidgetButton(action: LogMoodControlIntent()) {
                Label {
                    Text("control.log_mood.title")
                } icon: {
                    Image(systemName: "face.smiling")
                }
            }
        }
        .displayName(LocalizedStringResource("control.log_mood.display_name"))
        .description(LocalizedStringResource("control.log_mood.description"))
    }
}
