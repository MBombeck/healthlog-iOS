import Foundation
import Observation

/// `@MainActor @Observable` store backing the native ALLERGY records surface
/// (v1.25 `W-RECORDS`). Loads the allergy list via ``AllergiesRepository`` and
/// drives optimistic create / update / delete.
///
/// **PHI.** The decrypted `reaction` + `note` free-text live in ``records`` —
/// this store conforms to `LogoutClearable` so the cascade wipes it on logout
/// (the next user never inherits the predecessor's allergies). Errors are routed
/// through `LogSanitizer.redact`; the PHI fields are never logged.
///
/// **Deferred-delete undo (no restore endpoint).** The server soft-delete has no
/// inverse, so a swipe-delete removes the row optimistically AND schedules the
/// network `DELETE` to fire only after the undo window elapses. Tapping undo
/// cancels the pending task and re-inserts the row in place — nothing reached the
/// server, so the record (id + createdAt + encrypted PHI) is preserved exactly.
/// Letting the window expire commits the delete (durably, via the outbox, on a
/// retriable failure).
@MainActor
@Observable
public final class AllergiesStore {
    public private(set) var records: [AllergyDTO] = []
    public private(set) var isLoading = false
    public private(set) var lastError: String?

    /// The undo window (seconds) the optimistic delete defers the network call by.
    public static let deleteUndoWindow: TimeInterval = 5

    private let repository: AllergiesRepository
    private let undo: UndoCoordinator?
    private var isReloading = false
    /// In-flight deferred deletes, keyed by record id, so a re-delete / undo /
    /// logout can cancel the pending network call before it fires.
    private var pendingDeletes: [String: Task<Void, Never>] = [:]

    public init(repository: AllergiesRepository, undo: UndoCoordinator? = nil) {
        self.repository = repository
        self.undo = undo
    }

    // MARK: - Load

    /// Load the allergy list. No-op while a reload is already in flight.
    public func load(includeInactive: Bool = true) async {
        guard !isReloading else { return }
        isReloading = true
        isLoading = true
        defer {
            isLoading = false
            isReloading = false
        }
        do {
            let fetched = try await repository.list(includeInactive: includeInactive)
            // L6 — a refresh during the undo window must NOT re-surface a row that
            // is mid-deferred-delete: the pending DELETE still fires and the row
            // would vanish on the next load, a confusing flicker. Filter out any id
            // with a pending delete so the optimistic removal holds until the
            // commit lands (or undo re-inserts it).
            records = pendingDeletes.isEmpty ? fetched : fetched.filter { pendingDeletes[$0.id] == nil }
            lastError = nil
        } catch {
            applyError(error)
        }
    }

    // MARK: - Writes

    /// Create an allergy, then reload. Returns the created record on success.
    ///
    /// **H3 — offline create is SUCCESS, not failure.** When the network attempt
    /// fails retriably the repo durably enqueues the create under a STABLE
    /// idempotency key and re-throws `HLError.shouldPersistToOutbox`. We treat that
    /// as success (insert an optimistic row, return it) — mirroring `commitDelete`
    /// — so the user does NOT see a "save failed" sheet and re-tap, which would mint
    /// a SECOND idempotency key and create a DUPLICATE clinical record on reconnect.
    /// The outbox replays the original write exactly once; the next online reload
    /// reconciles the optimistic row with the server record.
    @discardableResult
    public func create(_ body: AllergyCreate) async -> AllergyDTO? {
        lastError = nil
        // audit-v0162 H-4 — mint the optimistic id UP FRONT and stamp it on the
        // queued create so a later offline edit/delete of this record (which
        // targets the same optimistic id) is remapped to the server id when the
        // create replays, instead of 404-ing.
        let clientEntityId = "optimistic-\(UUID().uuidString)"
        do {
            let created = try await repository.create(body, clientEntityId: clientEntityId)
            await load()
            return created
        } catch let err as HLError where err.shouldPersistToOutbox {
            let optimistic = Self.optimisticAllergy(from: body, id: clientEntityId)
            records.insert(optimistic, at: 0)
            lastError = nil
            return optimistic
        } catch {
            applyError(error)
            return nil
        }
    }

