import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

// Phase 07 Wave 1 — the owner-partitioned, read-back-verified cursor store.
//
// Everything the shipped app persists as a HealthKit cursor today is either
// installation-global (SpeziHealthKit's own slots) or per-type but not
// per-account (`hl.healthkit.anchor.*`). Both shapes mean the same thing on a
// shared device: account B resumes reading from wherever account A stopped, and
// account A's un-uploaded window is silently consumed.
//
// This store fixes the identity and the proof at once:
//
//   * Identity is `{owner, source, type}` (`HealthSyncCursorKey`), with the
//     owner hashed into the storage key so a defaults dump never names an
//     account.
//   * A write counts only after a read-back that returns the same bytes under
//     the same format version. A silent `UserDefaults` loss can therefore never
//     leave a partition claiming progress it does not have.
//   * Migration is versioned and fail-closed. `notStarted` and `failed` refuse
//     collection outright; only a verified adoption or an explicit legacy
//     replay may collect.
//
// Two rules bound what migration is allowed to do:
//
//   * A legacy value is adopted only against *proof* that it belonged to this
//     account. There is exactly one such proof today — a key this app wrote
//     under a per-user namespace.
//   * An installation-global value has no owner and never acquires one. It is
//     quarantined: retained (never deleted in this phase, and read-only through
//     Phase 11), recorded as a reference on the partition, and replaced by a
//     replay from the cutoff the user chose during onboarding.
//
// No legacy key is deleted here, and nothing in this file can copy an owner's
// cursor into a global slot or promote a global value into an owner partition.
// Recovery is allowed to stop collection; it is never allowed to widen it.
//
// `UserDefaults` remains the backing store, deliberately: an anchor is an
// opaque resume token, not health data, and the battery rationale in
// PROJECT_GUIDE.md for keeping anchors out of the encrypted SwiftData store is
// unchanged. What is new is that the *value* is a versioned record rather than
// a bare blob.

/// What is known about a legacy value *before* any migration touches it.
///
/// There is no third case on purpose. "Probably this user's" is not proof, and
/// a value that cannot be proven is quarantined rather than guessed at.
enum HealthSyncLegacyCursorOwnership: Sendable, Equatable {
    /// The legacy key lived in a per-account namespace and that account is
    /// exactly this partition's owner.
    case provenOwner(String)
    /// An installation-global slot (SpeziHealthKit, or any pre-Phase-07
    /// per-type key). Unowned, and it stays that way.
    case unownedGlobal
}

/// Why a cursor write or migration refused to stamp progress.
enum HealthSyncCursorStoreError: String, Error, Sendable, Equatable {
    /// The lease does not own the partition it tried to write.
    case partitionOwnerMismatch
    /// The anchor blob was empty or otherwise unusable.
    case malformedAnchor
    /// The write did not survive its own read-back.
    case writeNotVerified
}

/// The non-sensitive key/value backing store cursor and migration records live
/// in.
///
/// A `Sendable` pair of accessors rather than a `UserDefaults` reference: the
/// store is an actor, and handing a reference type across that boundary would
/// leave the caller holding a second, unsynchronised handle onto the same
/// mutable state. Injecting the two operations keeps the actor's state genuinely
/// its own and lets a test drive a lossy write without subclassing anything the
/// production path uses.
struct HealthSyncCursorStorage: Sendable {
    let read: @Sendable (String) -> Data?
    let write: @Sendable (String, Data) -> Void

    /// `UserDefaults`-backed storage. `UserDefaults` is documented thread-safe,
    /// which is what the `nonisolated(unsafe)` capture asserts and nothing more:
    /// the instance is never mutated by this type outside these two calls.
    static func userDefaults(_ defaults: UserDefaults) -> HealthSyncCursorStorage {
        nonisolated(unsafe) let backing = defaults
        return HealthSyncCursorStorage(
            read: { backing.data(forKey: $0) },
            write: { backing.set($1, forKey: $0) }
        )
    }

    static let standard = userDefaults(.standard)
}

