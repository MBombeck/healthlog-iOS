import AppIntents

/// Exposes the HealthLog App Intents to Siri,
/// Spotlight, and the Shortcuts app.
///
/// `AppShortcutsProvider` is the system entry point: iOS reads
/// `appShortcuts` at install/first-launch to register the trigger
/// phrases. Each `AppShortcut` lists the invocation phrases users can
/// speak to Siri; the `\(.applicationName)` token is required by the
/// framework and resolves to the app's display name.
///
/// Phrases are localized only through `Resources/AppShortcuts.xcstrings`
/// (key = the English phrase with `${applicationName}` / `${parameter}`
/// tokens); Siri never reads them from `Localizable.xcstrings`. Short titles
/// stay in `Localizable`. `AppShortcutPhraseCatalogTests` keeps code and
/// catalog in step.
struct HealthLogAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogBloodGlucoseIntent(),
            phrases: [
                "Log blood glucose in \(.applicationName)",
                "Record my blood sugar in \(.applicationName)",
                "Add a glucose reading to \(.applicationName)",
                "Log my blood sugar with \(.applicationName)"
            ],
            shortTitle: "Log blood glucose",
            systemImageName: "drop.fill"
        )
        // The generic scalar-measurement write intent. Closes
        // the voice/Shortcut gap for every hand-logged scalar metric (weight,
        // pulse, body temperature, SpO₂, respiratory rate, body fat) that had
        // no dedicated intent. The `\(\.$kind)` token lets Siri / Shortcuts
        // fill the metric, `\(\.$value)` the reading. EN + DE phrasings both
        // register via the xcstrings catalogue.
        AppShortcut(
            intent: LogMeasurementIntent(),
            phrases: [
                "Log a measurement in \(.applicationName)",
                "Record a measurement in \(.applicationName)",
                "Log \(\.$kind) in \(.applicationName)",
                "Add a \(\.$kind) reading to \(.applicationName)",
                "Log my weight in \(.applicationName)"
            ],
            shortTitle: "Log a measurement",
            systemImageName: "square.and.pencil"
        )
        // A value for one of the
        // person's own metrics. `\(\.$metric)` lets Siri fill the metric by
        // name from `CustomMetricEntityQuery`.
        AppShortcut(
            intent: LogCustomMetricValueIntent(),
            phrases: [
                "Log a value in \(.applicationName)",
                "Log \(\.$metric) in \(.applicationName)",
                "Add a value to \(\.$metric) in \(.applicationName)"
            ],
            shortTitle: "Log a value",
            systemImageName: "slider.horizontal.3"
        )
        AppShortcut(
            intent: LogBloodPressureIntent(),
            phrases: [
                "Log blood pressure in \(.applicationName)",
                "Record my blood pressure in \(.applicationName)",
                "Add a blood pressure reading to \(.applicationName)"
            ],
            shortTitle: "Log blood pressure",
            systemImageName: "heart.fill"
        )
        // The mood-log write intent. The lowest-friction
        // entry in the app: a one-second voice/Shortcut log. Natural "log my
        // mood" phrasings register for Siri + Spotlight; EN + DE phrasings
        // both register via the xcstrings catalogue.
        AppShortcut(
            intent: LogMoodIntent(),
            phrases: [
                "Log my mood in \(.applicationName)",
                "Record how I feel in \(.applicationName)",
                "Add a mood entry to \(.applicationName)",
                "How am I feeling in \(.applicationName)"
            ],
            shortTitle: "Log mood",
            systemImageName: "face.smiling"
        )
        AppShortcut(
            intent: MarkMedicationTakenIntent(),
            phrases: [
                "Mark medication taken in \(.applicationName)",
                "I took my medication in \(.applicationName)",
                "Log a dose in \(.applicationName)"
            ],
            shortTitle: "Mark medication taken",
            systemImageName: "pills.fill"
        )
        // The compliance READ intent. The first read /
        // query intent in the surface (the others are all writes). Natural
        // "did I take my meds today?" phrasings register for Siri + Spotlight;
        // the intent is `isDiscoverable` so Spotlight can surface it as an
        // action. EN + DE phrasings both register via the xcstrings catalogue.
        AppShortcut(
            intent: MedicationComplianceQueryIntent(),
            phrases: [
                "Did I take my medication today in \(.applicationName)",
                "Show my adherence in \(.applicationName)",
                "Have I taken my meds in \(.applicationName)",
                "Check my medication compliance in \(.applicationName)",
                "What's my adherence rate in \(.applicationName)"
            ],
            shortTitle: "Check today’s adherence",
            systemImageName: "checklist"
        )
        // The per-medication READ intent ("Did I take
        // Lisinopril?"). The compliance query above answers the AGGREGATE
        // ("X of Y doses today"); this one answers about ONE medication by
        // name. `isDiscoverable` so Spotlight can surface it as an action.
        // EN + DE phrasings both register via the xcstrings catalogue; the
        // `\(\.$medication)` token lets Siri / Shortcuts fill the med name.
        AppShortcut(
            intent: DidITakeMedicationIntent(),
            phrases: [
                "Did I take my \(\.$medication) in \(.applicationName)",
                "Have I taken \(\.$medication) in \(.applicationName)",
                "Check if I took \(\.$medication) in \(.applicationName)",
                "Did I take my \(\.$medication) today in \(.applicationName)"
            ],
            shortTitle: "Did I take this medication?",
            systemImageName: "checkmark.seal"
        )
    }
}
