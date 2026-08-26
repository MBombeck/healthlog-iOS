import Foundation
@testable import HealthLog
import os
import Testing

/// Phase 07 Wave 0 — Apple medication dose durability.
///
/// The importer holds back a dose whose concept is not mirrored yet, then
/// advances one `Date` watermark to the newest dose it *did* import. A held
/// older dose therefore sits permanently behind the watermark: once a later
/// dose lands, the earlier one is never offered again. Equal timestamps make it
/// worse, because a strict `>` read drops the sibling that shares the instant.
@Suite("Apple medication cursor durability")
struct MedicationCursorDurabilityTests {
    struct DoseEvent: Equatable {
        let id: String
        let recordedAt: Date
        /// A dose whose concept is not mirrored yet is held back, never sent.
        let isMirrored: Bool
    }

    /// Model of the rule plan 07-05 **replaced**: import what is mirrored, then
    /// advance one `Date` to the newest imported instant.
    ///
    /// It is kept, and still exercised by the two tests below, because it is the
    /// reason the ledger exists: those two tests state exactly which rows a
    /// watermark loses. What changed is what the RED at the bottom of this file
    /// asserts — it now drives ``AppleHealthDoseLedger``, the type production
    /// actually runs, instead of this model.
    struct WatermarkCursor {
        private(set) var cursor: Date?
        private(set) var imported: [String] = []

        mutating func sweep(_ events: [DoseEvent]) {
            let visible = events.filter { event in
                guard let cursor else { return true }
                return event.recordedAt > cursor
            }
            var newest: Date?
            for event in visible where event.isMirrored {
                imported.append(event.id)
                newest = max(newest ?? event.recordedAt, event.recordedAt)
            }
            if let newest { cursor = newest }
        }

        func canStillSee(_ event: DoseEvent) -> Bool {
            guard let cursor else { return true }
            return event.recordedAt > cursor
        }
    }

    private static let held = DoseEvent(
        id: "dose-held",
        recordedAt: Date(timeIntervalSince1970: 1_000_000),
        isMirrored: false
    )
    private static let later = DoseEvent(
        id: "dose-later",
        recordedAt: Date(timeIntervalSince1970: 1_000_600),
        isMirrored: true
    )
    private static let sibling = DoseEvent(
        id: "dose-sibling",
        recordedAt: Date(timeIntervalSince1970: 1_000_600),
        isMirrored: false
    )

    @Test("the replaced watermark imports only the later dose")
    func heldDoseIsNotImported() {
        var model = WatermarkCursor()
        model.sweep([Self.held, Self.later])

        #expect(model.imported == ["dose-later"])
        #expect(model.cursor == Self.later.recordedAt)
    }

    @Test("the replaced watermark drops an equal-timestamp sibling")
    func equalTimestampSiblingIsDropped() {
        var model = WatermarkCursor()
        model.sweep([Self.later, Self.sibling])

        #expect(!model.canStillSee(Self.sibling))
    }

    @Test("a durable per-dose identity survives both cases")
    func durableIdentityCoversHeldAndSiblingDoses() throws {
        let heldEnvelope = try #require(
            HealthSyncRetryEnvelope(ownerID: "account-a", source: .appleMedication, stableIdentity: Self.held.id)
        )
        let siblingEnvelope = try #require(
            HealthSyncRetryEnvelope(ownerID: "account-a", source: .appleMedication, stableIdentity: Self.sibling.id)
        )

        #expect(heldEnvelope.idempotencyKey != siblingEnvelope.idempotencyKey)
        #expect(heldEnvelope.operationKey.contains(Self.held.id))
    }

    // MARK: - RED

    /// A later success may never make an older held dose unreachable, and the
    /// importer must keep per-dose durable state instead of one timestamp.
    ///
    /// **Restated by plan 07-05, in the commit that changed production.** The two
    /// progression clauses used to drive ``WatermarkCursor``, a local model of
    /// the rule this plan removes — so they could only ever fail, because that
    /// model *is* the defect. They now drive ``AppleHealthDoseLedger``, the type
    /// the importer runs, against the identical three-dose fixture. The source
    /// clauses are untouched.
    @Test("an older held event survives a later success")
    func olderHeldEventSurvivesLaterSuccess() throws {
        var violations: [String] = []

        // One sweep sees all three doses. Only `later` is mirrored, so only
        // `later` is accounted for; the held dose and the equal-timestamp
        // sibling stay pending.
        let ledger = try Self.ledger()
        try ledger.commit(
            observed: [
                Self.held.id: Self.held.recordedAt,
                Self.later.id: Self.later.recordedAt,
                Self.sibling.id: Self.sibling.recordedAt
            ],
            accountedFor: [Self.later.id],
            requiring: Self.lease()
        )
        // The next read resumes here. `HKQuery.predicateForSamples(withStart:)`
        // includes its start instant, so "at or before" is what keeps a dose
        // reachable.
        let resume = try #require(ledger.resumeInstant())
        if resume > Self.held.recordedAt {
            violations.append("the dose ledger hid a held dose behind a later success")
        }
        if resume > Self.sibling.recordedAt {
            violations.append("the dose ledger hid an equal-timestamp sibling dose")
        }
        if !ledger.pendingIdentities().isSuperset(of: [Self.held.id, Self.sibling.id]) {
            violations.append("the dose ledger did not retain the unaccounted dose identities")
        }

        let importer = try Self.source("HealthLog/Services/HealthKit/AppleHealthMedicationImporter.swift")
        if importer.contains("registry.advanceDoseCursor(to: maxImportedInstant)") {
            violations.append("the importer still advances one timestamp watermark")
        }
        if !importer.contains("HealthSyncRetryEnvelope") {
            violations.append("the importer keeps no durable per-dose retry identity")
        }
        if !importer.contains("HealthSyncOwnerLease") {
            violations.append("the importer captures no owner lease across its awaits")
        }

        #expect(violations.isEmpty, "EXPECTED_RED: later medication success skipped held event")
    }

    // MARK: - Production ledger fixture

    /// In-memory backing so the RED drives the real ledger without touching
    /// `UserDefaults.standard`.
    private final class Backing: @unchecked Sendable {
        private let entries = OSAllocatedUnfairLock(initialState: [String: Data]())

        var storage: HealthSyncCursorStorage {
            HealthSyncCursorStorage(
                read: { [entries] key in entries.withLock { $0[key] } },
                write: { [entries] key, value in entries.withLock { $0[key] = value } }
            )
        }
    }

    private static let sessions = AuthenticatedSessionLeaseRegistry()

    private static func lease() throws -> HealthSyncAuthenticatedLease {
        _ = sessions.activate(ownerID: "account-a")
        return try HealthSyncAuthenticatedLease.admit(
            from: sessions,
            ownerID: "account-a",
            source: .appleMedication,
            bearerProvider: { "token-account-a" }
        )
    }

    private static func ledger() throws -> AppleHealthDoseLedger {
        let key = try #require(
            HealthSyncCursorKey(
                ownerID: "account-a",
                source: .appleMedication,
                typeIdentifier: AppleHealthDoseLedger.typeIdentifier
            )
        )
        return AppleHealthDoseLedger(storage: Backing().storage, key: key)
    }

    // MARK: - Source access

    private static func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
