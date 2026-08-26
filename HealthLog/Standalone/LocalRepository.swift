import Foundation
import SwiftData

/// Public actor wrapping `LocalStore` — the standalone local-canonical mirror.
/// Lives in `AppContainer`; in v0.11 paired mode it is registered but DORMANT
/// (nothing reads it). Read-union (W2), the Release door (W5), and adopt-on-
/// pair upload (W4) light it up later. Mirrors the `GLP1LocalRepository` →
/// `GLP1LocalStore` split so the actor surface stays Sendable-clean and the
/// persistence layer can be swapped in tests (in-memory) without touching call
/// sites.
///
/// **Validation policy:** notes are trimmed + capped at the repository boundary
/// (`maxNoteLength`); mood `score` is clamped to 1–5. The UI guards against
/// invalid input at the picker boundary, so clamping silently rather than
/// throwing keeps the write path infallible for the caller.
public actor LocalRepository {
    /// Deferred-open state for the backing `LocalStore`. Mirrors
    /// `SWRCoordinator.CacheState`: production defers the SwiftData
    /// `ModelContainer` open onto a detached task (`makeWithRecoveryTask()`)
    /// so `AppContainer.init` (the cold-launch tick) never pays for it; the
    /// store resolves lazily on the first actual read/write. In paired mode
    /// this mirror is dormant, so the common launch never even triggers the
    /// resolve. Tests seed `.resolved` directly via `init(store:)`.
    private enum StoreState {
        case pending(Task<LocalStore, Never>)
        case resolved(LocalStore)
    }

    private var storeState: StoreState

    /// Max length for free-text notes across all entities. Enforced here so the
    /// SwiftData schema doesn't need a validator. Mirrors
    /// `GLP1LocalRepository.maxNoteLength`.
    public static let maxNoteLength: Int = 512

    public init(store: LocalStore) {
        storeState = .resolved(store)
    }

    /// Production init — defers `LocalStore` resolution until the first
    /// read/write. `AppContainer` kicks the `ModelContainer` open onto a
    /// detached task via `makeWithRecoveryTask()`; we await it lazily on first
    /// use so app launch no longer pays for the SwiftData open on the
    /// cold-launch tick (audit P-1).
    public init(storeTask: Task<LocalStore, Never>) {
        storeState = .pending(storeTask)
    }

    /// Single-flight resolve of the deferred store. First caller awaits the
    /// open; subsequent callers return the memoised actor reference without
    /// re-opening. Mirrors `SWRCoordinator.cache()`.
    private func store() async -> LocalStore {
        switch storeState {
        case let .resolved(store):
            return store
        case let .pending(task):
            let value = await task.value
            storeState = .resolved(value)
            return value
        }
    }

    /// Synchronous production factory. Mirrors `GLP1LocalRepository`:
    /// tries the persistent SQLite store, wipes the directory + retries once on
    /// failure, falls back to an in-memory store with a logged warning. Kept
    /// for callers that don't pay the cold-launch budget (tests / macOS); the
    /// composition root prefers `makeWithRecoveryTask()` so the open runs off
    /// the launch tick.
    public static func makeWithRecovery() -> LocalRepository {
        LocalRepository(store: makeStoreWithRecovery())
    }

    /// Detached-task variant of `makeWithRecovery()`. Schedules the
    /// `ModelContainer` open on a `.userInitiated` detached task so the
    /// SwiftData open (~30-80 ms cold) no longer blocks the launch tick
    /// (audit P-1). Consumed by `init(storeTask:)`, resolved lazily on first
    /// use. The Outbox has to stay synchronous (BGTaskScheduler.register runs
    /// in `applicationDidFinishLaunching`); this dormant paired-mode mirror has
    /// no such coupling.
    public static func makeWithRecoveryTask() -> LocalRepository {
        let task = Task.detached(priority: .userInitiated) {
            makeStoreWithRecovery()
        }
        return LocalRepository(storeTask: task)
    }

    /// Shared store-open recovery ladder used by both the sync + deferred
    /// factories. `static` (hence nonisolated) so the detached open-task can
    /// call it off the actor.
    private static func makeStoreWithRecovery() -> LocalStore {
        do {
            let container = try LocalStore.makePersistent()
            return LocalStore(modelContainer: container)
        } catch {
            HLLog.outbox.error(
                "Standalone store unreadable, attempting rebuild: \(LogSanitizer.redact(String(describing: error)))"
            )
            if let storeURL = try? LocalStore.persistentStoreURL() {
                let dir = storeURL.deletingLastPathComponent()
                try? FileManager.default.removeItem(at: dir)
            }
            do {
                let container = try LocalStore.makePersistent()
                return LocalStore(modelContainer: container)
            } catch {
                HLLog.outbox.error(
                    "Standalone rebuild also failed, falling back to in-memory: \(LogSanitizer.redact(String(describing: error)))"
                )
                // Non-trapping in-memory floor (audit M2): degrade to an inert
                // empty-schema store instead of `try!`-trapping on the path that
                // exists to avoid a hard launch failure.
                let container = ModelContainerRecovery.recoveredInMemoryContainer(
                    log: HLLog.outbox,
                    subsystem: "Standalone",
                    build: LocalStore.makeInMemory
                )
                return LocalStore(modelContainer: container)
            }
        }
    }

    // MARK: - Measurements

    public func measurements(
        kind: String? = nil,
        limit: Int? = nil
    ) async throws -> [LocalMeasurementSnapshot] {
        try await store().snapshotMeasurements(kind: kind, limit: limit)
    }

    public func addMeasurement(
        kind: String,
        value: Double,
        unit: String,
        systolic: Double? = nil,
        diastolic: Double? = nil,
        recordedAt: Date,
        note: String? = nil,
        source: String = "manual"
    ) async throws -> LocalMeasurementSnapshot {
        let snapshot = LocalMeasurementSnapshot(
            externalId: UUID().uuidString,
            kind: kind,
            value: value,
            unit: unit,
            systolic: systolic,
            diastolic: diastolic,
            recordedAt: recordedAt,
            note: sanitizeNote(note),
            source: source,
            createdAt: .now
        )
        try await store().insertMeasurement(snapshot)
        return snapshot
    }

    public func updateMeasurement(
        externalId: String,
        value: Double,
        unit: String,
        systolic: Double? = nil,
        diastolic: Double? = nil,
        recordedAt: Date,
        note: String? = nil
    ) async throws {
        try await store().updateMeasurement(
            externalId: externalId,
            value: value,
            unit: unit,
            systolic: systolic,
            diastolic: diastolic,
            recordedAt: recordedAt,
            note: sanitizeNote(note)
        )
    }

    public func deleteMeasurement(externalId: String) async throws {
        try await store().deleteMeasurement(externalId: externalId)
    }

    // MARK: - Moods

    public func moods(days: Int? = nil) async throws -> [LocalMoodSnapshot] {
        try await store().snapshotMoods(sinceDays: days)
    }

    public func addMood(
        score: Int,
        tags: [String] = [],
        tagKeys: [String] = [],
        note: String? = nil,
        recordedAt: Date,
        source: String = "manual"
    ) async throws -> LocalMoodSnapshot {
        let snapshot = LocalMoodSnapshot(
            externalId: UUID().uuidString,
            score: clampScore(score),
            tags: tags,
            tagKeys: tagKeys,
            note: sanitizeNote(note),
            recordedAt: recordedAt,
            source: source,
            createdAt: .now
        )
        try await store().insertMood(snapshot)
        return snapshot
    }

    public func updateMood(
        externalId: String,
        score: Int,
        tags: [String],
        tagKeys: [String] = [],
        note: String? = nil,
        recordedAt: Date
    ) async throws {
        try await store().updateMood(
            externalId: externalId,
            score: clampScore(score),
            tags: tags,
            tagKeys: tagKeys,
            note: sanitizeNote(note),
            recordedAt: recordedAt
        )
    }

    public func deleteMood(externalId: String) async throws {
        try await store().deleteMood(externalId: externalId)
    }

    // MARK: - Intakes

    public func intakes(medicationId: String? = nil) async throws -> [LocalIntakeSnapshot] {
        try await store().snapshotIntakes(medicationId: medicationId)
    }

    public func addIntake(
        medicationId: String,
        takenAt: Date,
        status: String,
        injectionSite: String? = nil,
        note: String? = nil,
        source: String = "manual"
    ) async throws -> LocalIntakeSnapshot {
        let snapshot = LocalIntakeSnapshot(
            externalId: UUID().uuidString,
            medicationId: medicationId,
            takenAt: takenAt,
            status: status,
            // Only a `taken` dose carries a site — mirror the paired
            // `record(intake:)` gate (`status == .taken ? site : nil`).
            injectionSite: status == IntakeStatus.taken.rawValue ? injectionSite : nil,
            note: sanitizeNote(note),
            source: source,
            createdAt: .now
        )
        try await store().insertIntake(snapshot)
        return snapshot
    }

    public func updateIntake(
        externalId: String,
        takenAt: Date,
        status: String,
        note: String? = nil
    ) async throws {
        try await store().updateIntake(
            externalId: externalId,
            takenAt: takenAt,
            status: status,
            note: sanitizeNote(note)
        )
    }

    public func deleteIntake(externalId: String) async throws {
        try await store().deleteIntake(externalId: externalId)
    }

    // MARK: - Medication definitions (v0.13 W5)

    public func medications(includeArchived: Bool = false) async throws -> [LocalMedicationSnapshot] {
        try await store().snapshotMedications(includeArchived: includeArchived)
    }

    public func medication(externalId: String) async throws -> LocalMedicationSnapshot? {
        try await store().snapshotMedication(externalId: externalId)
    }

    public func addMedication(_ snapshot: LocalMedicationSnapshot) async throws -> LocalMedicationSnapshot {
        try await store().insertMedication(snapshot)
        return snapshot
    }

    public func updateMedication(_ snapshot: LocalMedicationSnapshot) async throws {
        try await store().updateMedication(snapshot)
    }

    public func archiveMedication(externalId: String, archivedAt: Date) async throws {
        try await store().archiveMedication(externalId: externalId, archivedAt: archivedAt)
    }

    // MARK: - Backfill / wipe

    /// Snapshots every locally-canonical row for the W4 adopt-on-pair upload.
    public func allForBackfill() async throws -> LocalBackfillBundle {
        try await store().snapshotAll()
    }

    /// Wipes the whole mirror — wired into the account-deletion / logout cascade
    /// alongside the GLP-1 + outbox wipes.
    public func deleteAll() async throws {
        try await store().deleteAll()
    }

    // MARK: - Internals

    private func clampScore(_ raw: Int) -> Int {
        max(1, min(5, raw))
    }

    private func sanitizeNote(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(Self.maxNoteLength))
    }
}

