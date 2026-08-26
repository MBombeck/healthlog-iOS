import Foundation
import SwiftData

/// SwiftData-backed persistence for the outbox. Lives **behind** `OutboxQueue`'s
/// public actor — callers never see this type. Only Sendable value types
/// (`OutboxQueue.Operation`) cross the actor boundary in either direction; raw
/// `OutboxOperation` PersistentModel instances stay pinned to this actor's
/// `ModelContext`. See ADR-011 + the swift-concurrency skill for the rationale.
///
/// ## v0.6.2 W-SEC-A — at-rest encryption (M-4)
///
/// The on-disk `payload` blob is now AES-GCM-encrypted. The store
/// encrypts on `enqueue(...)` and decrypts on `snapshot()` — the
/// `OutboxOperationSnapshot.payload` exposed to callers (and downstream
/// `OutboxReplayService.dispatch`) is plaintext, matching the old
/// contract. Pre-v0.6.2 rows that survive on disk in plaintext form are
/// migrated lazily on the next `snapshot()` pass (read plaintext →
/// re-encrypt → save).
@ModelActor
public actor OutboxStore {
    /// Round-trip helper for the on-disk payload blob. Defaults to a
    /// real `KeychainStore`-backed cipher; tests inject a stub.
    /// Configurable post-construction via `useCipher(_:)` so the
    /// `@ModelActor`-generated initializer stays untouched.
    private var cipher: OutboxPayloadCipher = .init()

    /// Override the cipher used by this store. Used by unit tests to
    /// thread a deterministic / fault-injection cipher; production
    /// callers leave the default in place.
    public func useCipher(_ cipher: OutboxPayloadCipher) {
        self.cipher = cipher
    }

    /// Hydrate the entire queue, ordered oldest-first. The replay loop calls this
    /// once per pass. Legacy plaintext rows are migrated to ciphertext in-place.
    ///
    /// **v0.6.2.3 F3-SEC (A-CODE M-1):** decrypt failures (corrupt blob,
    /// missing key after a logout-wipe, tag-check mismatch, …) used to
    /// surface the raw ciphertext as the snapshot `payload`. The
    /// dispatcher then JSON-decoded the cipher bytes, hit a `DecodingError`
    /// non-retriable arm in `OutboxReplayService.runOnce`, and **silently
    /// dropped the row** with only the generic "verworfen" warning — no
    /// signal that the loss was due to decrypt failure vs. a real schema
    /// drift. The new branch deletes the row at the snapshot boundary,
    /// emits a distinct `decrypt failed for record …` log line under the
    /// `outbox` category, and skips the row from the returned slice so
    /// the dispatcher never sees the corruption.
    public func snapshot() throws -> [OutboxOperationSnapshot] {
        // audit-v0162 H1 (Opt 1) — dead-lettered rows are kept on disk for
        // recovery but MUST NOT replay: exclude them from the live snapshot so
        // the drain loop never re-fires them (only `resubmit` re-arms a row).
        let descriptor = FetchDescriptor<OutboxOperation>(
            predicate: #Predicate { !$0.deadLettered },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let rows = try modelContext.fetch(descriptor)
        var migrationNeedsSave = false
        var rowsToDelete: [OutboxOperation] = []
        var decryptFailureIDs: [UUID] = []
        var snapshots: [OutboxOperationSnapshot] = []
        snapshots.reserveCapacity(rows.count)
        for row in rows {
            // Two on-disk shapes can be present:
            //   * v0.6.2+ ciphertext  — version-tag 0x02 → decrypt
            //   * pre-v0.6.2 plaintext — JSON → return as-is + migrate
            // The migrate-on-read branch re-encrypts in place so the next
            // snapshot pass is uniform. `payload` on the returned snapshot
            // is always the plaintext the dispatcher expects.
            if OutboxPayloadCipher.isCiphertext(row.payload) {
                if let plain = try? cipher.decrypt(row.payload) {
                    snapshots.append(OutboxOperationSnapshot(from: row, overridePayload: plain))
                    continue
                }
                // Decrypt failure → delete the row in-place + collect the
                // id for an out-of-actor log emission. We deliberately do
                // NOT surface the raw bytes to the dispatcher (the legacy
                // behaviour) because the only thing the dispatcher can do
                // with a cipher-blob masquerading as plaintext is fail to
                // decode + silently drop — which is exactly the bug.
                decryptFailureIDs.append(row.id)
                rowsToDelete.append(row)
            } else {
                // Legacy plaintext row — capture the plaintext for the
                // returned snapshot BEFORE re-encrypting the persisted
                // row in place. The dispatcher needs plaintext; the
                // at-rest blob needs to converge to ciphertext.
                let plaintext = row.payload
                if let ciphertext = try? cipher.encrypt(plaintext) {
                    row.payload = ciphertext
                    migrationNeedsSave = true
                }
                snapshots.append(OutboxOperationSnapshot(from: row, overridePayload: plaintext))
            }
        }
        if !rowsToDelete.isEmpty {
            for row in rowsToDelete {
                modelContext.delete(row)
            }
            migrationNeedsSave = true
        }
        if migrationNeedsSave {
            // Best-effort: a failure here is logged outside the actor; the
            // snapshots returned to the caller still carry plaintext, so
            // the replay pass proceeds even if the migration save loses.
            try? modelContext.save()
        }
        // Emit one distinct line per corrupt row OUTSIDE the actor's hot
        // path. The `record` token in the message is the discriminator a
        // post-mortem grep keys off — generic "verworfen" warnings hit
        // every dispatcher-drop, but `decrypt failed for record …` only
        // appears on this exact code path.
        for id in decryptFailureIDs {
            // The outbox row id is a per-install random UUID, not a
            // user-bound or server-correlatable identifier — operator-grade
            // for post-mortem triage and matches the rest of the outbox
            // category's `.public` interpolation policy.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.outbox.error("decrypt failed for record \(id.uuidString, privacy: .public) — row deleted at snapshot boundary")
        }
        return snapshots
    }

    public func enqueue(
        id: UUID,
        kindRaw: String,
        payload: Data,
        idempotencyKey: String,
        createdAt: Date,
        attempts: Int = 0,
        ownerUserID: String? = nil,
        clientEntityId: String? = nil
    ) throws {
        let ciphertext = try cipher.encrypt(payload)
        let op = OutboxOperation(
            id: id,
            kindRaw: kindRaw,
            payload: ciphertext,
            idempotencyKey: idempotencyKey,
            createdAt: createdAt,
            attempts: attempts,
            ownerUserID: ownerUserID,
            clientEntityId: clientEntityId
        )
        modelContext.insert(op)
        try modelContext.save()
    }

    public func delete(id: UUID) throws {
        let descriptor = FetchDescriptor<OutboxOperation>(
            predicate: #Predicate { $0.id == id }
        )
        if let op = try modelContext.fetch(descriptor).first {
            modelContext.delete(op)
            try modelContext.save()
        }
    }

    public func incrementAttempts(id: UUID, lastError: String?) throws {
        let descriptor = FetchDescriptor<OutboxOperation>(
            predicate: #Predicate { $0.id == id }
        )
        guard let op = try modelContext.fetch(descriptor).first else { return }
        op.attempts += 1
        op.lastAttemptAt = .now
        if let lastError {
            op.lastError = String(lastError.prefix(256))
        }
        try modelContext.save()
    }

    /// **audit-v0162 H1 (Opt 3) — record a replay attempt WITHOUT burning the
    /// attempt counter.** Used when the failure is a server-side 5xx/429 while
    /// the health-probe reports the server is KNOWN-degraded: the write did not
    /// fail on its own merits, so counting it toward `maxAttempts` would
    /// dead-letter a perfectly-good PHI write during a server outage. We still
    /// stamp `lastAttemptAt` (for the back-off window) and the last error.
    public func touchAttempt(id: UUID, lastError: String?) throws {
        let descriptor = FetchDescriptor<OutboxOperation>(
            predicate: #Predicate { $0.id == id }
        )
        guard let op = try modelContext.fetch(descriptor).first else { return }
        op.lastAttemptAt = .now
        if let lastError {
            op.lastError = String(lastError.prefix(256))
        }
        try modelContext.save()
    }

    /// **audit-v0162 H-4 — remap an optimistic id to the server id in place.**
    /// After a queued `create` replays and the server assigns a real id, every
    /// sibling row whose `clientEntityId` still carries the `optimistic-<uuid>`
    /// is rewritten to the server id so its dependent `update`/`delete` addresses
    /// the real record on replay (via `OutboxReplayService.resolveEntityId`),
    /// instead of 404-ing on the stale optimistic id. Returns the number of rows
    /// rewritten. Persisted, so the remap survives across replay passes / app
    /// restarts even if the dependent op has not yet drained.
    @discardableResult
    public func applyEntityRemap(from optimisticId: String, to serverId: String) throws -> Int {
        let descriptor = FetchDescriptor<OutboxOperation>(
            predicate: #Predicate { $0.clientEntityId == optimisticId }
        )
        let rows = try modelContext.fetch(descriptor)
        guard !rows.isEmpty else { return 0 }
        for row in rows {
            row.clientEntityId = serverId
        }
        try modelContext.save()
        return rows.count
    }

    /// Drops every row in the outbox. Used by the account-deletion cascade so
    /// no pending POSTs leak from the freshly-deleted account into the next
    /// session (a re-login would otherwise replay them and 401, but we'd rather
    /// not even try). Idempotent — empty store stays empty.
    public func deleteAll() throws {
        let descriptor = FetchDescriptor<OutboxOperation>()
        let rows = try modelContext.fetch(descriptor)
        guard !rows.isEmpty else { return }
        for row in rows {
            modelContext.delete(row)
        }
        try modelContext.save()
    }

    /// **audit-v0162 H1 (Opt 3 + Opt 1) — gated dead-lettering.** Flags (does
    /// NOT delete) every live row that has BOTH exhausted its retry budget
    /// (`attempts >= maxAttempts`) AND aged past the wall-clock window
    /// (`now - createdAt >= minAge`). The dual gate stops a transient burst of
    /// failures — several attempts consumed within minutes across rapid replay
    /// triggers — from dead-lettering a PHI write that is only days-worth of
    /// retries from succeeding: age is the real signal that the write is
    /// genuinely stuck, attempts alone is not. Flagged rows are kept on disk
    /// (recoverable via `resubmit`) but excluded from the replay snapshot.
    /// Returns the snapshots of rows NEWLY dead-lettered by this call so the
    /// caller can log + surface an honest failure count.
    public func markDeadLetters(maxAttempts: Int, minAge: TimeInterval, now: Date) throws -> [OutboxOperationSnapshot] {
        let threshold = maxAttempts
        let descriptor = FetchDescriptor<OutboxOperation>(
            predicate: #Predicate { $0.attempts >= threshold && !$0.deadLettered }
        )
        let candidates = try modelContext.fetch(descriptor)
        let due = candidates.filter { now.timeIntervalSince($0.createdAt) >= minAge }
        guard !due.isEmpty else { return [] }
        let snapshots = due.map { row -> OutboxOperationSnapshot in
            if OutboxPayloadCipher.isCiphertext(row.payload),
               let plain = try? cipher.decrypt(row.payload)
            {
                return OutboxOperationSnapshot(from: row, overridePayload: plain)
            }
            return OutboxOperationSnapshot(from: row)
        }
        for row in due {
            row.deadLettered = true
            row.deadLetteredAt = now
        }
        try modelContext.save()
        return snapshots
    }

    /// Count of dead-lettered (recoverable, non-replaying) rows — drives the
    /// honest "N Einträge konnten nicht übermittelt werden" surface.
    public func deadLetterCount() throws -> Int {
        let descriptor = FetchDescriptor<OutboxOperation>(
            predicate: #Predicate { $0.deadLettered }
        )
        return try modelContext.fetchCount(descriptor)
    }

    /// Snapshots of every dead-lettered row (for a diagnostics / re-submit
    /// surface). Includes rows the live `snapshot()` deliberately excludes.
    public func deadLetteredSnapshots() throws -> [OutboxOperationSnapshot] {
        let descriptor = FetchDescriptor<OutboxOperation>(
            predicate: #Predicate { $0.deadLettered },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let rows = try modelContext.fetch(descriptor)
        return rows.map { row in
            if OutboxPayloadCipher.isCiphertext(row.payload),
               let plain = try? cipher.decrypt(row.payload)
            {
                return OutboxOperationSnapshot(from: row, overridePayload: plain)
            }
            return OutboxOperationSnapshot(from: row)
        }
    }

    /// **audit-v0162 H1 (Opt 1) — manual re-submit of a dead-lettered row.**
    /// Clears the flag and resets the retry budget so the next replay pass
    /// picks the row up again. Returns `true` when a matching dead-lettered row
    /// was re-armed. The persisted idempotency key is untouched, so a
    /// re-submit-after-the-original-actually-landed is still server-deduped.
    @discardableResult
    public func resubmit(id: UUID) throws -> Bool {
        let descriptor = FetchDescriptor<OutboxOperation>(
            predicate: #Predicate { $0.id == id && $0.deadLettered }
        )
        guard let op = try modelContext.fetch(descriptor).first else { return false }
        op.deadLettered = false
        op.deadLetteredAt = nil
        op.attempts = 0
        op.lastAttemptAt = nil
        op.lastError = nil
        try modelContext.save()
        return true
    }
}

/// Sendable mirror of an `OutboxOperation` row. `OutboxStore` returns these
/// instead of raw PersistentModel pointers so callers stay isolation-safe.
///
/// **v0.6.2 W-SEC-A:** The `payload` field on this snapshot is always
/// plaintext, even though the underlying SwiftData row stores ciphertext.
/// `OutboxStore` performs the decrypt at the actor boundary so the
/// dispatch path (and tests) keep their existing contract.
public struct OutboxOperationSnapshot: Sendable {
    public let id: UUID
    public let kindRaw: String
    public let payload: Data
    public let idempotencyKey: String
    public let createdAt: Date
    public let attempts: Int
    public let lastAttemptAt: Date?
    public let lastError: String?
    /// v0.13 WS — owning user-id stamped at enqueue (`nil` for legacy rows).
    public let ownerUserID: String?
    /// audit-v0162 H1 — persisted dead-letter flag (recoverable, non-replaying).
    public let deadLettered: Bool
    /// audit-v0162 H-4 — optimistic→server entity-id remap key (see model).
    public let clientEntityId: String?

    init(from model: OutboxOperation) {
        id = model.id
        kindRaw = model.kindRaw
        payload = model.payload
        idempotencyKey = model.idempotencyKey
        createdAt = model.createdAt
        attempts = model.attempts
        lastAttemptAt = model.lastAttemptAt
        lastError = model.lastError
        ownerUserID = model.ownerUserID
        deadLettered = model.deadLettered
        clientEntityId = model.clientEntityId
    }

    /// Construct a snapshot whose `payload` is replaced by `overridePayload`
    /// while every other field still mirrors the underlying SwiftData row.
    /// Used by `OutboxStore.snapshot()` to expose the decrypted plaintext
    /// even though the persisted blob is ciphertext.
    init(from model: OutboxOperation, overridePayload: Data) {
        id = model.id
        kindRaw = model.kindRaw
        payload = overridePayload
        idempotencyKey = model.idempotencyKey
        createdAt = model.createdAt
        attempts = model.attempts
        lastAttemptAt = model.lastAttemptAt
        lastError = model.lastError
        ownerUserID = model.ownerUserID
        deadLettered = model.deadLettered
        clientEntityId = model.clientEntityId
    }
}

// MARK: - ModelContainer factories

public extension OutboxStore {
    /// Production initializer: persistent SQLite under `Application Support`, no
    /// CloudKit. Throws on Application-Support resolution failure or schema
    /// incompatibility — `AppContainer.bootstrap` catches and falls back to a
    /// degraded in-memory store (see `OutboxQueue.makeWithRecovery`).
    static func makePersistent() throws -> ModelContainer {
        let storeURL = try persistentStoreURL()
        return try makePersistent(storeURL: storeURL)
    }

    /// Injectable persistent initializer used by deterministic storage-policy
    /// tests. The directory is re-verified here so even a caller supplying its
    /// own URL cannot open an unexcluded health-bearing store.
    static func makePersistent(storeURL: URL) throws -> ModelContainer {
        try SensitiveDataBackupExclusion.prepareDirectory(at: storeURL.deletingLastPathComponent())
        let schema = Schema(versionedSchema: OutboxSchemaV1.self)
        let config = ModelConfiguration(
            "HealthLogOutbox",
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

        // Apply file protection. SwiftData (Core Data underneath) creates the
        // file lazily on first save; for files that don't exist yet, the helper
        // simply skips them — subsequent calls (post first-save) seal them.
        //
        // S-4 (A360-3 security) — do NOT swallow a protection-apply failure
        // silently. A failure here would persist the outbox without
        // `.completeUntilFirstUserAuthentication`, with no signal at all. We
        // still don't crash (the payloads are already AES-GCM-encrypted at rest,
        // so impact is bounded) but a failure is now observable in the logs for
        // post-mortem triage. The error is a `CocoaError`/`POSIXError` about the
        // file attributes, never PII.
        do {
            try applyFileProtection(to: storeURL)
        } catch {
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.outbox.error(
                "outbox file-protection apply failed — store may persist without complete-until-first-auth protection. err=\(error.localizedDescription, privacy: .public)"
            )
        }

        return container
    }

    /// Test initializer: in-memory only, zero I/O. Used by both production
    /// recovery fallback and the entire test suite.
    static func makeInMemory() throws -> ModelContainer {
        let schema = Schema(versionedSchema: OutboxSchemaV1.self)
        let config = ModelConfiguration(
            "HealthLogOutbox.test",
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

    /// Shared App Group identifier — both the app **and** the widget /
    /// Live-Activity extension hold the `com.apple.security.application-groups`
    /// entitlement for this suite (see `project.yml`, both targets). Mirrors
    /// ``WidgetAppGroup/identifier``; duplicated here as a bare constant because
    /// `WidgetShared/` is app-target-only and is **not** part of the
    /// platform-free `HealthLogCore` SPM module that compiles `OutboxStore`
    /// (same lock-step-constant pattern as `LockScreenPrivacy`). MUST stay in
    /// lock-step with `WidgetAppGroup.identifier`.
    static let appGroupIdentifier = "group.dev.healthlog.app"

    /// **audit-v0162 H2 — outbox lives in the SHARED App Group container.**
    /// `<app-group>/HealthLog/Outbox/outbox.sqlite`, created on demand. Public
    /// so the recovery path in `OutboxQueue` can wipe/move-aside the store if it
    /// becomes unreadable.
    ///
    /// ## Why the App Group container (not the process-local sandbox)
    ///
    /// The "Genommen"/mood App Intents that back the Lock-Screen widget + Live
    /// Activity buttons run **inside the widget-extension process**
    /// (`openAppWhenRun = false`). Extensions do NOT share the app's
    /// `Application Support` container — only the App Group + Keychain access
    /// group cross the sandbox boundary. Pre-fix, an offline "Genommen" tap
    /// enqueued a durable write-ahead row into the *extension's own* sandbox
    /// outbox, which the app's `OutboxReplayService` could never see — the
    /// intake was permanently lost. Resolving the store into the shared App
    /// Group container makes the app and the extension open **one** outbox file,
    /// so the app's existing replay loop drains extension-enqueued writes.
    ///
    /// ## Concurrency / corruption tradeoff (deliberate, conservative)
    ///
    /// Two processes on one SQLite file is delicate. The pattern here is
    /// **enqueue-from-extension + drain-from-app**: the extension only ever
    /// *appends* (`enqueue` → insert + `save()`), and the **app owns** the
    /// replay/drain (snapshot → dispatch → delete). SwiftData (Core Data /
    /// SQLite underneath) runs in WAL journal mode with POSIX file locking, so
    /// concurrent append-vs-read across processes is serialized at the SQLite
    /// layer — the safe end of the multi-process spectrum. We deliberately do
    /// **not** run the replay/delete loop from the extension (no
    /// `OutboxReplayService` in the widget target), keeping the risky
    /// mutate-while-another-process-reads window closed. File protection stays
    /// `completeUntilFirstUserAuthentication` (ADR-012) so the store is readable
    /// in the BGTask/extension window while the device is locked.
    ///
    /// Falls back to the pre-fix process-local `Application Support` path when
    /// the App Group container is unavailable (unit tests / a build where the
    /// group is not provisioned), preserving the app-target behavior there.
    static func persistentStoreURL() throws -> URL {
        try persistentStoreURL(appGroupContainer: appGroupContainerURL())
    }

    /// Resolved URL of the provisioned App Group container root, or `nil` when
    /// the group is not available (unit tests, unprovisioned build). Injected in
    /// tests via ``persistentStoreURL(appGroupContainer:fileManager:)``.
    static func appGroupContainerURL(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    /// Testable core of ``persistentStoreURL()`` — resolves the `outbox.sqlite`
    /// file inside the outbox directory for the given (possibly injected) App
    /// Group container.
    static func persistentStoreURL(
        appGroupContainer: URL?,
        fileManager: FileManager = .default
    ) throws -> URL {
        try outboxDirectory(appGroupContainer: appGroupContainer, fileManager: fileManager)
            .appendingPathComponent("outbox.sqlite")
    }

    /// Resolve (and create) the directory that holds `outbox.sqlite`. Prefers
    /// the shared App Group container; falls back to the process-local
    /// `Application Support` directory when the group is unavailable.
    static func outboxDirectory(
        appGroupContainer: URL?,
        fileManager: FileManager = .default
    ) throws -> URL {
        if let appGroupContainer {
            let shared = appGroupContainer.appendingPathComponent("HealthLog/Outbox", isDirectory: true)
            try SensitiveDataBackupExclusion.prepareDirectory(at: shared, fileManager: fileManager)
            migrateLegacySandboxStoreIfNeeded(into: shared, fileManager: fileManager)
            return shared
        }
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("HealthLog/Outbox", isDirectory: true)
        try SensitiveDataBackupExclusion.prepareDirectory(at: dir, fileManager: fileManager)
        return dir
    }

    /// **audit-v0162 H2 — one-time best-effort migration of a pre-App-Group
    /// outbox.** Before this fix the app wrote `outbox.sqlite` into its
    /// process-local `Application Support`. On the upgrade that flips the store
    /// into the shared container, move any existing legacy store (SQLite +
    /// `-wal`/`-shm` sidecars, whatever their naming) across so already-queued
    /// offline writes are NOT orphaned. Runs only when the shared store does not
    /// yet exist (never clobbers a live shared store) and is fully best-effort —
    /// a failure leaves the legacy bytes in place for a later retry and the app
    /// still opens the (empty) shared store rather than crashing.
    static func migrateLegacySandboxStoreIfNeeded(into sharedDir: URL, fileManager: FileManager) {
        let sharedStore = sharedDir.appendingPathComponent("outbox.sqlite")
        guard !fileManager.fileExists(atPath: sharedStore.path) else { return }
        guard let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return }
        let legacyDir = appSupport.appendingPathComponent("HealthLog/Outbox", isDirectory: true)
        guard fileManager.fileExists(atPath: legacyDir.appendingPathComponent("outbox.sqlite").path) else { return }
        guard let entries = try? fileManager.contentsOfDirectory(atPath: legacyDir.path) else { return }
        for name in entries where name.hasPrefix("outbox.sqlite") {
            let from = legacyDir.appendingPathComponent(name)
            let to = sharedDir.appendingPathComponent(name)
            guard !fileManager.fileExists(atPath: to.path) else { continue }
            try? fileManager.moveItem(at: from, to: to)
        }
    }

    /// Best-effort: set `.completeUntilFirstUserAuthentication` on the SQLite
    /// store + `-shm` + `-wal`. Equivalent to Keychain's
    /// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (file is unreadable
    /// after reboot until first unlock; remains readable while the device is
    /// locked thereafter — required because BGProcessingTask wakeups happen
    /// while the device may be locked). See ADR-012.
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
