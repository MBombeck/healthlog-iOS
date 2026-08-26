import Foundation
import SwiftData

/// W-INTEGRITY-WRITEPATH — the durability surface of `OutboxQueue`:
///   * **G-1** write-ahead (`writeAhead(_:send:)`) — persist BEFORE the network
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

    /// **Write-ahead** durability for an optimistic write whose loss on a
    /// crash-mid-send is unacceptable (the worst case is the background
    /// "Genommen" notification action, which has no UI recovery).
    ///
    /// Contract, in order:
    ///   1. Persist `op` to the durable store **before** the network call, so a
    ///      crash anywhere after this point leaves exactly one replayable entry
    ///      carrying the SAME idempotency key (no fresh key minted on re-action
    ///      → no double-write; server dedups the eventual replay against the
    ///      original attempt that may have already landed).
    ///   2. Run `send()` (the `api.send(...)`).
    ///   3. On success: remove the entry — the write reached the server, nothing
    ///      to replay. Returns normally.
    ///   4. On a `shouldPersistToOutbox` failure: **keep** the entry (already
    ///      durably queued) and re-throw the original error so the caller can
    ///      surface the deferred/queued state. Replay drains it later.
    ///   5. On a non-retriable failure (server understood + rejected, decode,
    ///      cancel): **remove** the entry and re-throw — replaying a rejected op
    ///      forever is strictly worse than surfacing the error.
    ///
    /// If the write-ahead persist in step 1 itself fails, we degrade to a
    /// best-effort send WITHOUT a durable safety net and signal that honestly:
    /// a subsequent retriable send-failure throws `HLError.notPersisted` (G-2)
    /// so the caller rolls back instead of claiming "queued"; a successful send
    /// still returns normally (the entry would have been a no-op anyway).
    ///
    /// - Parameters:
    ///   - op: the operation to persist write-ahead. Its `idempotencyKey` is the
    ///     single key reused across the live send, any crash-replay, and the
    ///     reachability-replay — the idempotency contract is preserved end to end.
    ///   - send: the network call. Throws `HLError` on failure.
    func writeAhead<Result: Sendable>(
        _ op: Operation,
        send: @Sendable () async throws -> Result
    ) async throws -> Result {
        var persisted = false
        do {
            try await enqueue(op)
            persisted = true
        } catch {
            // Step 1 failed — no durable safety net. Log sanitized; the honest
            // failure signal happens below if the send also fails retriably.
            HLLog.outbox.error("Write-ahead enqueue failed: \(LogSanitizer.redact(String(describing: error)))")
        }
        do {
            let result = try await send()
            // Success — drop the durable entry if we managed to persist it.
            if persisted { try? await remove(id: op.id) }
            return result
        } catch let err as HLError {
            if persisted {
                if err.shouldPersistToOutbox {
                    // Keep the durable entry; replay drains it. Re-throw so the
                    // caller surfaces the queued/deferred state.
                    throw err
                }
                // Non-retriable reject — remove so it never replays.
                try? await remove(id: op.id)
                throw err
            }
            // Not persisted AND the send failed. If the failure was retriable
            // the write is now lost (no server, no queue) — surface that
            // honestly so the store rolls the optimistic state back. A
            // non-retriable failure is a genuine reject; surface it verbatim.
            throw err.shouldPersistToOutbox
                ? .notPersisted(String(describing: err))
                : err
        }
    }
}
