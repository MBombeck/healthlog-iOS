import AppIntents
import Foundation
import WidgetKit

/// **The Home-screen next-dose widget's "Genommen"
/// button.**
///
/// **#188 (7) — one tap.** The first tap records the intake against the
/// dose's **canonical slot instant** via the same server-first
/// `MedicationsRepository.recordFromReminder(...)` the in-app card, the Live
/// Activity, the Siri intent, and the notification action handler use
/// (idempotency-keyed, Outbox fallback on a retriable error, **no parallel
/// write path**), and notes the take in ``ExternalTakeLog`` so the next open
/// of the app offers an undo. The two-step confirm through
/// ``WidgetPendingConfirmStore`` guarded against an accidental tap that
/// nothing could undo; a marker an older build armed is simply cleared.
///
/// Runs in the widget-extension process (`openAppWhenRun = false`) via the
/// shared Keychain token, exactly like the other widget intents.
struct MarkNextDoseFromWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "med.dose.action.take"
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

    /// Test seam for the outcome marker, like ``pendingStoreOverride``.
    @MainActor static var outcomeStoreOverride: WidgetDoseOutcomeStore?

    /// Test seam for the external-take log (never the live App Group).
    @MainActor static var externalTakeLogOverride: ExternalTakeLog?

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = Self.pendingStoreOverride ?? WidgetPendingConfirmStore()
        let scheduledFor = Date(timeIntervalSince1970: scheduledForEpoch)
        store.clear()
        await commit(scheduledFor: scheduledFor)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.nextDose)
        return .result()
    }

    @MainActor
    private func commit(scheduledFor: Date) async {
        let outcomes = Self.outcomeStoreOverride ?? WidgetDoseOutcomeStore()
        let deps = IntentDependencies.resolve()
        guard IntentDependencies.isSignedIn(deps) else {
            outcomes.record(medicationId: medicationId, scheduledFor: scheduledFor, kind: .notSaved)
            return
        }
        var failure: Error?
        var receipt: ReminderIntakeReceipt?
        let idempotencyKey = IdempotencyKey()
        do {
            receipt = try await deps.medicationsRepo.recordFromReminderReturningReceipt(
                medicationId: medicationId,
                scheduledFor: scheduledFor,
                status: .taken,
                idempotencyKey: idempotencyKey
            )
        } catch {
            failure = error
            HLLog.notifications.error(
                "Widget mark-taken failed err=\(LogSanitizer.redact(String(describing: error)), privacy: .public)"
            )
        }
        let kind = WidgetDoseOutcomeStore.kind(signedIn: true, error: failure)
        outcomes.record(medicationId: medicationId, scheduledFor: scheduledFor, kind: kind)
        // R1 (1): only the row this tap wrote is offered for undo; a slot
        // taken already (`alreadyTaken`) belongs to someone else.
        (Self.externalTakeLogOverride ?? ExternalTakeLog()).record(
            medicationId: medicationId,
            scheduledFor: scheduledFor,
            source: .widget,
            binding: ExternalTakeLog.Binding.forCommit(error: failure, receipt: receipt, idempotencyKey: idempotencyKey.raw)
        )
    }
}
