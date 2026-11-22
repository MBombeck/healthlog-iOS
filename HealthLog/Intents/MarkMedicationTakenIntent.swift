import AppIntents
import Foundation

/// "Mark medication as taken" Siri / Shortcuts
/// intent.
///
/// Records an intake against the **same** server path the
/// `MEDICATION_REMINDER` notification action handler uses:
/// `MedicationsRepository.recordFromReminder(...)` →
/// `POST /api/medications/intake/bulk` with an idempotency key, Outbox
/// fallback on a retriable network error. No parallel write path, no
/// new endpoint — exactly the method `NotificationService.dispatchAction`
/// calls on a "Genommen" tap.
///
/// The medication is resolved via ``MedicationEntityQuery``, which lists
/// the user's medications from the server so Siri / Spotlight can offer
/// them by name. `scheduledFor` defaults to now (the reminder-driven
/// bulk endpoint idempotently inserts-or-returns the row for the
/// `(medicationId, scheduledFor)` pair).
struct MarkMedicationTakenIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark medication as taken"

    static let description = IntentDescription(
        "Mark one of your medications as taken in HealthLog."
    )

    static let openAppWhenRun: Bool = false

    @Parameter(
        title: "Medication",
        description: "The medication to mark as taken."
    )
    var medication: MedicationEntity

    /// Optional override for the recorded slot
    /// instant, as a Unix epoch (seconds). The next-dose widget passes the
    /// due dose's canonical `scheduledAt` so the intake row keys on
    /// `(medicationId, scheduledFor)` and de-dupes onto the in-app card's
    /// row instead of spawning a duplicate "now" row beside the slot.
    ///
    /// Siri / Shortcuts leave this `nil` → the intake records against `now`,
    /// preserving the explicit "I took it now" semantics. Not surfaced in the
    /// `parameterSummary`, so the Siri / Shortcuts UI never prompts for it.
    @Parameter(title: "Scheduled For (epoch)")
    var scheduledForEpoch: Double?

    static var parameterSummary: some ParameterSummary {
        Summary("Mark \(\.$medication) as taken")
    }

    /// Resolve the instant the intake records against: the supplied slot epoch
    /// (next-dose widget) when present, else `now` (Siri / Shortcuts —
    /// explicit "I took it now"). Pure + testable; `scheduledFor` is what the
    /// bulk endpoint keys the idempotent insert on, so a slot instant collapses
    /// onto the in-app card's `(medicationId, scheduledFor)` row.
    static func resolveScheduledFor(epoch: Double?, now: Date = .now) -> Date {
        epoch.map { Date(timeIntervalSince1970: $0) } ?? now
    }

    /// The spoken confirmation. This intent stays usable on a locked iPhone
    /// (a write, like `MarkNextDoseTakenIntent`), so it names no medication
    /// while the switch that hides names is on or the device is locked.
    @MainActor
    static func confirmation(
        medicationName: String,
        hidesName: Bool = IntentMedicationNamePrivacy.hidesNames()
    ) -> LocalizedStringResource {
        if hidesName {
            return LocalizedStringResource(
                "Marked the medication as taken.",
                comment: "AppIntents — medication marked taken confirmation without the name (names hidden or device locked)"
            )
        }
        return LocalizedStringResource(
            "Marked \(medicationName) as taken.",
            comment: "AppIntents — medication marked taken confirmation"
        )
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let deps = IntentDependencies.resolve()
        guard IntentDependencies.isSignedIn(deps) else {
            return .result(dialog: IntentCopy.signInRequired)
        }

        let scheduledFor = Self.resolveScheduledFor(epoch: scheduledForEpoch)

        do {
            try await deps.medicationsRepo.recordFromReminder(
                medicationId: medication.id,
                scheduledFor: scheduledFor,
                status: .taken
            )
            return .result(dialog: IntentDialog(Self.confirmation(medicationName: medication.name)))
        } catch let already as MedicationAlreadyTaken {
            // #189 (6): no second dose; say when the first one was taken.
            return .result(dialog: IntentDialog(stringLiteral: already.message))
        } catch let error as HLError where error.shouldPersistToOutbox {
            // Durably enqueued (incl. a transient-refresh 401) — saved, not lost.
            return .result(dialog: IntentCopy.queued(after: error))
        } catch {
            return .result(dialog: IntentCopy.writeFailed)
        }
    }
}

/// App-Intents entity mirroring a `Medication` row so Siri / Spotlight
/// can resolve a medication by name. Only the load-bearing fields (id +
/// name) cross the App-Intents boundary — the entity is a lookup token,
/// not a full domain model.
struct MedicationEntity: AppEntity {
    let id: String
    let name: String

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Medication"
    )

    static let defaultQuery = MedicationEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

/// Resolves `MedicationEntity` values for the intent. Lists the user's
/// medications from the server through the shared
/// `MedicationsRepository.list()` so the picker stays in sync with the
/// app. Returns an empty set when signed out (the intent's own gate
/// surfaces the sign-in dialog).
///
/// On a locked iPhone it suggests nothing: Siri would read the whole list
/// aloud to ask which one. It asks without a list instead, and the spoken
/// name resolves through ``entities(matching:)``.
struct MedicationEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [MedicationEntity] {
        let all = try await fetchAll()
        let wanted = Set(identifiers)
        return all.filter { wanted.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [MedicationEntity] {
        let wanted = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return [] }
        return try await fetchAll().filter { $0.name.localizedStandardContains(wanted) }
    }

    @MainActor
    func suggestedEntities() async throws -> [MedicationEntity] {
        guard !IntentMedicationNamePrivacy.isDeviceLocked() else { return [] }
        return try await fetchAll()
    }

    @MainActor
    private func fetchAll() async throws -> [MedicationEntity] {
        let deps = IntentDependencies.resolve()
        guard IntentDependencies.isSignedIn(deps) else { return [] }
        // v1.39.1 — Siri offers no intake for a medication kept as a
        // record (intake tracking off); v1.39.4 — nor for one the server
        // calls not actionable today (an ended or not yet started course).
        let medications = try await deps.medicationsRepo.list().filter(\.offersIntakeActions)
        return medications.map { MedicationEntity(id: $0.id, name: $0.name) }
    }
}

/// **Whether Siri may say a medication name.** Not while "hide medication
/// names" is on, and not while the iPhone is locked: a write intent runs
/// there by design, and whoever holds the locked phone hears the answer.
@MainActor
enum IntentMedicationNamePrivacy {
    /// The lock state. The app sets it at launch from
    /// `UIApplication.isProtectedDataAvailable`; an extension cannot ask, and
    /// there only the switch counts.
    static var isDeviceLocked: @MainActor () -> Bool = { false }

    static func hidesNames(
        switchOn: Bool = LockScreenPrivacy.hideMedicationName(),
        locked: Bool? = nil
    ) -> Bool {
        switchOn || (locked ?? isDeviceLocked())
    }
}