// MARK: - v0.11 W2 — standalone read-union seam conformance

/// Exposes the local mirror to the platform-free repository read-union
/// (`StandaloneGate`) without leaking the SwiftData concretes. The methods just
/// re-spell the existing read API onto the Core protocol's vocabulary.
extension LocalRepository: StandaloneLocalReading {
    public func standaloneMeasurements(kind: String?, limit: Int?) async throws -> [LocalMeasurementSnapshot] {
        try await measurements(kind: kind, limit: limit)
    }

    public func standaloneMoods(days: Int?) async throws -> [LocalMoodSnapshot] {
        try await moods(days: days)
    }

    public func standaloneIntakes(medicationId: String?) async throws -> [LocalIntakeSnapshot] {
        try await intakes(medicationId: medicationId)
    }

    public func standaloneAddMeasurement(
        kind: String, value: Double, unit: String,
        systolic: Double?, diastolic: Double?, recordedAt: Date, note: String?
    ) async throws -> LocalMeasurementSnapshot {
        try await addMeasurement(
            kind: kind, value: value, unit: unit,
            systolic: systolic, diastolic: diastolic, recordedAt: recordedAt, note: note
        )
    }

    public func standaloneUpdateMeasurement(
        externalId: String, value: Double, unit: String,
        systolic: Double?, diastolic: Double?, recordedAt: Date, note: String?
    ) async throws {
        try await updateMeasurement(
            externalId: externalId, value: value, unit: unit,
            systolic: systolic, diastolic: diastolic, recordedAt: recordedAt, note: note
        )
    }

