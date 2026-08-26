import Foundation
import SwiftData

/// Persistent SWR cache. Hidden behind the `SWRCoordinator` for callers —
/// most code shouldn't touch this directly, but it's `public` so
/// `AppContainer` can wire one instance and tests can hit the read/write
/// boundary in isolation.
///
/// Single `@Model` schema (`CachedSnapshot`) keyed by `CacheKey.persistentHash`.
/// Payload is `JSONEncoder.hlDefault`-encoded value-type at write time and
/// `JSONDecoder.hlDefault`-decoded at read time. The actor isolation matches
/// the proven `OutboxStore` pattern (ADR-011 + swift-concurrency skill).
@ModelActor
public actor SWRCache {
    /// **21-02 — the read primitive. Fetch only; the payload is NOT decoded here.**
    ///
    /// Returns the stored bytes plus the row's write instant, and `nil` for a
    /// missing row or a row whose `schemaVersion` no longer matches (dropped
    /// lazily, exactly as before).
    ///
    /// This exists because `SWRCache` is a `@ModelActor` and its executor is
    /// serial. 21-01 measured what that costs: across an eight-surface
    /// foreground fan-out, **zero** pairs of distinct keys ever decoded at the
    /// same instant, and 99% of a small surface's first paint was spent waiting
    /// for other keys' decodes. The `modelContext.fetch` genuinely has to
    /// happen here — SwiftData confines the context to this actor and a
    /// `CachedSnapshot` must never cross the boundary — but the decode does
    /// not. `Data` and `Date` are `Sendable`, so they cross, and
    /// `SWRCoordinator` decodes on its own task.
    ///
    /// Callers that want the decoded value and do not care where the work runs
    /// can still use ``read(_:as:)``; the first-paint path deliberately does
    /// not.
    public func readPayload(_ key: CacheKey) -> Cached<Data>? {
        let hash = key.persistentHash
        let descriptor = FetchDescriptor<CachedSnapshot>(
            predicate: #Predicate { $0.keyHash == hash }
        )
        guard let row = SWRSignpost.measure(.readFetch, key: key.canonicalString, {
            try? modelContext.fetch(descriptor).first
        }) else { return nil }
        guard row.schemaVersion == CacheSchemaV1.currentSchemaVersion else {
            // Drop stale-schema row in the background; treat as cache-miss now.
            modelContext.delete(row)
            do {
                try modelContext.save()
            } catch {
                HLLog.cache.error(
                    "Stale-schema cache row delete save failed: \(LogSanitizer.redact(String(describing: error)))"
                )
            }
            return nil
        }
        // `row.payloadData` is copied out here, while still on the actor. The
        // `CachedSnapshot` itself does not escape.
        return Cached(value: row.payloadData, updatedAt: row.updatedAt)
    }

    /// Read a key **and decode it on this actor**.
    ///
    /// Convenience for callers that are not on a first-paint path — and for
    /// the suites that pin the round-trip. It is deliberately NOT what
    /// `SWRCoordinator.observe` uses: decoding here holds the serial executor
    /// for the duration, which is the contention 21-02 removed. If a future
    /// production caller reaches for this on a hot path,
    /// `SWRCacheContentionTests` is the test that will say so.
    ///
    /// Returns `nil` for a missing row, a stale-schema row, or a decode failure
    /// (treated as a cache-miss; the row is left in place so a successful
    /// future write replaces it idempotently).
    public func read<T: Decodable & Sendable>(_ key: CacheKey, as _: T.Type) -> Cached<T>? {
        guard let raw = readPayload(key) else { return nil }
        guard let value: T = Self.decodePayload(raw.value, key: key, as: T.self) else { return nil }
        return Cached(value: value, updatedAt: raw.updatedAt)
    }

    /// The one definition of "decode a cached payload", shared by the
    /// actor-side convenience above and by `SWRCoordinator`'s off-actor path,
    /// so the two cannot drift in what a decode failure means.
    ///
    /// `nonisolated` and `static`: it touches no actor state, so it runs
    /// wherever its caller runs — on the actor for ``read(_:as:)``, on the
    /// observing task for the first-paint path.
    nonisolated static func decodePayload<T: Decodable & Sendable>(
        _ payload: Data,
        key: CacheKey,
        as _: T.Type
    ) -> T? {
        do {
            return try SWRSignpost.measure(
                .readDecode,
                key: key.canonicalString,
                bytes: payload.count
            ) {
                try JSONDecoder.hlDefault.decode(T.self, from: payload)
            }
        } catch {
            // Cache keys are enum-shaped canonical paths (no user data) — operator-grade.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.cache.warning("Cache decode failed for \(key.canonicalString, privacy: .public)")
            return nil
        }
    }

    /// Write a key → value. Idempotent on the unique `keyHash` constraint.
    public func write(_ key: CacheKey, payload: Data, at now: Date = .now) throws {
        let hash = key.persistentHash
        let descriptor = FetchDescriptor<CachedSnapshot>(
            predicate: #Predicate { $0.keyHash == hash }
        )
        if let row = try modelContext.fetch(descriptor).first {
            row.payloadData = payload
            row.updatedAt = now
            row.schemaVersion = CacheSchemaV1.currentSchemaVersion
        } else {
            modelContext.insert(CachedSnapshot(
                keyHash: hash,
                payloadData: payload,
                updatedAt: now
            ))
        }
        try modelContext.save()
    }

    /// Invalidate one or more keys — silently no-ops for misses.
    public func invalidate(_ keys: [CacheKey]) throws {
        for key in keys {
            let hash = key.persistentHash
            let descriptor = FetchDescriptor<CachedSnapshot>(
                predicate: #Predicate { $0.keyHash == hash }
            )
            for row in try modelContext.fetch(descriptor) {
                modelContext.delete(row)
            }
        }
        try modelContext.save()
    }

    /// Wipe every row. Called on logout / account-deletion so the next user
    /// never sees the previous user's cached data through a hot launch.
    public func invalidateAll() throws {
        let descriptor = FetchDescriptor<CachedSnapshot>()
        for row in try modelContext.fetch(descriptor) {
            modelContext.delete(row)
        }
        try modelContext.save()
    }

    /// Sweep rows older than `maxAge` — keeps the SQLite bounded for power
    /// users who churn through many series-day combinations. Returns the
    /// number of rows dropped (caller can log).
    ///
    /// **AUD-8 L-4** — uses SwiftData's batch-delete predicate
    /// (`delete(model:where:)`) instead of fetch-all-then-per-row-delete, so a
    /// large expired set is dropped without materialising every row into memory.
    @discardableResult
    public func sweepOlderThan(_ maxAge: TimeInterval, now: Date = .now) throws -> Int {
        // 21-01 — a sweep is a member of the same foreground pass as every
        // surface's first read AND runs on the same serial executor, so its
        // cost is charged to whichever first paint is queued behind it. Timed
        // so that cost stops being an argument and becomes a number.
        try SWRSignpost.measure(.sweep, key: "sweepOlderThan") {
            let threshold = now.addingTimeInterval(-maxAge)
            let countBefore = try rowCount()
            try modelContext.delete(
                model: CachedSnapshot.self,
                where: #Predicate { $0.updatedAt < threshold }
            )
            try modelContext.save()
            let dropped = try countBefore - rowCount()
            return max(0, dropped)
        }
    }

    /// **AUD-8 H-1** — hard row-count cap. Evicts the OLDEST rows beyond
    /// `maxRows` (least-recently-written first, by `updatedAt`) so the cache
    /// SQLite can never grow unbounded for a power user who opens many
    /// metric/day/period combinations — the budget guard the age-sweep alone
    /// could not provide (the age-sweep only runs on a BGTask wake, which never
    /// fires with Background-App-Refresh off).
    ///
    /// Returns the number of rows evicted. No-op (returns 0) when at/below the
    /// cap. Uses a batch-delete keyed on a cutoff `updatedAt` so the eviction is
    /// one SQLite statement, not N per-row deletes (AUD-8 L-4).
    @discardableResult
    public func sweepKeepingNewest(maxRows: Int) throws -> Int {
        // 21-01 — timed for the same reason as `sweepOlderThan`. The early
        // `return 0` exits are inside the interval on purpose: a sweep that
        // decides to do nothing still took the executor to decide it, and a
        // first paint queued behind that decision still waited for it.
        try SWRSignpost.measure(.sweep, key: "sweepKeepingNewest") {
            guard maxRows > 0 else { return 0 }
            let total = try rowCount()
            guard total > maxRows else { return 0 }

            // Find the cutoff: the `updatedAt` of the newest row we must DROP. Fetch
            // just the timestamps ascending and pick the boundary so everything at
            // or below it is evicted. (Fetching `updatedAt` only — not payloads —
            // keeps the boundary scan cheap.)
            var ascending = FetchDescriptor<CachedSnapshot>(
                sortBy: [SortDescriptor(\.updatedAt, order: .forward)]
            )
            ascending.propertiesToFetch = [\.updatedAt]
            let dropCount = total - maxRows
            ascending.fetchLimit = dropCount
            let oldestRows = try modelContext.fetch(ascending)
            guard let cutoff = oldestRows.last?.updatedAt else { return 0 }

            let countBefore = try rowCount()
            // Evict every row at or before the cutoff. Ties on the exact cutoff
            // instant may evict slightly more than `dropCount` — acceptable for a
            // best-effort bound and far cheaper than per-row id deletes.
            try modelContext.delete(
                model: CachedSnapshot.self,
                where: #Predicate { $0.updatedAt <= cutoff }
            )
            try modelContext.save()
            let evicted = try countBefore - rowCount()
            return max(0, evicted)
        }
    }

    /// Current persisted row count — used by the sweep/cap bookkeeping.
    public func rowCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<CachedSnapshot>())
    }
}

