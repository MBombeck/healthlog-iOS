import Foundation
@testable import HealthLog
import os
import Testing

/// **Phase 07 / plan 07-05 — the Apple-medication dose ledger.**
///
/// The type that replaced the single `Date` watermark. What a watermark could
/// not express, and each of these pins: a hole behind a moving horizon, a
/// sibling that shares an instant, an owner who may not write, and a write that
/// did not survive its own read-back.
@Suite("Apple Health dose ledger")
struct AppleHealthDoseLedgerTests {
    // MARK: - Fixtures

    private final class Backing: @unchecked Sendable {
        private let entries = OSAllocatedUnfairLock(initialState: [String: Data]())
        private let dropWrites = OSAllocatedUnfairLock(initialState: false)

        var dropsWrites: Bool {
            get { dropWrites.withLock { $0 } }
            set { dropWrites.withLock { $0 = newValue } }
        }

        var storage: HealthSyncCursorStorage {
            HealthSyncCursorStorage(
                read: { [entries] key in entries.withLock { $0[key] } },
                write: { [entries, dropWrites] key, value in
                    guard !dropWrites.withLock({ $0 }) else { return }
                    entries.withLock { $0[key] = value }
                }
            )
        }
    }

    private let sessions = AuthenticatedSessionLeaseRegistry()

    private func lease(owner: String = "account-a") throws -> HealthSyncAuthenticatedLease {
        _ = sessions.activate(ownerID: owner)
        return try HealthSyncAuthenticatedLease.admit(
            from: sessions,
            ownerID: owner,
            source: .appleMedication,
            bearerProvider: { "token-\(owner)" }
        )
    }

