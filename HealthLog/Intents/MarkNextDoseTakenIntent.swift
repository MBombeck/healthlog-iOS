import AppIntents
import Foundation

/// **v0.8.4 WWIDGET-3** — "Nächste Dosis – Genommen" control intent.
///
/// Bound to the Control Center / Lock-Screen / Action-Button
/// ``MarkNextDoseControl``. One tap marks the *next due dose* taken without
/// opening the app (`openAppWhenRun = false`) — the same one-tap "Genommen"
/// the notification action, the Live Activity, and the next-dose widget
/// expose, reached from a hardware/Control-Center surface.
///
/// **Why a dedicated intent and not the shared ``MarkMedicationTakenIntent``
/// directly:** a `ControlWidgetButton` needs a *parameterless* intent it can
/// fire on tap — there is no per-tap UI to resolve a `MedicationEntity`. This
/// intent reads which dose is next from the App Group ``WidgetSnapshot`` (the
/// same snapshot the next-dose widget paints from, written by the app), then
/// records the intake through the **identical** server-first path
/// `MedicationsRepository.recordFromReminder(...)` — no parallel write path,
/// idempotency-keyed, Outbox-on-failure, exactly like every other "taken"
/// surface. The snapshot already carries `medicationId` + name, which is all
/// the recordFromReminder path needs (it keys the idempotent insert on
/// `(medicationId, scheduledFor)`), so **no `WidgetSnapshot` extension is
/// required**.
struct MarkNextDoseTakenIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark next dose as taken"

    static let description = IntentDescription(
        "Marks your next scheduled medication dose as taken in HealthLog."
    )

    static let openAppWhenRun: Bool = false

    /// Test seam — when set, the intent reads the next dose from this store
    /// instead of the live App Group container. Production never sets this.
    /// `@MainActor`-isolated (the `perform()` that reads it already runs on
    /// the main actor) so the mutable static is concurrency-safe under Swift
    /// 6 strict concurrency — no `nonisolated(unsafe)` painkiller.
    @MainActor static var snapshotStoreOverride: WidgetSnapshotStore?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let deps = IntentDependencies.resolve()
        guard IntentDependencies.isSignedIn(deps) else {
            return .result(dialog: IntentCopy.signInRequired)
        }

        let store = Self.snapshotStoreOverride ?? WidgetSnapshotStore()
        guard let nextDose = store.read()?.nextDose else {
            return .result(dialog: IntentCopy.noDoseDue)
        }

        do {
            try await deps.medicationsRepo.recordFromReminder(
                medicationId: nextDose.medicationId,
                scheduledFor: Date(),
                status: .taken
            )
            return .result(
                dialog: IntentDialog(
                    LocalizedStringResource(
                        "Marked \(nextDose.medicationName) as taken.",
                        comment: "AppIntents — next-dose marked taken confirmation"
                    )
                )
            )
        } catch let error as HLError where error.shouldPersistToOutbox {
            // Durably enqueued (incl. a transient-refresh 401) — saved, not lost.
            return .result(dialog: IntentCopy.queuedOffline)
        } catch {
            return .result(dialog: IntentCopy.writeFailed)
        }
    }
}