    /// Update an allergy, then reload. Returns `true` on success.
    ///
    /// **H3 — an offline (durably enqueued) update is SUCCESS.** Same rationale as
    /// `create`: surfacing it as a failure invites a retry that mints a second
    /// idempotency key → a duplicate PATCH on reconnect. The outbox replays the
    /// queued PATCH once; the next online reload reflects the server state.
    @discardableResult
    public func update(id: String, _ patch: AllergyPatch) async -> Bool {
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

    /// Optimistically remove an allergy + surface a `HLUndoToast`. The row is
    /// dropped from the in-memory list immediately; the server soft-delete is
    /// DEFERRED until the undo window elapses (there is no restore endpoint, so we
    /// must not hit the network until the user has had the chance to undo). Undo
    /// cancels the pending delete and re-inserts the row in place.
    public func delete(_ record: AllergyDTO, undoMessage: String) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records.remove(at: index)
        lastError = nil

        // Cancel any earlier pending delete for the same id (defensive — a
        // re-delete before the first committed).
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

    /// Undo path: cancel the deferred network delete (nothing reached the server)
    /// and re-insert the row in place — the record is preserved losslessly.
    private func cancelPendingDelete(_ record: AllergyDTO, originalIndex: Int) {
        pendingDeletes[record.id]?.cancel()
        pendingDeletes[record.id] = nil
        if !records.contains(where: { $0.id == record.id }) {
            records.insert(record, at: min(originalIndex, records.count))
        }
    }

    /// Fire the deferred network delete once the undo window has elapsed. A
    /// retriable failure was durably enqueued by the repo (replays at
    /// reachability; soft-delete is tombstone-idempotent), so the row stays
    /// removed. A genuine non-retriable failure restores the row + surfaces an
    /// honest error.
    private func commitDelete(_ record: AllergyDTO, originalIndex: Int) async {
        pendingDeletes[record.id] = nil
        do {
            _ = try await repository.delete(id: record.id)
        } catch let err as HLError where err.shouldPersistToOutbox {
            // Durably queued — keep the optimistic removal; the outbox replays it.
            return
        } catch {
            if AllergiesRepository.isNotFound(error) { return } // already gone — benign
            if !records.contains(where: { $0.id == record.id }) {
                records.insert(record, at: min(originalIndex, records.count))
            }
            applyError(error)
        }
    }

    // MARK: - Logout

    /// Drop every in-memory snapshot + cancel pending deletes on logout so the
    /// next user never inherits the previous user's allergies (PHI).
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

    /// Test-only — populate the in-memory snapshot without a network round-trip so
    /// the logout-wipe suite can prove `clearOnLogout` purges the PHI.
    func seedForTesting(records: [AllergyDTO]) {
        self.records = records
    }

    // MARK: - Private

    /// Build an optimistic in-memory row for an offline-queued create (H3). Carries
    /// a temporary `optimistic-…` id so it never collides with a server id; the
    /// next online reload replaces the whole snapshot with the server records
    /// (under the same idempotency key), so the placeholder is transient.
    private static func optimisticAllergy(from body: AllergyCreate, id: String) -> AllergyDTO {
        let now = ISO8601DateFormatter().string(from: Date.now)
        return AllergyDTO(
            id: id,
            substance: body.substance,
            category: body.category ?? .other,
            type: body.type ?? .allergy,
            severity: body.severity,
            status: body.status ?? .active,
            onsetAt: body.onsetAt,
            reaction: body.reaction,
            note: body.note,
            createdAt: now,
            updatedAt: now
        )
    }

    private func applyError(_ error: Error) {
        lastError = LogSanitizer.redact(String(describing: error))
    }
}
