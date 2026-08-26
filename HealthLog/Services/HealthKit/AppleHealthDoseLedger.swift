import Foundation

// Phase 07 Wave 3 — the Apple-medication dose ledger.
//
// The shipped importer kept one `Date` watermark: it imported whatever it could,
// then moved the watermark to the newest instant it managed to import. Two
// events are permanently lost that way, and Wave 0 pinned both:
//
//   * A dose whose concept is not mirrored yet is *held back* on purpose. If any
//     later dose lands in the same sweep, the watermark jumps past the held one
//     and the next read — which starts at the watermark — never offers it again.
//   * Two doses can share an instant. `event.recordedAt > cursor` drops the
//     sibling that shares the watermark's own instant, so an equal-timestamp
//     pair loses one row even when both were importable.
//
// A timestamp cannot express "everything up to here landed EXCEPT these three".
// This ledger can: it stores a horizon plus the explicit set of dose identities
// that are known and not yet terminally accounted for, and the next read resumes
// at the *oldest pending* instant rather than the newest imported one.
//
// Three properties are deliberate:
//
//   * Identity is the HealthKit dose-event UUID — the same value the bulk route
//     already carries as `externalId`, so the ledger, the wire payload, and the
//     server's dedup key are one identity rather than three.
//   * The partition is `{owner, appleMedication, HKMedicationDoseEvent}`, built
//     from the admitted owner lease. A blank owner cannot construct a key, so
//     this ledger can never become installation-global the way the date cursor
//     was per-user-but-not-per-session.
//   * A write counts only after a read-back returns the same record. A silently
//     lost `UserDefaults` write can therefore never leave the importer claiming
//     doses are accounted for when they are not — the same rule
//     `DurableHealthCursorStore` applies to sample anchors.
//
// The legacy `hl.medications.appleHealth.doseCursor.<token>` value is read once,
// to seed the horizon, and then never written again. It is not deleted: it is
// the rollback material for this plan, frozen at whatever the last watermark
// sweep left behind.

/// Durable, owner-partitioned per-dose progression for the Apple Health
/// medication importer.
struct AppleHealthDoseLedger: Sendable {
    /// On-disk format version. Bumping it makes every older record read as
    /// absent rather than as silently-compatible.
    static let formatVersion = 2

    /// The HealthKit object type this ledger tracks. Part of the partition key
    /// so the medication source can never collide with another importer's.
    static let typeIdentifier = "HKMedicationDoseEvent"

    /// One partition's progression.
    ///
    /// `horizon` is the newest instant this importer has *observed*; `pending`
    /// is every observed dose that is not yet terminally accounted for, with the
    /// instant it was recorded at. The pair is what makes a hole expressible:
    /// the horizon may move forward while a hole behind it stays open.
    struct Record: Codable, Sendable, Equatable {
        let version: Int
        let horizon: Date?
        let pending: [String: Date]
        /// `true` once the legacy date watermark has been folded in, so the
        /// seed happens exactly once even if the legacy value is later cleared.
        let seededFromDateCursor: Bool
        let updatedAt: Date
    }

