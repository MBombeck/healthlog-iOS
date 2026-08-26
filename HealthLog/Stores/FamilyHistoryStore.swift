import Foundation
import Observation

/// `@MainActor @Observable` store backing the native FAMILY-HISTORY records
/// surface (v1.25 `W-RECORDS`). Loads the entry list via
/// ``FamilyHistoryRepository`` and drives optimistic create / update / delete.
///
/// **PHI.** The decrypted `note` free-text lives in ``records`` — this store
/// conforms to `LogoutClearable` so the cascade wipes it on logout. Errors route
/// through `LogSanitizer.redact`; the note is never logged.
///
/// **Deferred-delete undo (no restore endpoint).** Mirrors ``AllergiesStore``: a
/// swipe-delete removes the row optimistically and schedules the network `DELETE`
/// to fire only after the undo window elapses, so an undo cancels the pending
/// call and re-inserts the row losslessly.
@MainActor
@Observable
public final class FamilyHistoryStore {
    public private(set) var records: [FamilyHistoryEntryDTO] = []
    public private(set) var isLoading = false
    public private(set) var lastError: String?

    /// The undo window (seconds) the optimistic delete defers the network call by.
    public static let deleteUndoWindow: TimeInterval = 5

    private let repository: FamilyHistoryRepository
    private let undo: UndoCoordinator?
    private var isReloading = false
    private var pendingDeletes: [String: Task<Void, Never>] = [:]

    public init(repository: FamilyHistoryRepository, undo: UndoCoordinator? = nil) {
        self.repository = repository
        self.undo = undo
    }

    // MARK: - Load

    /// Load the family-history list. No-op while a reload is already in flight.
    public func load() async {
        guard !isReloading else { return }
        isReloading = true
        isLoading = true
        defer {
            isLoading = false
            isReloading = false
        }
        do {
            let fetched = try await repository.list()
            // L6 — a refresh during the undo window must NOT re-surface a row that
            // is mid-deferred-delete (the pending DELETE still fires → flicker).
            records = pendingDeletes.isEmpty ? fetched : fetched.filter { pendingDeletes[$0.id] == nil }
            lastError = nil
        } catch {
            applyError(error)
        }
    }

    // MARK: - Writes

    /// Create an entry, then reload. Returns the created entry on success.
    ///
    /// **H3 — offline create is SUCCESS, not failure.** A retriable failure is
    /// durably enqueued by the repo under a STABLE idempotency key and re-thrown.
    /// We treat that as success (optimistic row + return it) so the user does not
    /// re-tap and mint a SECOND key → a DUPLICATE clinical record on reconnect. The
    /// outbox replays the original write once; the next online reload reconciles.
    @discardableResult
    public func create(_ body: FamilyHistoryCreate) async -> FamilyHistoryEntryDTO? {
        lastError = nil
        // audit-v0162 H-4 — stamp the optimistic id on the queued create so a
        // later offline edit/delete of this entry is remapped to the server id
        // once the create replays.
        let clientEntityId = "optimistic-\(UUID().uuidString)"
        do {
            let created = try await repository.create(body, clientEntityId: clientEntityId)
            await load()
            return created
        } catch let err as HLError where err.shouldPersistToOutbox {
            let optimistic = Self.optimisticEntry(from: body, id: clientEntityId)
            records.insert(optimistic, at: 0)
            lastError = nil
            return optimistic
        } catch {
            applyError(error)
            return nil
        }
    }

    /// Update an entry, then reload. Returns `true` on success.
    ///
    /// **H3 — an offline (durably enqueued) update is SUCCESS** (same duplicate-on-
    /// retry rationale as `create`). The outbox replays the queued PATCH once.
    @discardableResult
    public func update(id: String, _ patch: FamilyHistoryPatch) async -> Bool {
        lastError = nil
        do {
            _ = try await repository.update(id: id, patch)
            await load()
            return true
        } catch let err as HLError where err.shouldPersistToOutbox {
            lastError = nil
            return true
        } catch {
            applyError(error)
            return false
        }
    }

    /// Optimistically remove an entry + surface a `HLUndoToast`. The network
    /// soft-delete is DEFERRED until the undo window elapses (no restore
    /// endpoint); undo cancels it and re-inserts the row in place.
    public func delete(_ record: FamilyHistoryEntryDTO, undoMessage: String) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records.remove(at: index)
        lastError = nil

        pendingDeletes[record.id]?.cancel()
        let task = Task { @MainActor [weak self] in
            let nanos = UInt64(Self.deleteUndoWindow * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            if Task.isCancelled { return }
            await self?.commitDelete(record, originalIndex: index)
        }
        pendingDeletes[record.id] = task

        undo?.enqueue(message: undoMessage, ttl: Self.deleteUndoWindow) { [weak self] in
            await self?.cancelPendingDelete(record, originalIndex: index)
        }
    }

    private func cancelPendingDelete(_ record: FamilyHistoryEntryDTO, originalIndex: Int) {
        pendingDeletes[record.id]?.cancel()
        pendingDeletes[record.id] = nil
        if !records.contains(where: { $0.id == record.id }) {
            records.insert(record, at: min(originalIndex, records.count))
        }
    }

    private func commitDelete(_ record: FamilyHistoryEntryDTO, originalIndex: Int) async {
        pendingDeletes[record.id] = nil
        do {
            _ = try await repository.delete(id: record.id)
        } catch let err as HLError where err.shouldPersistToOutbox {
            return // durably queued — keep the optimistic removal
        } catch {
            if FamilyHistoryRepository.isNotFound(error) { return }
            if !records.contains(where: { $0.id == record.id }) {
                records.insert(record, at: min(originalIndex, records.count))
            }
            applyError(error)
        }
    }

    // MARK: - Logout

    /// Drop every in-memory snapshot + cancel pending deletes on logout (PHI).
    public func clearOnLogout() {
        for task in pendingDeletes.values {
            task.cancel()
        }
        pendingDeletes = [:]
        records = []
        isLoading = false
        isReloading = false
        lastError = nil
    }

    /// Test-only — populate the in-memory snapshot without a network round-trip.
    func seedForTesting(records: [FamilyHistoryEntryDTO]) {
        self.records = records
    }

    // MARK: - Private

    /// Build an optimistic in-memory row for an offline-queued create (H3). Carries
    /// a temporary `optimistic-…` id; the next online reload replaces the snapshot
    /// with the server records (under the same idempotency key).
    private static func optimisticEntry(from body: FamilyHistoryCreate, id: String) -> FamilyHistoryEntryDTO {
        let now = ISO8601DateFormatter().string(from: Date.now)
        return FamilyHistoryEntryDTO(
            id: id,
            relationship: body.relationship,
            condition: body.condition,
            ageAtOnset: body.ageAtOnset,
            note: body.note,
            createdAt: now,
            updatedAt: now
        )
    }

    private func applyError(_ error: Error) {
        lastError = LogSanitizer.redact(String(describing: error))
    }
}