    private func key(owner: String = "account-a") throws -> HealthSyncCursorKey {
        try #require(
            HealthSyncCursorKey(
                ownerID: owner,
                source: .appleMedication,
                typeIdentifier: AppleHealthDoseLedger.typeIdentifier
            )
        )
    }

    private static let held = Date(timeIntervalSince1970: 1_000_000)
    private static let later = Date(timeIntervalSince1970: 1_000_600)

    // MARK: - Progression

    @Test("A fresh partition has no bound and reads everything")
    func aFreshPartitionHasNoResumeBound() throws {
        let ledger = try AppleHealthDoseLedger(storage: Backing().storage, key: key())
        #expect(ledger.resumeInstant() == nil)
        #expect(ledger.pendingIdentities().isEmpty)
    }

    @Test("The resume instant is the oldest pending dose, not the newest imported one")
    func resumeInstantIsTheOldestPendingDose() throws {
        let ledger = try AppleHealthDoseLedger(storage: Backing().storage, key: key())
        try ledger.commit(
            observed: ["dose-held": Self.held, "dose-later": Self.later],
            accountedFor: ["dose-later"],
            requiring: lease()
        )

        #expect(ledger.resumeInstant() == Self.held)
        #expect(ledger.pendingIdentities() == ["dose-held"])
    }

    @Test("An equal-timestamp sibling stays reachable because the bound is inclusive")
    func equalTimestampSiblingStaysReachable() throws {
        let ledger = try AppleHealthDoseLedger(storage: Backing().storage, key: key())
        try ledger.commit(
            observed: ["dose-later": Self.later, "dose-sibling": Self.later],
            accountedFor: ["dose-later"],
            requiring: lease()
        )

        // `HKQuery.predicateForSamples(withStart:end:)` includes its start, so a
        // resume instant equal to the sibling's own instant re-offers it.
        #expect(ledger.resumeInstant() == Self.later)
        #expect(ledger.pendingIdentities() == ["dose-sibling"])
    }

    @Test("With nothing pending the resume instant falls back to the horizon")
    func anEmptyPendingSetFallsBackToTheHorizon() throws {
        let ledger = try AppleHealthDoseLedger(storage: Backing().storage, key: key())
        let admission = try lease()
        try ledger.commit(
            observed: ["dose-held": Self.held, "dose-later": Self.later],
            accountedFor: ["dose-later"],
            requiring: admission
        )
        // The held dose finally lands on a later sweep.
        try ledger.commit(
            observed: ["dose-held": Self.held, "dose-later": Self.later],
            accountedFor: ["dose-held", "dose-later"],
            requiring: admission
        )

        #expect(ledger.pendingIdentities().isEmpty)
        #expect(ledger.resumeInstant() == Self.later)
    }

    @Test("The horizon never moves backwards")
    func horizonIsMonotonic() throws {
        let ledger = try AppleHealthDoseLedger(storage: Backing().storage, key: key())
        let admission = try lease()
        try ledger.commit(observed: ["a": Self.later], accountedFor: ["a"], requiring: admission)
        // A later sweep that happens to see only an older dose must not rewind.
        try ledger.commit(observed: ["b": Self.held], accountedFor: ["b"], requiring: admission)

        #expect(ledger.resumeInstant() == Self.later)
    }

    @Test("A pending dose deleted in Apple Health is dropped rather than held forever")
    func aDeletedPendingDoseIsDropped() throws {
        let ledger = try AppleHealthDoseLedger(storage: Backing().storage, key: key())
        let admission = try lease()
        try ledger.commit(observed: ["gone": Self.held], accountedFor: [], requiring: admission)
        #expect(ledger.pendingIdentities() == ["gone"])

        // The next sweep reads the same window (it starts at `held`) and the
        // dose is simply not there any more.
        try ledger.commit(observed: [:], accountedFor: [], requiring: admission)
        #expect(ledger.pendingIdentities().isEmpty)
    }

    // MARK: - Migration from the legacy watermark

    @Test("The legacy date watermark seeds the horizon exactly once")
    func theLegacyWatermarkSeedsOnce() throws {
        let ledger = try AppleHealthDoseLedger(storage: Backing().storage, key: key())
        let admission = try lease()

        #expect(try ledger.seedFromDateCursorIfNeeded(Self.later, requiring: admission))
        #expect(ledger.resumeInstant() == Self.later)

        // A second seed — with a *different* value — must not rewind or advance
        // an established partition.
        #expect(try !ledger.seedFromDateCursorIfNeeded(Self.held, requiring: admission))
        #expect(ledger.resumeInstant() == Self.later)
    }

    @Test("A device with no legacy watermark starts unbounded, and stays established")
    func noLegacyWatermarkStillEstablishesThePartition() throws {
        let ledger = try AppleHealthDoseLedger(storage: Backing().storage, key: key())
        let admission = try lease()

        #expect(try ledger.seedFromDateCursorIfNeeded(nil, requiring: admission))
        #expect(ledger.resumeInstant() == nil)
        #expect(try !ledger.seedFromDateCursorIfNeeded(Self.later, requiring: admission))
    }

    // MARK: - Ownership and proof

    @Test("A lease may not write another account's partition")
    func aLeaseCannotWriteAnotherOwnersPartition() throws {
        let ledger = try AppleHealthDoseLedger(storage: Backing().storage, key: key(owner: "account-b"))
        #expect(throws: HealthSyncCursorStoreError.partitionOwnerMismatch) {
            try ledger.commit(observed: ["a": Self.later], accountedFor: [], requiring: lease(owner: "account-a"))
        }
    }

    @Test("A stale admission writes nothing")
    func aStaleAdmissionWritesNothing() throws {
        let ledger = try AppleHealthDoseLedger(storage: Backing().storage, key: key())
        let admission = try lease(owner: "account-a")
        _ = sessions.activate(ownerID: "account-b")

        #expect(throws: HealthSyncLeaseRefusal.staleSession) {
            try ledger.commit(observed: ["a": Self.later], accountedFor: [], requiring: admission)
        }
        #expect(ledger.resumeInstant() == nil)
    }

    @Test("A write that does not survive its own read-back is not progress")
    func aLostWriteIsRefused() throws {
        let backing = Backing()
        let ledger = try AppleHealthDoseLedger(storage: backing.storage, key: key())
        backing.dropsWrites = true

        #expect(throws: HealthSyncCursorStoreError.writeNotVerified) {
            try ledger.commit(observed: ["a": Self.later], accountedFor: ["a"], requiring: lease())
        }
        #expect(ledger.resumeInstant() == nil, "a silently dropped write must not read as progress")
    }

    @Test("Two owners get disjoint partitions from the same identities")
    func ownersGetDisjointPartitions() throws {
        let backing = Backing()
        let ledgerA = try AppleHealthDoseLedger(storage: backing.storage, key: key(owner: "account-a"))
        let ledgerB = try AppleHealthDoseLedger(storage: backing.storage, key: key(owner: "account-b"))
        #expect(ledgerA.storageKey != ledgerB.storageKey)
        #expect(!ledgerA.storageKey.contains("account-a"), "the owner is hashed, never named in a defaults dump")

        try ledgerA.commit(observed: ["a": Self.later], accountedFor: [], requiring: lease(owner: "account-a"))
        #expect(ledgerB.resumeInstant() == nil)
        #expect(ledgerB.pendingIdentities().isEmpty)
    }
}
