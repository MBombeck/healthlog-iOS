import AppIntents
import Foundation

/// **v0.8.4 WWIDGET-3** — "Erfassen" control / Action-Button intent.
///
/// Bound to the Control Center / Lock-Screen / Action-Button "Erfassen"
/// control (``CaptureControl``). Runs with `openAppWhenRun = true`, so a tap
/// brings HealthLog to the foreground and routes straight into the capture
/// flow — the jump-to-logging affordance the operator wanted from the
/// hardware button.
///
/// **Hand-off, not composition root:** the intent does *not* stand up the
/// `AppRouter` (consistent with `IntentDependencies`' rationale — the App
/// Intents context isn't the place to build app state). It drops a tiny
/// one-shot marker into the shared App Group via ``CaptureRequestStore``;
/// the app consumes it on its next foreground tick (`RootView`) and flips to
/// the capture surface. Works whether the control cold-launches the app or
/// foregrounds an already-running instance.
struct OpenCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture a health entry"

    static let description = IntentDescription(
        "Opens HealthLog and jumps straight to logging a new entry."
    )

    /// Foreground the app — the capture flow is an in-app surface.
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // One-shot marker; the app picks it up on foreground. A write failure
        // is logged and swallowed — the app still foregrounds, just on its
        // last surface rather than capture, which is a safe degrade.
        do {
            try CaptureRequestStore().write()
        } catch {
            HLLog.notifications.error(
                "capture-request write failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
            )
        }
        return .result()
    }
}
