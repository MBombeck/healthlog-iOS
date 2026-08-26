import AppIntents
import Foundation

/// **v0.7.1 W-APPINTENTS** — shared, localized result dialogs for the
/// HealthLog App Intents. Centralised so the three intents speak with
/// one voice and the strings live in a single place for the xcstrings
/// catalogue.
enum IntentCopy {
    /// User is not signed in — the write would 401, so we ask them to
    /// open the app and sign in rather than firing a doomed request.
    static var signInRequired: IntentDialog {
        IntentDialog(
            LocalizedStringResource(
                "Open HealthLog and sign in first, then try again.",
                comment: "AppIntents — not signed in"
            )
        )
    }

    /// Network error on a retriable write — the value is safely on the
    /// Outbox and will sync on the next app foreground. Reassures the
    /// user the entry is saved, not lost.
    static var queuedOffline: IntentDialog {
        IntentDialog(
            LocalizedStringResource(
                "Saved offline — it will sync the next time you open HealthLog.",
                comment: "AppIntents — write queued on the outbox"
            )
        )
    }

    /// Non-retriable failure — the server rejected the write. Generic
    /// copy; the user can retry from inside the app.
    static var writeFailed: IntentDialog {
        IntentDialog(
            LocalizedStringResource(
                "Couldn't save that right now. Please try again in the app.",
                comment: "AppIntents — non-retriable write failure"
            )
        )
    }

    /// **v0.8.4 WWIDGET-3** — the "next dose – taken" control fired but the
    /// App Group snapshot has no due dose (nothing scheduled in-window /
    /// everything already taken). Reassures the user there was nothing to do.
    static var noDoseDue: IntentDialog {
        IntentDialog(
            LocalizedStringResource(
                "No dose is due right now.",
                comment: "AppIntents — next-dose control fired with no due dose"
            )
        )
    }

    /// Blood-pressure systolic ≤ diastolic — a transposed entry.
    static var bpOrderInvalid: LocalizedStringResource {
        LocalizedStringResource(
            "Systolic must be higher than diastolic. Please check the values.",
            comment: "AppIntents — BP order validation"
        )
    }

    /// **v0.15 W-SIRI** — the generic log-measurement intent received a value
    /// outside the kind's plausible range (a transposed / fat-fingered entry).
    static var measurementOutOfRange: LocalizedStringResource {
        LocalizedStringResource(
            "intents.logMeasurement.outOfRange",
            defaultValue: "That value looks out of range. Please check it and try again.",
            comment: "AppIntents — generic measurement value failed the plausibility range"
        )
    }
}
