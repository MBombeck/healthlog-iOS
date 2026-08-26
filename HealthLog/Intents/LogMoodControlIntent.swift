import AppIntents
import Foundation

/// **v0.10.0 W-Mood-B** — "Stimmung erfassen" control / Action-Button intent.
///
/// Bound to the Control Center / Lock-Screen / Action-Button mood control
/// (``LogMoodControl``). Runs with `openAppWhenRun = true`, so a tap brings
/// HealthLog to the foreground and routes straight to the mood quick-entry
/// sheet — a one-press "how am I right now" ritual tile.
///
/// **Hand-off, not composition root:** like ``OpenCaptureIntent``, the intent
/// does *not* stand up the `AppRouter` (the App Intents context isn't the
/// place to build app state). It drops a tiny one-shot marker into the shared
/// App Group via ``CaptureRequestStore`` — tagged `.mood` — and the app
/// consumes it on its next foreground tick (`RootView`) and presents the mood
/// quick-entry sheet via `router.requestMoodQuickEntry()`. Works whether the
/// control cold-launches the app or foregrounds an already-running instance.
///
/// A pure deep-link launcher (no silent write) — the actual mood level is
/// picked in the sheet. The voice/Shortcut fast-log lives in
/// ``LogMoodIntent``; this is the second, hardware/Control-Center route to the
/// same action (Apple's own model is intent + control + widget all reaching
/// one action — we ship exactly one mood control, no per-level proliferation).
struct LogMoodControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Log mood"

    static let description = IntentDescription(
        "Opens HealthLog and jumps straight to logging your mood."
    )

    /// Foreground the app — the mood quick-entry sheet is an in-app surface.
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // One-shot marker; the app picks it up on foreground. A write failure
        // is logged and swallowed — the app still foregrounds, just on its
        // last surface rather than the mood sheet, which is a safe degrade.
        do {
            try CaptureRequestStore().write(
                .init(requestedAt: .now, surface: .mood)
            )
        } catch {
            HLLog.notifications.error(
                "mood-control request write failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
            )
        }
        return .result()
    }
}