// MARK: - ModelContainer factories

public extension SWRCache {
    /// Production initializer: persistent SQLite under `Application Support`,
    /// no CloudKit, file-protection `.completeUntilFirstUserAuthentication`.
    /// Mirrors `OutboxStore.makePersistent()` exactly so BGProcessingTask
    /// wakeups that touch the cache observe the same security envelope.
    static func makePersistent() throws -> ModelContainer {
        let storeURL = try persistentStoreURL()
        let schema = Schema(versionedSchema: CacheSchemaV1.self)
        let config = ModelConfiguration(
            "HealthLogCache",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: schema,
            migrationPlan: nil,
            configurations: [config]
        )
        try? applyFileProtection(to: storeURL)
        return container
    }

    /// Test initializer: in-memory only, zero I/O.
    static func makeInMemory() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CacheSchemaV1.self)
        let config = ModelConfiguration(
            "HealthLogCache.test",
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: nil,
            configurations: [config]
        )
    }

    /// `<sandbox>/Library/Application Support/HealthLog/Cache/cache.sqlite`.
    /// Sibling of `Outbox/outbox.sqlite` per A2-Audit §5.
    static func persistentStoreURL() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("HealthLog/Cache", isDirectory: true)
        try SensitiveDataBackupExclusion.prepareDirectory(at: dir, fileManager: fm)
        return dir.appendingPathComponent("cache.sqlite")
    }

    /// Same `.completeUntilFirstUserAuthentication` envelope as Outbox
    /// (ADR-012). Required for BGProcessingTask wakeups that may run before
    /// first device unlock after reboot.
    static func applyFileProtection(to storeURL: URL) throws {
        let fm = FileManager.default
        let candidates = [
            storeURL,
            storeURL.appendingPathExtension("shm"),
            storeURL.appendingPathExtension("wal")
        ]
        for url in candidates where fm.fileExists(atPath: url.path) {
            try fm.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        }
    }
}
