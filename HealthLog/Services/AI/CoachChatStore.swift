import Foundation
import SwiftData

/// **v0.5.7 G.5** — SwiftData persistence shim for the Coach chat
/// transcript. Owns the dedicated `ModelContainer` + `ModelContext`
/// pair and exposes the four operations `CoachConversationStore`
/// needs: hydrate, persist, clear (user-scoped), clear (all).
///
/// **Why a separate persistence type instead of inlining into
/// `CoachConversationStore`?**
/// 1. The conversation store is `@MainActor @Observable` and drives
///    the SwiftUI surface. Mixing SwiftData open + recovery logic
///    into the same type couples view-layer state with disk I/O —
///    the outbox store already keeps the persistence shim
///    factored separately for the same reason.
/// 2. Unit tests can hand an in-memory `CoachChatStore` to the
///    conversation store via init injection, without exercising the
///    on-disk recovery path on every spin-up.
/// 3. A future migration that moves the chat transcript onto a
///    different storage layer (e.g. CryptoKit-sealed file blobs) can
///    swap this type out without touching the orchestration logic.
///
/// **Recovery posture** mirrors `OutboxStore.makeWithRecovery`:
/// attempt the persistent
/// store, wipe the directory + retry on corruption, fall back to
/// in-memory so app launch never crashes here. The chat transcript
/// is non-load-bearing — a wipe is no worse than the user clearing
/// it via the new Settings affordance.
public final class CoachChatStore: @unchecked Sendable {
    /// `@unchecked Sendable` annotation: the underlying `ModelContainer`
    /// is Sendable by SwiftData design; `ModelContext` access is
    /// confined to the calling actor (we hop to MainActor before
    /// invoking any read/write method). The wrapper holds no shared
    /// mutable state outside the container ref itself.
    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    /// Hydrate the persisted transcript for the supplied `userID`.
    /// Returns the rows ordered oldest-first so the SpeziChat
    /// `ChatEntity` array can be re-built in append order.
    ///
    /// `@MainActor` because `ModelContainer.mainContext` is bound to
    /// the main actor when used through the convenience accessor.
    /// Reads of
    /// at most ~500 chat rows are fast enough that the MainActor hop
    /// is a non-issue (each row is <1 KB).
    @MainActor
    public func fetch(userID: String) -> [CoachChatMessage] {
        var descriptor = FetchDescriptor<CoachChatMessage>(
            predicate: #Predicate<CoachChatMessage> { $0.userID == userID },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        // Hard upper bound — the Settings affordance gives the operator
        // a manual reset, but a runaway loop should never produce a
        // hydration storm.
        descriptor.fetchLimit = 500
        do {
            return try container.mainContext.fetch(descriptor)
        } catch {
            HLLog.storage
                .warning("Coach chat fetch failed: \(LogSanitizer.redact(String(describing: error)))")
            return []
        }
    }

    /// Persist a single message row. Called twice per send — once for
    /// the user turn, once for the assistant turn.
    ///
    /// The save is fire-and-forget at the call-site (no return value
    /// observed); errors are logged but never surfaced — a failed
    /// persist means the next launch hydrates a shorter transcript,
    /// which is harmless. Crashing on a chat-persist error would
    /// regress the AskCoach sheet for a non-load-bearing failure.
    @MainActor
    public func insert(_ message: CoachChatMessage) {
        container.mainContext.insert(message)
        do {
            try container.mainContext.save()
        } catch {
            HLLog.storage
                .warning("Coach chat insert failed: \(LogSanitizer.redact(String(describing: error)))")
        }
    }

    /// Drops every row for the supplied `userID`. Used by:
    /// 1. `CoachConversationStore.reset()` — manual clear from the
    ///    AskCoach toolbar OR the Settings → Coach → "Verlauf
    ///    löschen" affordance.
    /// 2. `AppContainer.handleLocalLogout()` — logout/401-bridge hook
    ///    so the next account never inherits the previous user's chat.
    @MainActor
    public func clear(userID: String) {
        let descriptor = FetchDescriptor<CoachChatMessage>(
            predicate: #Predicate<CoachChatMessage> { $0.userID == userID }
        )
        do {
            let rows = try container.mainContext.fetch(descriptor)
            for row in rows {
                container.mainContext.delete(row)
            }
            try container.mainContext.save()
        } catch {
            HLLog.storage
                .warning("Coach chat clear failed: \(LogSanitizer.redact(String(describing: error)))")
        }
    }

    /// Drops every row regardless of partition. Currently unused in
    /// production — kept as an explicit affordance for tests + a
    /// future "factory-reset" surface. The per-user `clear(userID:)`
    /// is the canonical path; this method exists so test setUp can
    /// guarantee a clean slate without knowing which sentinel was
    /// used by prior cases.
    @MainActor
    public func clearAll() {
        let descriptor = FetchDescriptor<CoachChatMessage>()
        do {
            let rows = try container.mainContext.fetch(descriptor)
            for row in rows {
                container.mainContext.delete(row)
            }
            try container.mainContext.save()
        } catch {
            HLLog.storage
                .warning("Coach chat clearAll failed: \(LogSanitizer.redact(String(describing: error)))")
        }
    }
}

// MARK: - ModelContainer factories

public extension CoachChatStore {
    /// Production entry point. Mirrors `OutboxQueue.makeWithRecovery`:
    /// corrupt store
    /// wipes + retries, falls back to in-memory so app launch never
    /// crashes here.
    static func makeWithRecovery() -> CoachChatStore {
        do {
            return try CoachChatStore(container: makePersistent())
        } catch {
            HLLog.storage
                .error("Coach chat store unreadable, attempting rebuild: \(LogSanitizer.redact(String(describing: error)))")
            if let storeURL = try? persistentStoreURL() {
                let dir = storeURL.deletingLastPathComponent()
                try? FileManager.default.removeItem(at: dir)
            }
            do {
                return try CoachChatStore(container: makePersistent())
            } catch {
                HLLog.storage
                    .error("Coach chat rebuild also failed, falling back to in-memory: \(LogSanitizer.redact(String(describing: error)))")
                // Non-trapping in-memory floor (audit M2): degrade to an inert
                // empty-schema store instead of `try!`-trapping on the path that
                // exists to avoid a hard launch failure. The chat transcript is
                // non-load-bearing, so an inert store is harmless.
                let container = ModelContainerRecovery.recoveredInMemoryContainer(
                    log: HLLog.storage,
                    subsystem: "CoachChat",
                    build: makeInMemory
                )
                return CoachChatStore(container: container)
            }
        }
    }

