import Foundation
import SwiftData

/// Persistent record of a pending offline write. Created by the repositories'
/// retriable-error path, hydrated on app launch, drained by `OutboxReplayService`.
///
/// **Lifecycle:** Created → (replayed → deleted on success) | (incrementAttempts on
/// retriable fail → eventually dropped after `OutboxReplayService.maxAttempts`).
///
/// **Threading:** A `PersistentModel` is bound to the `ModelContext` it was fetched
/// from. Instances of this type **must never cross** the `OutboxStore` actor
/// boundary — only the `OutboxQueue.Operation` Sendable struct does. See ADR-011 +
/// the swift-concurrency skill's Core-Data-→-SwiftData guidance.
@Model
public final class OutboxOperation {
    /// SwiftData requires a unique identity. We use the same UUID the public
    /// `Operation` struct already exposes so test code and existing IDs map 1:1.
    @Attribute(.unique) public var id: UUID

    /// Stored as the raw `String` of `OutboxQueue.Operation.Kind` so the
    /// schema is forward-compatible with new kinds without a SwiftData
    /// migration. Decoded back into the enum at the actor boundary.
    public var kindRaw: String

    /// Encoded request body (camelCase JSON, matches `JSONEncoder.hlDefault`).
    /// Symmetric with the replay decoder in `OutboxReplayService.dispatch`.
    public var payload: Data

    /// UUID-string. Persisted at `enqueue` time so the server's
    /// `(userId, key, method, path)` 24h dedup is preserved across app kill.
    public var idempotencyKey: String

    /// Wall-clock time of enqueue. Replay iterates oldest-first.
    public var createdAt: Date

    /// Increments on each retriable failure. Drop rule: `attempts >= maxAttempts`.
    public var attempts: Int

    /// Last replay timestamp — useful for backoff bookkeeping and triage.
    public var lastAttemptAt: Date?

    /// Last sanitized error string (max 256 chars). Pre-sanitized at write time
    /// via `LogSanitizer.redact`.
    public var lastError: String?

    /// **v0.13 WS — cross-user outbox binding (Medium security).** The
    /// `KeychainKey.userID` of the user who was signed in when this row was
    /// enqueued. Replay only fires a row whose owner matches the *currently*
    /// signed-in user; a foreign-owned row is dead-lettered, never POSTed
    /// under the wrong bearer token.
    ///
    /// **Optional (defaults `nil`) on purpose — lightweight SwiftData
    /// migration.** Adding an optional attribute with a default needs no
    /// `SchemaMigrationPlan`: existing on-disk rows (enqueued before this
    /// field) hydrate as `nil`. The replay path treats a `nil` owner as
    /// "current-user-owned" (transitional compat) — see
    /// `OutboxReplayService.runOnce` for the full justification of why that
    /// is the SAFE choice for the legacy window.
    public var ownerUserID: String?

    /// **v0.16.2 audit-v0162 H1 (Opt 1) — persisted dead-letter flag.** A row
    /// that exhausts its retry budget *and* has aged past the dead-letter window
    /// is no longer permanently deleted — it is flagged `deadLettered` and kept
    /// on disk so the write remains RECOVERABLE (count + manual re-submit).
    /// Dead-lettered rows are excluded from the replay snapshot so they never
    /// re-fire on their own; `resubmit` clears the flag + resets `attempts`.
    /// Optional-with-default → lightweight migration (same posture as
    /// `ownerUserID`); legacy rows hydrate as `false`.
    public var deadLettered: Bool = false

    /// Wall-clock time the row was moved to the dead-letter state. `nil` while
    /// the row is live. Used only for triage / a future diagnostics surface.
    public var deadLetteredAt: Date?

    /// **v0.16.2 audit-v0162 H-4 — optimistic→server id remap key.** For a PHI
    /// records/labs write this carries the ENTITY id the op concerns: a `create`
    /// stamps the `optimistic-<uuid>` id its store minted; a dependent
    /// `update`/`delete` stamps the id it targets (which equals that optimistic
    /// id while the create is still offline). When the create replays and the
    /// server assigns a real id, `OutboxReplayService` remaps every sibling row
    /// carrying the same `optimistic-<uuid>` here to the server id — so an
    /// offline edit/delete of an offline-created record isn't lost to a 404.
    /// `nil` for kinds without an optimistic-id chain (measurements, mood, …).
    public var clientEntityId: String?

    public init(
        id: UUID = UUID(),
        kindRaw: String,
        payload: Data,
        idempotencyKey: String,
        createdAt: Date = .now,
        attempts: Int = 0,
        lastAttemptAt: Date? = nil,
        lastError: String? = nil,
        ownerUserID: String? = nil,
        deadLettered: Bool = false,
        deadLetteredAt: Date? = nil,
        clientEntityId: String? = nil
    ) {
        self.id = id
        self.kindRaw = kindRaw
        self.payload = payload
        self.idempotencyKey = idempotencyKey
        self.createdAt = createdAt
        self.attempts = attempts
        self.lastAttemptAt = lastAttemptAt
        self.lastError = lastError
        self.ownerUserID = ownerUserID
        self.deadLettered = deadLettered
        self.deadLetteredAt = deadLetteredAt
        self.clientEntityId = clientEntityId
    }
}

/// Schema versioning seed. The first ever migration starts from a named version
/// rather than "anonymous v0" — keeps `SchemaMigrationPlan` work explicit when v2
/// lands.
public enum OutboxSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [OutboxOperation.self]
    }
}
