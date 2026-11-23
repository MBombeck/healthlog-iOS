import AppIntents
import Foundation

/// Shared, localized result dialogs for the
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

    /// The dialog for a write the repository durably queued, chosen by
    /// why it was queued. A 429 (the server's write ceiling, with or without
    /// `record_write.rate_limited`) is not "offline": the phone is online and
    /// the entry is saved, it just waits a moment. Everything else keeps
    /// the offline dialog.
    static func queued(after error: HLError) -> IntentDialog {
        IntentDialog(queuedResource(after: error))
    }

    /// The string behind ``queued(after:)`` — split out so a test can read the key.
    static func queuedResource(after error: HLError) -> LocalizedStringResource {
        if case .rateLimited = error {
            return LocalizedStringResource(
                "intents.queued.rateLimited",
                defaultValue: "Saved. The server is busy right now, so it will sync automatically in a moment.",
                comment: "AppIntents — write queued because the server rate-limited it (HTTP 429); no action needed"
            )
        }
        // Network error on a retriable write — the value is safely on the
        // Outbox and will sync on the next app foreground.
        return LocalizedStringResource(
            "Saved offline — it will sync the next time you open HealthLog.",
            comment: "AppIntents — write queued on the outbox"
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

    /// The "next dose – taken" control fired on a snapshot the app has not
    /// refreshed for too long: its next dose may be long past.
    static var snapshotStale: IntentDialog {
        IntentDialog(
            LocalizedStringResource(
                "Your doses are out of date. Open HealthLog, then try again.",
                comment: "AppIntents — next-dose control fired on an out-of-date widget snapshot; nothing recorded"
            )
        )
    }

    /// The "next dose – taken" control fired for a dose a widget or control
    /// tap already saved.
    static var alreadyRecorded: IntentDialog {
        IntentDialog(
            LocalizedStringResource(
                "This dose is already recorded.",
                comment: "AppIntents — next-dose control fired for a dose that was already saved; nothing recorded again"
            )
        )
    }

    /// The "next dose – taken" control fired but the
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

    /// The generic log-measurement intent received a value
    /// outside the kind's plausible range (a transposed / fat-fingered entry).
    static var measurementOutOfRange: LocalizedStringResource {
        LocalizedStringResource(
            "intents.logMeasurement.outOfRange",
            defaultValue: "That value looks out of range. Please check it and try again.",
            comment: "AppIntents — generic measurement value failed the plausibility range"
        )
    }
}
