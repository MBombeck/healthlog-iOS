import AppIntents
import Foundation
import WidgetKit

/// **v0.10.0 W-Widget-2Tap — the Home-screen next-dose widget's "Genommen"
/// button.**
///
/// Mirrors the Live Activity's anti-accidental two-step confirm
/// (``MarkDoseFromLiveActivityIntent``) for a surface that has **no** running
/// Activity to hold the armed state. Where the LA reads its `Activity`'s
/// `ContentState`, this intent reads a tiny App Group marker
/// (``WidgetPendingConfirmStore``) the first tap writes:
///
/// - **FIRST tap** → ``WidgetPendingConfirmStore/arm(medicationId:scheduledFor:now:)``
///   writes the pending marker (NO intake recorded), then reloads the
///   next-dose timeline so the button re-renders as "Erneut tippen zum
///   Bestätigen". One accidental tap therefore never records a dose.
/// - **SECOND tap** (marker present + fresh) → records the intake against the
///   dose's **canonical slot instant** via the same server-first
///   `MedicationsRepository.recordFromReminder(...)` the in-app card, the
///   Live Activity, the Siri intent, and the notification action handler use
///   — idempotency-keyed, Outbox fallback on a retriable error, **no parallel
///   write path** — then clears the marker and reloads.
/// - A **stale** marker (older than the confirm window) is treated as absent
///   by both the store read and the timeline render, so the button
///   auto-reverts to the plain "Genommen".
///
/// Runs in the widget-extension process (`openAppWhenRun = false`) via the
/// shared Keychain token, exactly like the other widget intents.
struct MarkNextDoseFromWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "widget.next_dose.taken"
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Medication ID")
    var medicationId: String

    @Parameter(title: "Medication Name")
    var medicationName: String

    /// The dose's canonical scheduled instant, as a Unix epoch (seconds).
    /// The committed intake records against this so the row de-dupes onto the
    /// in-app card's `(medicationId, scheduledFor)` row.
    @Parameter(title: "Scheduled For (epoch)")
    var scheduledForEpoch: Double

    init() {}

    init(medicationId: String, medicationName: String, scheduledForEpoch: Double) {
        self.medicationId = medicationId
        self.medicationName = medicationName
        self.scheduledForEpoch = scheduledForEpoch
    }

    /// Test seam — when set, the intent uses this store instead of the live
    /// App Group container. `@MainActor`-isolated so the mutable static is
    /// concurrency-safe under Swift 6 strict concurrency (mirrors
    /// ``MarkNextDoseTakenIntent/snapshotStoreOverride``).
    @MainActor static var pendingStoreOverride: WidgetPendingConfirmStore?

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = Self.pendingStoreOverride ?? WidgetPendingConfirmStore()
        let scheduledFor = Date(timeIntervalSince1970: scheduledForEpoch)

        // Build 273 (A17) — the confirm is bound to the slot the first tap armed.
        if store.armed(for: medicationId, scheduledFor: scheduledFor) {
            // SECOND tap — the button was armed: record the intake, then clear.
            store.clear()
            await commit(scheduledFor: scheduledFor)
        } else {
            // FIRST tap — only arm the confirm state; NO intake recorded.
            try? store.arm(medicationId: medicationId, scheduledFor: scheduledFor)
        }

        // Re-render the button into its new state ("Bestätigen?" after the
        // arm, plain "Genommen" after the commit/clear).
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.nextDose)
        return .result()
    }

    /// Record the intake server-first against the slot instant — the SAME
    /// path every other "taken" surface uses. Errors are swallowed with
    /// context: retriable ones are already enqueued on the Outbox inside
    /// `recordFromReminder`; the marker is already cleared either way (the
    /// user DID confirm).
    @MainActor
    private func commit(scheduledFor: Date) async {
        let deps = IntentDependencies.resolve()
        guard IntentDependencies.isSignedIn(deps) else { return }
        do {
            try await deps.medicationsRepo.recordFromReminder(
                medicationId: medicationId,
                scheduledFor: scheduledFor,
                status: .taken
            )
        } catch {
            HLLog.notifications.error(
                "Widget mark-taken failed err=\(LogSanitizer.redact(String(describing: error)), privacy: .public)"
            )
        }
    }
}
