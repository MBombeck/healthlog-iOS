import Foundation
import SwiftData

/// SwiftData row for one cached server response.
///
/// Single generic envelope (not one model per DTO) keeps the SwiftData
/// schema forward-compatible with server DTO drift — a renamed/added field
/// on the server breaks the next-decode (`SWRCoordinator` treats it as a
/// cache-miss + re-fetches), not the SwiftData migration path. A2-Audit §5
/// covers the rationale at length.
///
/// **Threading:** A `PersistentModel` is bound to its `ModelContext`. This
/// type **must never cross** the `SWRCache` actor boundary — only the
/// Sendable `Cached<T>` value struct does (see ADR-011 + swift-concurrency
/// skill's Core-Data-→-SwiftData guidance, same constraint as
/// `OutboxOperation`).
@Model
public final class CachedSnapshot {
    /// `CacheKey.persistentHash` — stable SHA-256 hex string.
    @Attribute(.unique) public var keyHash: String
    /// `JSONEncoder.hlDefault` output of the cached payload.
    public var payloadData: Data
    /// Wall-clock at write time. Drives staleness checks via
    /// `Cached<T>.isStale(per:)`.
    public var updatedAt: Date
    /// Schema-fingerprint counter. Bumped on non-additive iOS DTO changes
    /// (rare). On read, mismatching rows are treated as cache-misses + dropped.
    public var schemaVersion: Int

    public init(
        keyHash: String,
        payloadData: Data,
        updatedAt: Date,
        schemaVersion: Int = CacheSchemaV1.currentSchemaVersion
    ) {
        self.keyHash = keyHash
        self.payloadData = payloadData
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}

/// Schema versioning seed. Mirror of `OutboxSchemaV1` — named version
/// rather than anonymous v0 so the first migration can use `SchemaMigrationPlan`
/// cleanly when v2 lands.
public enum CacheSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [CachedSnapshot.self]
    }

    /// Current value-side schema fingerprint. Bump on non-additive Codable
    /// changes (e.g. removing a field, changing semantics of a kept name).
    /// Reads with a mismatching value are silently dropped + re-fetched.
    public static let currentSchemaVersion: Int = 1
}

/// Sendable boundary type returned by `SWRCache.read`. Callers see only this
/// — never the underlying `CachedSnapshot` PersistentModel.
public struct Cached<T: Sendable>: Sendable {
    public let value: T
    public let updatedAt: Date

    public init(value: T, updatedAt: Date) {
        self.value = value
        self.updatedAt = updatedAt
    }

    public func isStale(per key: CacheKey, now: Date = .now) -> Bool {
        now.timeIntervalSince(updatedAt) > key.staleAfter
    }
}
