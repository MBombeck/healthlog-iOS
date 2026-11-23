import Foundation
import SwiftData

/// The durability surface of `OutboxQueue`:
///   * **G-1** write-ahead (`writeAhead(_:now:send:)`) — persist BEFORE the network
///     send so a crash mid-send leaves exactly one replayable entry under the
///     same idempotency key (no double-write on re-action).
///   * **G-9** corrupt-vs-unavailable recovery (`recoverOrDegrade()`) — the
///     persistent-store open ladder fails soft (destroys nothing) on a
///     transient/locked failure and only moves a genuinely-corrupt store aside
///     (rename, never `rm`).
///
/// Split out of `OutboxQueue.swift` purely for file_length discipline — this is
/// a behaviour-neutral move of new code into a thematic extension.
extension OutboxQueue {
    // MARK: - G-9 recovery ladder

    /// Tries the persistent store; on failure it classifies the failure and
    /// recovers **without destroying un-synced writes on a merely-transient
    /// failure**.
    ///
    /// Returning a non-throwing handle is intentional: a corrupted offline store
    /// is bad, but crashing the app at launch over it is worse.
    ///
    /// **Phase 09 / plan 09-05 moved *when* this runs, not *what* it does.** It
    /// used to be called from `AppContainer.init` so `BGTaskScheduler.register`
    /// could stay in the same event-loop tick; the two were only ever coupled by
    /// that shared tick, never by a real dependency. Registration is still
    /// synchronous, and this ladder now runs behind `OutboxQueue`'s single-flight
    /// handle — on the first operation, or on the explicit warm-up the ordinary
    /// foreground bootstrap performs after the first frame. It therefore returns
    /// the opened container rather than a whole queue, and it is `nonisolated`
    /// so it can run on a detached executor instead of on whoever asked first.
    ///
    /// **The G-9 fix.** The previous implementation `rm`-ed the entire `Outbox/`
    /// directory on ANY open failure — including a transient `BGProcessingTask`
    /// wake before first unlock, where the
    /// `completeUntilFirstUserAuthentication`-protected store is simply
    /// unreadable *right now*. That irreversibly destroyed queued writes that
    /// would have opened fine on the next foreground launch. Now:
    ///
    ///   * **transient** (no file, or file sealed by data protection / locked):
    ///     FAIL SOFT — degrade to an in-memory store for this process WITHOUT
    ///     deleting anything. The on-disk store is untouched, so the queued
    ///     writes survive and the next clean launch opens + replays them.
    ///   * **corrupt** (file readable but rejected by Core Data/SQLite): MOVE
    ///     ASIDE — rename (never `rm`) the store + sidecars to a timestamped
    ///     `*.corrupt-<epoch>.*` set so the bytes survive for recovery, then
    ///     retry once against a fresh store.
    nonisolated static func recoverOrDegradeStore() -> StoreHandle {
        recoverOrDegradeStore(
            openPersistent: OutboxStore.makePersistent,
            persistentStoreURL: { try? OutboxStore.persistentStoreURL() },
            moveAside: { ModelContainerRecovery.moveAsideCorruptStore(at: $0, log: HLLog.outbox, subsystem: "Outbox") }
        )
    }