    private let storage: HealthSyncCursorStorage
    private let key: HealthSyncCursorKey
    private let clock: @Sendable () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        storage: HealthSyncCursorStorage,
        key: HealthSyncCursorKey,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.storage = storage
        self.key = key
        self.clock = clock
    }

    /// The partition this ledger writes, derived from the admitted owner lease
    /// rather than from an ambient user id.
    static func key(for owner: HealthSyncOwnerLease) -> HealthSyncCursorKey? {
        owner.cursorKey(typeIdentifier: typeIdentifier)
    }

    /// Storage key. A distinct suffix in the Phase-07 cursor namespace so a
    /// diagnostics dump shows the ledger next to the anchors it replaces, and so
    /// it can never be mistaken for an `HKQueryAnchor` blob.
    var storageKey: String {
        key.storageKey + ".doseLedger"
    }

    // MARK: - Reads

    /// The stored record, or `nil` when the partition has never been written or
    /// carries a version this build does not understand. Both read as "no
    /// progress", which costs a re-read rather than a lost dose.
    func record() -> Record? {
        guard let data = storage.read(storageKey),
              let decoded = try? decoder.decode(Record.self, from: data),
              decoded.version == Self.formatVersion else
        {
            return nil
        }
        return decoded
    }

    /// The instant the next HealthKit read must start from.
    ///
    /// The oldest still-pending dose when there is one, otherwise the horizon.
    /// `HKQuery.predicateForSamples(withStart:end:)` includes its start instant,
    /// so resuming *at* the pending instant re-offers that dose **and** every
    /// equal-timestamp sibling — which is exactly the second defect the
    /// watermark had.
    ///
    /// `nil` means "no bound": either a genuine first sweep, or a partition
    /// whose record could not be read.
    func resumeInstant() -> Date? {
        guard let record = record() else { return nil }
        if let oldestPending = record.pending.values.min() { return oldestPending }
        return record.horizon
    }

    /// Dose identities this ledger is still waiting to account for. Operator-
    /// grade: the count is what a diagnostics surface reports.
    func pendingIdentities() -> Set<String> {
        guard let record = record() else { return [] }
        return Set(record.pending.keys)
    }

    // MARK: - Writes

    /// Folds the legacy date watermark into a fresh partition exactly once.
    ///
    /// The legacy value is *read*, never moved and never deleted: it stays where
    /// the pre-Phase-07 importer wrote it, which is what makes a rollback of this
    /// plan resume from the same place it stopped. A partition that already has
    /// a record is left alone, so the seed cannot re-run and rewind a horizon.
    ///
    /// - Returns: `true` when this call created the record.
    @discardableResult
    func seedFromDateCursorIfNeeded(
        _ legacyWatermark: Date?,
        requiring lease: HealthSyncAuthenticatedLease
    ) throws -> Bool {
        guard record() == nil else { return false }
        try write(
            Record(
                version: Self.formatVersion,
                horizon: legacyWatermark,
                pending: [:],
                seededFromDateCursor: true,
                updatedAt: clock()
            ),
            requiring: lease
        )
        return true
    }

    /// Records what one sweep observed and what it terminally accounted for.
    ///
    /// - Parameters:
    ///   - observed: every dose this sweep read, with its recorded instant.
    ///   - accountedFor: the identities that are terminally done — landed on the
    ///     server, deterministically refused by it, or not importable by
    ///     contract. Everything else stays pending, including doses held back
    ///     because their concept is not mirrored yet and doses in a chunk that
    ///     never reached the server.
    ///
    /// The horizon only ever moves forward, and it moving forward is safe
    /// precisely because the holes travel with it in `pending`.
    func commit(
        observed: [String: Date],
        accountedFor: Set<String>,
        requiring lease: HealthSyncAuthenticatedLease
    ) throws {
        let previous = record()
        // Everything within the read window is re-observed, so a previously
        // pending identity that does not come back was deleted in Apple Health
        // and is correctly dropped rather than held forever.
        let pending = observed.filter { !accountedFor.contains($0.key) }
        let horizon = [previous?.horizon, observed.values.max()]
            .compactMap { $0 }
            .max()
        try write(
            Record(
                version: Self.formatVersion,
                horizon: horizon,
                pending: pending,
                seededFromDateCursor: previous?.seededFromDateCursor ?? true,
                updatedAt: clock()
            ),
            requiring: lease
        )
    }

    // MARK: - Private

    /// Validate, write, read back, validate again — the same ordering
    /// `DurableHealthCursorStore.save` uses, and for the same reason: an account
    /// replacement that lands during the write must not leave the new owner's
    /// partition carrying the old owner's progression.
    private func write(_ record: Record, requiring lease: HealthSyncAuthenticatedLease) throws {
        try lease.requireCurrent()
        guard lease.ownerID == key.ownerID else {
            throw HealthSyncCursorStoreError.partitionOwnerMismatch
        }
        guard let encoded = try? encoder.encode(record) else {
            throw HealthSyncCursorStoreError.malformedAnchor
        }
        storage.write(storageKey, encoded)
        guard let readBack = self.record(), readBack == record else {
            throw HealthSyncCursorStoreError.writeNotVerified
        }
        try lease.requireCurrent()
    }
}