    public func standaloneDeleteMeasurement(externalId: String) async throws {
        try await deleteMeasurement(externalId: externalId)
    }

    public func standaloneAddMood(
        score: Int, tags: [String], tagKeys: [String], note: String?, recordedAt: Date
    ) async throws -> LocalMoodSnapshot {
        try await addMood(score: score, tags: tags, tagKeys: tagKeys, note: note, recordedAt: recordedAt)
    }

    public func standaloneUpdateMood(
        externalId: String, score: Int, tags: [String], tagKeys: [String], note: String?, recordedAt: Date
    ) async throws {
        try await updateMood(externalId: externalId, score: score, tags: tags, tagKeys: tagKeys, note: note, recordedAt: recordedAt)
    }

    public func standaloneDeleteMood(externalId: String) async throws {
        try await deleteMood(externalId: externalId)
    }

    public func standaloneAddIntake(
        medicationId: String, takenAt: Date, status: String, injectionSite: String?, note: String?
    ) async throws -> LocalIntakeSnapshot {
        try await addIntake(
            medicationId: medicationId,
            takenAt: takenAt,
            status: status,
            injectionSite: injectionSite,
            note: note
        )
    }

    public func standaloneDeleteIntake(externalId: String) async throws {
        try await deleteIntake(externalId: externalId)
    }

    public func standaloneMedications(includeArchived: Bool) async throws -> [LocalMedicationSnapshot] {
        try await medications(includeArchived: includeArchived)
    }

    public func standaloneMedication(externalId: String) async throws -> LocalMedicationSnapshot? {
        try await medication(externalId: externalId)
    }

    public func standaloneAddMedication(_ snapshot: LocalMedicationSnapshot) async throws -> LocalMedicationSnapshot {
        try await addMedication(snapshot)
    }

    public func standaloneUpdateMedication(_ snapshot: LocalMedicationSnapshot) async throws {
        try await updateMedication(snapshot)
    }

    public func standaloneArchiveMedication(externalId: String, archivedAt: Date) async throws {
        try await archiveMedication(externalId: externalId, archivedAt: archivedAt)
    }
}