    /// The ladder itself, with its three side-effecting steps injected.
    ///
    /// The seams exist so the classification, the move-aside and the single
    /// retry can be driven deterministically without a real corrupt SQLite file
    /// on the simulator's Application Support directory. The live entry point
    /// above supplies exactly the production three, so the tested function and
    /// the shipped function are the same function.
    nonisolated static func recoverOrDegradeStore(
        openPersistent: () throws -> ModelContainer,
        persistentStoreURL: () -> URL?,
        moveAside: (URL) -> Bool
    ) -> StoreHandle {
        do {
            return try StoreHandle(container: openPersistent())
        } catch {
            let storeURL = persistentStoreURL()
            switch ModelContainerRecovery.classifyOpenFailure(error, storeURL: storeURL) {
            case .transient:
                // Do NOT delete. The bytes are (almost certainly) fine and
                // sealed/locked right now — destroying them would be the G-9
                // data-loss bug. Degrade this process to an inert in-memory
                // store; the next clean launch reopens the on-disk store and
                // replays the queued writes.
                HLLog.outbox.error(
                    "Outbox store unavailable (transient — not deleting): \(LogSanitizer.redact(String(describing: error)))"
                )
                return inMemoryFallback()
            case .corrupt:
                HLLog.outbox.error(
                    "Outbox store corrupt, moving aside (not deleting): \(LogSanitizer.redact(String(describing: error)))"
                )
                if let storeURL { _ = moveAside(storeURL) }
                do {
                    return try StoreHandle(container: openPersistent())
                } catch {
                    HLLog.outbox.error(
                        "Outbox rebuild after move-aside failed, falling back to in-memory: \(LogSanitizer.redact(String(describing: error)))"
                    )
                    return inMemoryFallback()
                }
            }
        }
    }

    /// Non-trapping in-memory floor (audit M2): degrade to an inert empty-schema
    /// store instead of `try!`-trapping on the very path that exists to avoid a
    /// hard launch failure.
    private nonisolated static func inMemoryFallback() -> StoreHandle {
        StoreHandle(container: ModelContainerRecovery.recoveredInMemoryContainer(
            log: HLLog.outbox,
            subsystem: "Outbox",
            build: OutboxStore.makeInMemory
        ))
    }

    // MARK: - G-1 write-ahead durability

    /// Kinds whose re-send does no harm at any age, because the server does
    /// not rely on the 24-hour key cache to fold them: a delete or restore, an
    /// edit that addresses one existing row by its id (or the one settings
    /// row of the account), a write the server upserts on its day (cycle and
    /// illness day logs), a medication intake (folded on medication and
    /// planned time, and on the key the server stores with the row), a coach
    /// answer the server skips when it is already on file, and what the
    /// server folds by `externalId`.
    ///
    /// Every other kind creates a record, or adds to a total, that the server
    /// only recognises through its idempotency cache. Those rows are written
    /// "sent, unconfirmed" (see ``writeAhead(_:now:send:)``), so a row that
    /// outlives the cache is held back instead of going out a second time.
    static let resendSafeAtAnyAge: Set<Operation.Kind> = OutboxReplayService.deleteKinds
        .union(OutboxReplayService.externalIdDedupedKinds)
        .union([
            .takeMedication, .logMedicationIntake, .updateIntake,
            .updateMeasurement, .updateMood, .updateMedication, .updateMedicationInventory,
            .updateThresholds, .updateInsightsLayout,
            .logCycleDayLog, .updateCycleDayLog, .cyclePeriod,
            .updateLab, .restoreLabs, .updateBiomarker,
            .updateIllnessEpisode, .restoreIllnessEpisode, .resolveIllnessEpisode, .upsertIllnessDayLog,
            .updateAllergy, .updateFamilyHistory, .updateCustomMetric, .updateCustomMetricEntry,
            .coachAboutMeAdopt, .coachAboutMeDismissQuestion
        ])

