import Foundation

/// Build 273 — the persist path and the per-key write generation (A9), split
/// out of the actor file so its type body stays under the length rule.
extension SWRCoordinator {
    func writeGeneration(_ key: CacheKey) -> Int {
        writeGenerations[key.persistentHash, default: 0]
    }

    func bumpWriteGeneration(_ key: CacheKey) {
        writeGenerations[key.persistentHash, default: 0] += 1
    }

    func fetchAndWriteThrough<T: Codable & Sendable>(
        _ key: CacheKey,
        cache: SWRCache,
        epoch: Int,
        fetch: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let generation = writeGeneration(key)
        let fresh = try await fetch()
        // A9 — a write-through or invalidate landed while this fetch was in
        // flight; the fetched payload is older than the disk. Hand the value to
        // the caller, but do not persist it.
        guard generation == writeGeneration(key) else {
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.cache.notice(
                "SWR persist skipped for \(key.canonicalString, privacy: .public): key written during revalidation"
            )
            return fresh
        }
        // Re-check on the actor AFTER the fetch — `sessionEpoch` reads here are
        // serialized with `invalidateAll()`'s bump, so a purge that landed
        // mid-fetch is observed before we write.
        guard epoch == sessionEpoch else {
            // Cache keys are enum-shaped canonical paths (no user data) — operator-grade.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.cache.notice(
                "SWR write-through dropped post-invalidate for \(key.canonicalString, privacy: .public) (stale session)"
            )
            return fresh
        }
        // W-PERF-SWR C2 — encode on the actor (cheap, keeps `fresh` off the
        // detached closure's Sendable surface), then persist on a detached
        // low-priority task so the on-screen repaint isn't blocked by the
        // SwiftData `save()` flush. Errors are logged inside the task, never
        // awaited. The fresh value is already in the in-memory store via this
        // return; the detached write only backfills cold-read correctness.
        do {
            let payload = try JSONEncoder.hlDefault.encode(fresh)
            schedulePersist(key, payload: payload, cache: cache, epoch: epoch)
        } catch {
            // Cache keys are enum-shaped canonical paths (no user data) — operator-grade.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.cache.warning("Cache encode failed for \(key.canonicalString, privacy: .public)")
        }
        return fresh
    }

    func schedulePersist(
        _ key: CacheKey,
        payload: Data,
        cache: SWRCache,
        epoch: Int
    ) {
        let id = UUID()
        let task = Task(priority: .utility) { [weak self] in
            // Re-check the epoch on the actor — a purge could have landed after
            // the synchronous encode but before this detached task ran.
            guard let self else { return }
            guard await epochIsCurrent(epoch) else {
                await finishPendingWrite(id)
                return
            }
            do {
                try await cache.write(key, payload: payload)
            } catch {
                // Cache keys are enum-shaped canonical paths (no user data) — operator-grade.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.cache.warning("Cache write failed for \(key.canonicalString, privacy: .public)")
            }
            await finishPendingWrite(id)
        }
        pendingWrites[id] = task
    }

    func epochIsCurrent(_ epoch: Int) -> Bool {
        epoch == sessionEpoch
    }
}
