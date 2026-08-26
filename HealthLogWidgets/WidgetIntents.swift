import AppIntents

/// **v0.8.4 WWIDGET-2 — intent builders for the interactive widgets.**
///
/// The interactive widgets fire shared App Intents (shared source membership
/// — see `project.yml`) whose `perform()` resolves the full server-first
/// repository stack via `IntentDependencies` inside the extension process
/// using the shared Keychain token, so a tap records exactly the way the
/// in-app surfaces do — no parallel write path. This enum is the single
/// construction site so the widget views stay declarative.
///
/// **v0.10.0 W-Widget-2Tap note:** the next-dose widget's "Genommen" button
/// no longer builds a one-shot `MarkMedicationTakenIntent` here — it fires the
/// dedicated two-step ``MarkNextDoseFromWidgetIntent`` directly (constructed at
/// the call site with the dose's slot instant) so its anti-accidental
/// arm/commit state machine stays self-contained, mirroring the Live Activity.
enum WidgetIntents {
    /// **v0.10.0 W-Mood-B** — build a `LogMoodIntent` for a tapped mood-widget
    /// face button. The intent writes through the same server-first
    /// `MoodRepository.log` path the in-app picker + Siri use — no parallel
    /// write path. `score` is a 1…5 HealthLog level.
    static func logMood(score: Int) -> LogMoodIntent {
        let intent = LogMoodIntent()
        intent.level = MoodLevelAppEnum(score: score)
        return intent
    }
}