    /// **Write-ahead**: the write is on disk before the request leaves, so no
    /// point in time exists at which it is neither stored nor sent.
    ///
    /// In order:
    ///   1. Persist `op`. From here on a crash leaves exactly one row, and the
    ///      replay sends it under the SAME idempotency key the live request
    ///      carried, so the server folds it onto a request that had landed.
    ///   2. Run `send()`.
    ///   3. Landed: remove the row.
    ///   4. A failure worth a retry (`shouldPersistToOutbox`): the row stays
    ///      and the error is re-thrown, so the caller reports "queued".
    ///   5. Any other failure (refused, cancelled, unreadable): the row is
    ///      removed and the error re-thrown.
    ///
    /// While the process lives, the queue therefore ends up exactly as it did
    /// when the row was only written after a failed send. The one new state is
    /// the row of step 1 found after a restart.
    ///
    /// That row may or may not have reached the server. A kind the server
    /// folds by itself goes out again whenever. Every other kind is written
    /// with the "sent, unconfirmed" note, which holds it back once the
    /// server's key cache can no longer recognise it. The note comes off when
    /// the send fails without having left the device, and stays when the
    /// request was cut off or its answer never came.
    ///
    /// If step 1 fails there is no safety net, and that is said honestly: a
    /// retry-worthy send failure then throws `HLError.notPersisted`, so the
    /// caller rolls back instead of reporting "queued". A send that succeeds
    /// needed no net.
    ///
    /// The row is not announced to observers unless it stays, and the replay
    /// does not touch it while this call runs (``isReplayable(_:)``).
    func writeAhead<Result: Sendable>(
        _ op: Operation,
        now: Date = .now,
        send: @Sendable () async throws -> Result
    ) async throws -> Result {
        liveSendIDs.insert(op.id)
        defer { liveSendIDs.remove(op.id) }
        let heldToWindow = !Self.resendSafeAtAnyAge.contains(op.kind)
        var row = op
        if heldToWindow { row.lastError = OutboxReplayService.unconfirmedMarker(op, now: now) }
        let seenAtStart = broadcastGeneration
        var persisted = false
        do {
            try await enqueueUnannounced(row)
            persisted = true
        } catch {
            // No safety net. The honest signal follows below if the send
            // fails in a way that would have needed one.
            HLLog.outbox.error("Write-ahead enqueue failed: \(LogSanitizer.redact(String(describing: error)))")
        }
        do {
            let result = try await send()
            if persisted { await settleLanded(op.id, seenAtStart: seenAtStart) }
            return result
        } catch let err as HLError where err.shouldPersistToOutbox {
            guard persisted else { throw HLError.notPersisted(String(describing: err)) }
            // Never left the device: an ordinary queued row. A failed clear
            // leaves the note on, which only ever holds a row back.
            if heldToWindow, !Self.mayHaveLeftTheDevice(err, kind: op.kind) {
                try? await resolvedStore().clearLastError(id: op.id)
            }
            await broadcast()
            throw err
        } catch {
            if persisted {
                try? await removeUnannounced(id: op.id)
                if broadcastGeneration != seenAtStart { await broadcast() }
            }
            throw error
        }
    }

    /// Whether a failed first send may have reached the server. A request cut
    /// off on the wire while its task lived had left the device as surely as
    /// one whose answer never came. The replay asks a narrower question
    /// (``OutboxReplayService/mayHaveLanded(_:kind:)``): a cut-off request
    /// stops its pass there and leaves the row as it was.
    private static func mayHaveLeftTheDevice(_ error: HLError, kind: Operation.Kind) -> Bool {
        error == .network(.writeCancelled) || OutboxReplayService.mayHaveLanded(error, kind: kind)
    }

    /// The server has the write: the row goes. A row that cannot be removed
    /// is at least stamped delivered, so it is never sent again.
    private func settleLanded(_ id: UUID, seenAtStart: UInt64) async {
        do {
            try await removeUnannounced(id: id)
        } catch {
            HLLog.outbox.error("Write-ahead remove failed: \(LogSanitizer.redact(String(describing: error)))")
            try? await resolvedStore().markDelivered(id: id)
        }
        // Only when an observer was told about the row in the meantime.
        if broadcastGeneration != seenAtStart { await broadcast() }
    }

    /// Whether the replay may send this row now: not while its first send is
    /// still running, and not once it is gone (a snapshot can be older than a
    /// row that has landed since). A store that cannot answer does not hold a
    /// row back.
    func isReplayable(_ id: UUID) async -> Bool {
        if liveSendIDs.contains(id) { return false }
        return await (try? resolvedStore().exists(id: id)) ?? true
    }
}