/// Owner-partitioned cursor storage with verified writes and a fail-closed,
/// versioned migration record.
actor DurableHealthCursorStore {
    /// On-disk format version for a cursor record. Bumping it makes every older
    /// record read as absent rather than as silently-compatible.
    static let formatVersion = 2

    /// Suffix of the sibling key that carries the migration record. Kept in the
    /// same namespace as the cursor so a partition is one contiguous prefix in
    /// any diagnostics dump.
    private static let migrationSuffix = ".migration"

    /// A stored cursor. The anchor is opaque; the version and timestamp exist so
    /// a read-back can prove the exact write that just happened, and so a future
    /// format change fails closed instead of misreading old bytes.
    struct CursorRecord: Codable, Sendable, Equatable {
        let version: Int
        let anchor: Data
        let updatedAt: Date
    }

    /// Versioned mirror of ``HealthSyncCursorMigrationState``. The contract enum
    /// is deliberately not `Codable` — the persisted shape is allowed to evolve
    /// independently of the vocabulary the rest of Phase 07 speaks.
    struct MigrationRecord: Codable, Sendable, Equatable {
        let version: Int
        let state: String
        let quarantineReference: String?
        let reason: String?
        let updatedAt: Date

        static let notStarted = "notStarted"
        static let replayingLegacy = "replayingLegacy"
        static let verified = "verified"
        static let failed = "failed"
    }

    /// Read-only view of one partition, for the diagnostics and replay surfaces
    /// Phase 07 owes the operator.
    struct PartitionDiagnostic: Sendable, Equatable {
        let storageKey: String
        let source: HealthSyncSource
        let typeIdentifier: String
        let hasCursor: Bool
        let migration: HealthSyncCursorMigrationState
        let quarantineReference: String?
        /// `true` when this partition may collect right now. Mirrors
        /// ``HealthSyncCursorMigrationState/permitsCollection`` so a reader
        /// never has to re-derive the fail-closed rule.
        let permitsCollection: Bool
    }

    private let storage: HealthSyncCursorStorage
    private let clock: @Sendable () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        storage: HealthSyncCursorStorage = .standard,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.storage = storage
        self.clock = clock
    }

    // MARK: - Reads

    /// The stored anchor for a partition, or `nil` when the partition has never
    /// been written, was written by a different format version, or holds bytes
    /// this build cannot decode. All three read as "no cursor", which is the
    /// safe direction: a re-read costs battery, a wrongly-trusted cursor costs
    /// data.
    func anchor(for key: HealthSyncCursorKey) -> Data? {
        record(for: key)?.anchor
    }

    func migrationState(for key: HealthSyncCursorKey) -> HealthSyncCursorMigrationState {
        guard let stored = migrationRecord(for: key) else {
            return .notStarted
        }
        switch stored.state {
        case MigrationRecord.verified:
            return .verified
        case MigrationRecord.replayingLegacy:
            guard let reference = stored.quarantineReference else {
                return .failed(reason: "replay record lost its quarantine reference")
            }
            return .replayingLegacy(quarantineReference: reference)
        case MigrationRecord.failed:
            return .failed(reason: stored.reason ?? "unspecified")
        default:
            return .notStarted
        }
    }

    /// The single gate every collector must consult before querying. Fails
    /// closed: an unproven or failed migration collects nothing.
    func permitsCollection(for key: HealthSyncCursorKey) -> Bool {
        migrationState(for: key).permitsCollection
    }

    /// The legacy key a quarantined value is retained under, or `nil`.
    ///
    /// Read from the persisted record rather than derived from the migration
    /// state, because the reference must outlive the replay: a partition that
    /// later fails closed is exactly the partition an operator needs to be able
    /// to trace back to the value it never adopted.
    func quarantineReference(for key: HealthSyncCursorKey) -> String? {
        migrationRecord(for: key)?.quarantineReference
    }

    /// Read-only access to a quarantined legacy value, for diagnosis and for
    /// scheduling a replay window.
    ///
    /// This is the only way to observe a quarantined value, and it is
    /// deliberately a *read*: there is no counterpart that installs the bytes it
    /// returns into an owner partition, so an unowned global anchor cannot
    /// re-enable a server-bound collector through this API.
    func quarantinedLegacyValue(for key: HealthSyncCursorKey) -> Data? {
        guard let reference = quarantineReference(for: key) else { return nil }
        return storage.read(reference)
    }

    func diagnostics(for keys: [HealthSyncCursorKey]) -> [PartitionDiagnostic] {
        keys.map { key in
            let state = migrationState(for: key)
            return PartitionDiagnostic(
                storageKey: key.storageKey,
                source: key.source,
                typeIdentifier: key.typeIdentifier,
                hasCursor: record(for: key) != nil,
                migration: state,
                quarantineReference: quarantineReference(for: key),
                permitsCollection: state.permitsCollection
            )
        }
    }

    // MARK: - Writes

    /// Persists an anchor for a partition the lease owns, and stamps progress
    /// only after the write proves itself on read-back.
    ///
    /// Ordering matters and is not negotiable: validate, write, read back,
    /// validate again. The trailing validation is what stops an account
    /// replacement that lands during the write from leaving B's partition
    /// carrying A's resume token.
    @discardableResult
    func save(
        anchor: Data,
        for key: HealthSyncCursorKey,
        requiring lease: HealthSyncAuthenticatedLease
    ) throws -> CursorRecord {
        try lease.requireCurrent()
        guard lease.ownerID == key.ownerID else {
            throw HealthSyncCursorStoreError.partitionOwnerMismatch
        }
        guard !anchor.isEmpty else {
            markFailed(key, reason: "anchor blob was empty")
            throw HealthSyncCursorStoreError.malformedAnchor
        }

        let candidate = CursorRecord(version: Self.formatVersion, anchor: anchor, updatedAt: clock())
        guard let encoded = try? encoder.encode(candidate) else {
            markFailed(key, reason: "cursor record could not be encoded")
            throw HealthSyncCursorStoreError.malformedAnchor
        }
        storage.write(key.storageKey, encoded)

        guard let readBack = record(for: key), readBack == candidate else {
            markFailed(key, reason: "cursor write did not survive read back")
            throw HealthSyncCursorStoreError.writeNotVerified
        }
        try lease.requireCurrent()

        // A partition mid-replay stays mid-replay: progress through the replay
        // window is not the same thing as having proven the migration.
        // `completeLegacyReplay` is the only way out of that state.
        if case .replayingLegacy = migrationState(for: key) {
            return readBack
        }
        write(
            MigrationRecord(
                version: Self.formatVersion,
                state: MigrationRecord.verified,
                quarantineReference: nil,
                reason: nil,
                updatedAt: clock()
            ),
            for: key
        )
        return readBack
    }

    /// Applies the Phase-07 commit rule to a page and writes the cursor only
    /// when it says so.
    ///
    /// This is the single decision point Wave 2+ collectors call instead of
    /// persisting a library anchor unconditionally. A hold leaves the stored
    /// cursor exactly as it was; there is no rewind, because a rewind cannot
    /// recover a page the query already consumed.
    @discardableResult
    func commit(
        page outcome: HealthSyncPageOutcome,
        anchor: Data,
        for key: HealthSyncCursorKey,
        requiring lease: HealthSyncAuthenticatedLease
    ) -> HealthSyncCommitDecision {
        if let refusal = lease.refusal {
            return .hold(reason: refusal.holdReason)
        }
        guard permitsCollection(for: key) else {
            return .hold(reason: .leaseLost)
        }
        let decision = HealthSyncCursorPolicy.required.decide(outcome)
        guard decision == .commit else { return decision }
        do {
            try save(anchor: anchor, for: key, requiring: lease)
            return .commit
        } catch {
            return .hold(reason: .retryPersistenceFailed)
        }
    }

    /// Ends an explicit legacy replay: the window the user chose has been
    /// walked, so the partition is now proven under its own owner.
    ///
    /// The quarantined legacy value is *not* deleted — it stays inspectable
    /// until the Phase-11 hardware pass confirms nothing was lost.
    func completeLegacyReplay(
        for key: HealthSyncCursorKey,
        requiring lease: HealthSyncAuthenticatedLease
    ) throws {
        try lease.requireCurrent()
        guard lease.ownerID == key.ownerID else {
            throw HealthSyncCursorStoreError.partitionOwnerMismatch
        }
        guard case .replayingLegacy = migrationState(for: key) else { return }
        write(
            MigrationRecord(
                version: Self.formatVersion,
                state: MigrationRecord.verified,
                quarantineReference: nil,
                reason: nil,
                updatedAt: clock()
            ),
            for: key
        )
    }

    /// Fail-closed recovery: stop collecting this partition without touching
    /// either the owner's stored cursor or any quarantined legacy value.
    ///
    /// Stopping is always allowed. Widening never is — this method cannot
    /// clear a quarantine, cannot adopt a global value, and cannot re-enable a
    /// collector.
    func failClosed(_ key: HealthSyncCursorKey, reason: String) {
        markFailed(key, reason: reason)
    }

    // MARK: - Migration

    /// Establishes the migration state for a partition exactly once.
    ///
    /// - `provenOwner` matching the partition adopts the legacy anchor through
    ///   the same verified write path as any other cursor, then reports
    ///   `verified`. A legacy key with nothing in it is also `verified`: there
    ///   is no history to lose.
    /// - `provenOwner` that does *not* match the partition is a proof failure,
    ///   not a fallback — the partition fails closed.
    /// - `unownedGlobal` never reads the value into the partition at all. It
    ///   records the legacy key as a quarantine reference and reports
    ///   `replayingLegacy`, which permits collection from the chosen cutoff
    ///   while the global value stays untouched.
    ///
    /// Re-running against an already-`verified` or already-replaying partition
    /// is a no-op, so a migration cannot be repeated into a second adoption.
    @discardableResult
    func migrate(
        _ key: HealthSyncCursorKey,
        legacyKey: String,
        ownership: HealthSyncLegacyCursorOwnership,
        requiring lease: HealthSyncAuthenticatedLease
    ) throws -> HealthSyncCursorMigrationState {
        try lease.requireCurrent()
        guard lease.ownerID == key.ownerID else {
            throw HealthSyncCursorStoreError.partitionOwnerMismatch
        }

        let existing = migrationState(for: key)
        switch existing {
        case .verified, .replayingLegacy:
            return existing
        case .notStarted, .failed:
            break
        }

        switch ownership {
        case .unownedGlobal:
            let state = HealthSyncCursorMigrationState.replayingLegacy(quarantineReference: legacyKey)
            write(
                MigrationRecord(
                    version: Self.formatVersion,
                    state: MigrationRecord.replayingLegacy,
                    quarantineReference: legacyKey,
                    reason: nil,
                    updatedAt: clock()
                ),
                for: key
            )
            return state

        case let .provenOwner(provenOwnerID):
            guard provenOwnerID == key.ownerID else {
                let reason = "legacy owner proof did not match the partition"
                markFailed(key, reason: reason)
                return .failed(reason: reason)
            }
            guard let legacyAnchor = storage.read(legacyKey), !legacyAnchor.isEmpty else {
                // Nothing to carry over. The partition is proven by
                // construction and starts from the chosen cutoff.
                write(
                    MigrationRecord(
                        version: Self.formatVersion,
                        state: MigrationRecord.verified,
                        quarantineReference: nil,
                        reason: nil,
                        updatedAt: clock()
                    ),
                    for: key
                )
                return .verified
            }
            do {
                try save(anchor: legacyAnchor, for: key, requiring: lease)
                return .verified
            } catch {
                let reason = "legacy anchor adoption did not verify"
                markFailed(key, reason: reason)
                return .failed(reason: reason)
            }
        }
    }

    // MARK: - Private

    private func record(for key: HealthSyncCursorKey) -> CursorRecord? {
        guard let data = storage.read(key.storageKey),
              let decoded = try? decoder.decode(CursorRecord.self, from: data),
              decoded.version == Self.formatVersion else
        {
            return nil
        }
        return decoded
    }

    private func migrationRecord(for key: HealthSyncCursorKey) -> MigrationRecord? {
        guard let data = storage.read(migrationKey(for: key)),
              let stored = try? decoder.decode(MigrationRecord.self, from: data),
              stored.version == Self.formatVersion else
        {
            return nil
        }
        return stored
    }

    private func migrationKey(for key: HealthSyncCursorKey) -> String {
        key.storageKey + Self.migrationSuffix
    }

    private func write(_ record: MigrationRecord, for key: HealthSyncCursorKey) {
        guard let data = try? encoder.encode(record) else { return }
        storage.write(migrationKey(for: key), data)
    }

    private func markFailed(_ key: HealthSyncCursorKey, reason: String) {
        write(
            MigrationRecord(
                version: Self.formatVersion,
                state: MigrationRecord.failed,
                quarantineReference: quarantineReference(for: key),
                reason: reason,
                updatedAt: clock()
            ),
            for: key
        )
        // The reason is an operator-grade sentence chosen at the call site; an
        // anchor is an opaque resume token and carries no health data.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.healthKit.error(
            "health cursor partition failed closed [\(key.source.rawValue, privacy: .public)] — \(reason, privacy: .public)"
        )
    }
}

#if canImport(HealthKit)

    extension DurableHealthCursorStore {
        /// HealthKit-typed convenience over ``save(anchor:for:requiring:)``.
        /// Archiving goes through ``HealthKitAnchorArchive`` so an encode
        /// failure is surfaced rather than swallowed, and a failure to archive
        /// is treated exactly like a failed write: the partition holds.
        @discardableResult
        func save(
            _ anchor: HKQueryAnchor,
            for key: HealthSyncCursorKey,
            requiring lease: HealthSyncAuthenticatedLease
        ) throws -> CursorRecord {
            guard let blob = HealthKitAnchorArchive.encodeAnchor(anchor, label: key.source.rawValue) else {
                markFailed(key, reason: "anchor could not be archived")
                throw HealthSyncCursorStoreError.malformedAnchor
            }
            return try save(anchor: blob, for: key, requiring: lease)
        }

        /// The stored anchor decoded back into HealthKit's type. An unreadable
        /// blob reads as `nil` — a controlled, logged reset — never as a crash.
        func queryAnchor(for key: HealthSyncCursorKey) -> HKQueryAnchor? {
            HealthKitAnchorArchive.decodeAnchor(anchor(for: key), label: key.source.rawValue)
        }
    }

#endif