    /// Production initializer: persistent SQLite under `Application
    /// Support`, no CloudKit. Throws on Application-Support resolution
    /// failure or schema incompatibility.
    static func makePersistent() throws -> ModelContainer {
        let storeURL = try persistentStoreURL()
        let schema = Schema(versionedSchema: CoachChatSchemaV1.self)
        let config = ModelConfiguration(
            "HealthLogCoachChat",
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

    /// Test initializer: in-memory only, zero I/O. Used by both the
    /// production recovery fallback and the entire test suite.
    static func makeInMemory() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CoachChatSchemaV1.self)
        let config = ModelConfiguration(
            "HealthLogCoachChat.test",
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

    /// `<sandbox>/Library/Application Support/HealthLog/CoachChat/coach-chat.sqlite`.
    /// Sibling of `Outbox/outbox.sqlite` + `Inbox/inbox.sqlite` +
    /// `Cache/cache.sqlite`.
    static func persistentStoreURL() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("HealthLog/CoachChat", isDirectory: true)
        try SensitiveDataBackupExclusion.prepareDirectory(at: dir, fileManager: fm)
        return dir.appendingPathComponent("coach-chat.sqlite")
    }

    /// Best-effort: set `.completeUntilFirstUserAuthentication` on the
    /// SQLite store + `-shm` + `-wal`. Mirrors the Outbox/Inbox file-
    /// protection policy so background hydration after first unlock
    /// still works.
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
