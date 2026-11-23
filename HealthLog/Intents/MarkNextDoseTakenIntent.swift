import AppIntents
import Foundation
import WidgetKit

/// "Nächste Dosis – Genommen" control intent.
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

    /// Test seam for the outcome marker the widget reads.
    @MainActor static var outcomeStoreOverride: WidgetDoseOutcomeStore?

    /// Test seam for the clock the freshness check reads.
    @MainActor static var nowOverride: Date?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let deps = IntentDependencies.resolve()
        guard IntentDependencies.isSignedIn(deps) else {
            return .result(dialog: IntentCopy.signInRequired)
        }

        let store = Self.snapshotStoreOverride ?? WidgetSnapshotStore()
        let outcomes = Self.outcomeStoreOverride ?? WidgetDoseOutcomeStore()
        let now = Self.nowOverride ?? Date()
        let decision = Self.decide(
            snapshot: store.read(),
            outcome: outcomes.read(),
            now: now
        )
        let nextDose: WidgetSnapshot.NextDose
        switch decision {
        case .noDose: return .result(dialog: IntentCopy.noDoseDue)
        case .stale: return .result(dialog: IntentCopy.snapshotStale)
        case .alreadyRecorded: return .result(dialog: IntentCopy.alreadyRecorded)
        case let .record(dose): nextDose = dose
        }

        // Booked on the dose's slot, like the widget button, so the server
        // lands it on that slot instead of guessing one from the tap time.
        var failure: Error?
        do {
            try await deps.medicationsRepo.recordFromReminder(
                medicationId: nextDose.medicationId,
                scheduledFor: nextDose.scheduledAt,
                status: .taken
            )
        } catch {
            failure = error
        }
        outcomes.record(
            medicationId: nextDose.medicationId,
            scheduledFor: nextDose.scheduledAt,
            kind: WidgetDoseOutcomeStore.kind(signedIn: true, error: failure),
            now: now
        )
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.nextDose)
        guard let failure else {
            return .result(dialog: IntentDialog(Self.confirmation(medicationName: nextDose.medicationName)))
        }
        if let already = failure as? MedicationAlreadyTaken {
            return .result(dialog: IntentDialog(stringLiteral: already.message)) // #189 (6)
        }
        if let error = failure as? HLError, error.shouldPersistToOutbox {
            // Durably enqueued (incl. a transient-refresh 401) — saved, not lost.
            return .result(dialog: IntentCopy.queued(after: error))
        }
        return .result(dialog: IntentCopy.writeFailed)
    }

    /// What one tap on the control does.
    enum Decision: Equatable {
        case noDose
        /// The snapshot is older than the widget's own next-dose cutoff.
        case stale
        /// A widget or control tap already saved this slot.
        case alreadyRecorded
        case record(WidgetSnapshot.NextDose)
    }

    /// Pure rule: the same freshness cutoff the widget applies before it shows
    /// its button, and no second write for a slot a tap already saved.
    static func decide(
        snapshot: WidgetSnapshot?,
        outcome: WidgetDoseOutcomeStore.Outcome?,
        now: Date
    ) -> Decision {
        guard let snapshot, let dose = snapshot.nextDose else { return .noDose }
        guard !WidgetTimelinePolicy.isNextDoseUntrusted(
            generatedAt: snapshot.generatedAt,
            scheduledAt: dose.scheduledAt,
            now: now
        ) else {
            return .stale
        }
        // #189 (1): taken elsewhere, as the confirmation push recorded.
        if ResolvedDoseLedger().contains(
            medicationId: dose.medicationId,
            slotAt: dose.scheduledAt,
            recordedAfter: snapshot.generatedAt
        ) {
            return .alreadyRecorded
        }
        switch WidgetDoseOutcomeStore.applicableKind(
            outcome, to: dose, snapshotGeneratedAt: snapshot.generatedAt, now: now
        ) {
        case .recorded, .queued: return .alreadyRecorded
        case .notSaved, nil: return .record(dose)
        }
    }

    /// **1.4** — the spoken confirmation. This intent runs from the lock
    /// screen by design (Control Center, Action Button), so it keeps working
    /// there, but it follows the switch that hides medication names on the
    /// lock screen: with it on, the confirmation names no medication.
    static func confirmation(
        medicationName: String,
        hidesName: Bool = LockScreenPrivacy.hideMedicationName()
    ) -> LocalizedStringResource {
        if hidesName {
            return LocalizedStringResource(
                "Marked your next dose as taken.",
                comment: "AppIntents — next-dose marked taken confirmation without the medication name (lock-screen privacy on)"
            )
        }
        return LocalizedStringResource(
            "Marked \(medicationName) as taken.",
            comment: "AppIntents — next-dose marked taken confirmation"
        )
    }
}
