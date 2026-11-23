import Foundation
@testable import HealthLog
import os
import Testing

/// Doses that appear in Apple Health with an earlier time than the newest one
/// already imported: entered afterwards, edited (a new event), synced late from
/// the Watch, or of a medication shared with HealthLog only later.
///
/// The read used to start at the horizon, so such a dose was never read. Every
/// sweep now reads a trailing window behind the horizon again, and a newly
/// shared medication once in full. The ledger's settled set keeps the re-read
/// from posting a dose twice.
@Suite("Apple Health doses logged late (trailing window)", .serialized, .mockURLSession)
struct AppleHealthDoseTrailingWindowTests {
    private static let owner = "account-trailing"
    private static let now = Date(timeIntervalSince1970: 1_791_000_000)
    private static let day: TimeInterval = 86400
    private static let conceptB = AppleHealthConceptKey.derive(fromArchivedIdentifier: Data("concept-B".utf8))
    private static let medA = AppleHealthMedicationRecord(conceptIdentifier: MedFixtures.conceptA, name: "Magnesium")
    private static let medB = AppleHealthMedicationRecord(conceptIdentifier: conceptB, name: "Lisinopril")

    private let sessions = AuthenticatedSessionLeaseRegistry()

    private func lease() throws -> HealthSyncAuthenticatedLease {
        _ = sessions.activate(ownerID: Self.owner)
        return try HealthSyncAuthenticatedLease.admit(
            from: sessions,
            ownerID: Self.owner,
            source: .appleMedication,
            bearerProvider: { "token" }
        )
    }

    private func makeLedger(storage: HealthSyncCursorStorage? = nil) throws -> AppleHealthDoseLedger {
        let defaults = try #require(UserDefaults(suiteName: "trailing.ledger.\(UUID().uuidString)"))
        let key = try #require(HealthSyncCursorKey(
            ownerID: Self.owner,
            source: .appleMedication,
            typeIdentifier: AppleHealthDoseLedger.typeIdentifier
        ))
        return AppleHealthDoseLedger(storage: storage ?? .userDefaults(defaults), key: key)
    }

    private static func dose(_ id: String, daysAgo: Double, concept: String = MedFixtures.conceptA) -> AppleHealthDoseRecord {
        let instant = now.addingTimeInterval(-daysAgo * day)
        return AppleHealthDoseRecord(
            eventUUID: id,
            conceptIdentifier: concept,
            logStatus: .taken,
            scheduledAt: instant,
            takenAt: instant
        )
    }

    // MARK: - The ledger

    @Test("the read starts a week behind the horizon, or earlier at the oldest pending dose")
    func readStartCoversTheTrailingWindow() throws {
        let ledger = try makeLedger()
        #expect(ledger.readStart() == nil, "a first sweep reads everything")

        try ledger.commit(observed: ["a": Self.now], accountedFor: ["a"], requiring: lease())
        #expect(ledger.readStart() == Self.now.addingTimeInterval(-AppleHealthDoseLedger.trailingWindow))
        #expect(ledger.resumeInstant() == Self.now)

        let held = Self.now.addingTimeInterval(-20 * Self.day)
        try ledger.commit(observed: ["a": Self.now, "held": held], accountedFor: ["a"], requiring: lease())
        #expect(ledger.readStart() == held)
    }

    @Test("settled doses are remembered inside the window and forgotten outside it")
    func settledFollowsTheWindow() throws {
        let ledger = try makeLedger()
        let inside = Self.now.addingTimeInterval(-2 * Self.day)
        let outside = Self.now.addingTimeInterval(-8 * Self.day)
        try ledger.commit(
            observed: ["new": Self.now, "inside": inside, "outside": outside, "held": inside],
            accountedFor: ["new", "inside", "outside"],
            requiring: lease()
        )
        #expect(ledger.settledIdentities() == ["new", "inside"])
        #expect(ledger.pendingIdentities() == ["held"])
    }

    @Test("settled doses stay remembered back to the oldest pending dose")
    func settledReachesTheOldestPending() throws {
        let ledger = try makeLedger()
        let held = Self.now.addingTimeInterval(-20 * Self.day)
        var observed = ["held": held, "new": Self.now]
        for index in 0 ..< 50 {
            observed["old-\(index)"] = Self.now.addingTimeInterval(-Double(8 + index % 10) * Self.day)
        }
        let settled = Set(observed.keys).subtracting(["held"])
        try ledger.commit(observed: observed, accountedFor: settled, requiring: lease())
        #expect(ledger.readStart() == held)
        #expect(ledger.settledIdentities() == settled)

        // Once the held dose is settled, the window alone decides again.
        try ledger.commit(observed: observed, accountedFor: Set(observed.keys), requiring: lease())
        #expect(ledger.settledIdentities() == ["new"])
    }

    @Test("a record from 1.6 without the new fields still reads, with nothing settled")
    func recordFromBeforeTheWindowStillReads() throws {
        let defaults = try #require(UserDefaults(suiteName: "trailing.legacy.\(UUID().uuidString)"))
        let ledger = try makeLedger(storage: .userDefaults(defaults))
        let json = #"""
        {"version":2,"horizon":0,"pending":{},"seededFromDateCursor":true,"updatedAt":0}
        """#
        defaults.set(Data(json.utf8), forKey: ledger.storageKey)
        let record = try #require(ledger.record())
        #expect(record.settled == nil)
        #expect(ledger.settledIdentities().isEmpty)
        #expect(ledger.knownConcepts() == nil)
        #expect(ledger.readStart() == Date(timeIntervalSinceReferenceDate: 0).addingTimeInterval(-AppleHealthDoseLedger.trailingWindow))
    }

    // MARK: - The importer

    @Test("a dose logged later with an earlier time arrives, and nothing is posted twice")
    func lateDoseArrivesWithoutDuplicates() async throws {
        let harness = try Harness(medications: [Self.medA], doses: [Self.dose("A-now", daysAgo: 0)])

        _ = await harness.importer.sync()
        #expect(harness.postedIDs == [["A-now"]])

        // Entered afterwards for two days ago, and an edit of three days ago
        // (Apple Health stores an edit as a new event).
        harness.reader.update(doses: [
            Self.dose("A-now", daysAgo: 0),
            Self.dose("A-late", daysAgo: 2),
            Self.dose("A-edited", daysAgo: 3)
        ])
        _ = await harness.importer.sync()

        #expect(harness.reader.readStarts.last == Self.now.addingTimeInterval(-AppleHealthDoseLedger.trailingWindow))
        #expect(harness.postedIDs == [["A-now"], ["A-edited", "A-late"]])
        #expect(harness.ledger.pendingIdentities().isEmpty)

        // A third sweep finds nothing new and posts nothing.
        _ = await harness.importer.sync()
        #expect(harness.postedIDs.count == 2)
    }

    @Test("a medication shared later has its whole history read once, the others are not sent again")
    func newlySharedMedicationIsReadInFull() async throws {
        let harness = try Harness(
            medications: [Self.medA],
            doses: [Self.dose("A-old", daysAgo: 30), Self.dose("A-now", daysAgo: 0)]
        )
        _ = await harness.importer.sync()
        #expect(harness.postedIDs == [["A-now", "A-old"]])
        #expect(harness.ledger.knownConcepts() == [MedFixtures.conceptA])

        // The person allows HealthLog to read a second medication.
        harness.reader.update(
            medications: [Self.medA, Self.medB],
            doses: [
                Self.dose("A-old", daysAgo: 30),
                Self.dose("A-now", daysAgo: 0),
                Self.dose("B-old", daysAgo: 40, concept: Self.conceptB)
            ]
        )
        _ = await harness.importer.sync()

        #expect(harness.reader.readStarts.last == .some(nil), "the full history is read once")
        #expect(harness.postedIDs == [["A-now", "A-old"], ["B-old"]])
        #expect(harness.ledger.knownConcepts() == [MedFixtures.conceptA, Self.conceptB])

        _ = await harness.importer.sync()
        #expect(harness.reader.readStarts.last != .some(nil), "and only once")
        #expect(harness.postedIDs.count == 2)
    }

    @Test("the first sweep after the update from 1.6 reads everything once, the server folds the repeats")
    func firstSweepAfterTheUpdateFrom16() async throws {
        let harness = try Harness(
            medications: [Self.medA, Self.medB],
            doses: [
                Self.dose("A-old", daysAgo: 30),
                Self.dose("A-mid", daysAgo: 3),
                Self.dose("A-now", daysAgo: 0),
                // Shared after the last 1.6 sweep, older than its horizon.
                Self.dose("B-old", daysAgo: 40, concept: Self.conceptB)
            ]
        )
        harness.answerDuplicate()
        // The record exactly as 1.6 wrote it: no settled set, no concept list.
        let horizon = Self.now.timeIntervalSinceReferenceDate
        let json = #"{"version":2,"horizon":\#(horizon),"pending":{},"seededFromDateCursor":true,"updatedAt":\#(horizon)}"#
        harness.defaults.set(Data(json.utf8), forKey: harness.ledger.storageKey)
        #expect(harness.ledger.knownConcepts() == nil)
        #expect(harness.ledger.readStart() == Self.now.addingTimeInterval(-AppleHealthDoseLedger.trailingWindow))

        let first = await harness.importer.sync()

        #expect(harness.reader.readStarts.last == .some(nil), "one full read")
        #expect(harness.postedIDs == [["A-mid", "A-now", "A-old", "B-old"]])
        // The mock answers every entry `duplicate`, as the server does for repeats.
        #expect(first.dosesDuplicate == 4)
        #expect(harness.ledger.knownConcepts() == [MedFixtures.conceptA, Self.conceptB])
        #expect(harness.ledger.readStart() == Self.now.addingTimeInterval(-AppleHealthDoseLedger.trailingWindow))

        _ = await harness.importer.sync()
        #expect(harness.reader.readStarts.last == Self.now.addingTimeInterval(-AppleHealthDoseLedger.trailingWindow))
        #expect(harness.postedIDs.count == 1, "the second sweep posts nothing")
    }

    @Test("a held old dose keeps the settled doses behind the window, so none is posted again")
    func heldDoseKeepsSettledDoses() async throws {
        // Concept C is not mirrored: its dose is held back and stays pending.
        let conceptC = AppleHealthConceptKey.derive(fromArchivedIdentifier: Data("concept-C".utf8))
        let harness = try Harness(
            medications: [Self.medA],
            doses: [
                Self.dose("C-held", daysAgo: 20, concept: conceptC),
                Self.dose("A-old", daysAgo: 10),
                Self.dose("A-now", daysAgo: 0)
            ]
        )
        _ = await harness.importer.sync()
        #expect(harness.postedIDs == [["A-now", "A-old"]])
        #expect(harness.ledger.pendingIdentities() == ["C-held"])
        #expect(harness.ledger.settledIdentities() == ["A-now", "A-old"])

        _ = await harness.importer.sync(maxDoseChunks: 1)
        #expect(harness.reader.readStarts.last == Self.now.addingTimeInterval(-20 * Self.day))
        #expect(harness.postedIDs.count == 1, "nothing settled is posted again, the budget stays free")
    }

    @Test("a medication taken away and shared again is read in full once more")
    func medicationSharedAgain() async throws {
        let harness = try Harness(
            medications: [Self.medA, Self.medB],
            doses: [Self.dose("A-now", daysAgo: 0), Self.dose("B-old", daysAgo: 40, concept: Self.conceptB)]
        )
        _ = await harness.importer.sync()
        harness.reader.update(medications: [Self.medA], doses: [Self.dose("A-now", daysAgo: 0)])
        _ = await harness.importer.sync()
        #expect(harness.ledger.knownConcepts() == [MedFixtures.conceptA])

        harness.reader.update(
            medications: [Self.medA, Self.medB],
            doses: [Self.dose("A-now", daysAgo: 0), Self.dose("B-old", daysAgo: 40, concept: Self.conceptB)]
        )
        _ = await harness.importer.sync()
        #expect(harness.reader.readStarts.last == .some(nil))
        #expect(harness.ledger.knownConcepts() == [MedFixtures.conceptA, Self.conceptB])
    }
}

// MARK: - Harness

/// One importer over a reader that honours `since`, a server that mirrors
/// both concepts and answers every bulk entry `inserted`, and the ledger.
private final class Harness: @unchecked Sendable {
    let reader: SinceHonouringReader
    let importer: AppleHealthMedicationImporter
    let ledger: AppleHealthDoseLedger
    let recorder: MedicationRequestRecorder
    let lease: HealthSyncAuthenticatedLease
    let defaults: UserDefaults
    private let bulkStatus: OSAllocatedUnfairLock<String>

    init(medications: [AppleHealthMedicationRecord], doses: [AppleHealthDoseRecord]) throws {
        let recorder = MedicationRequestRecorder()
        self.recorder = recorder
        let bulkStatus = OSAllocatedUnfairLock(initialState: "inserted")
        self.bulkStatus = bulkStatus
        MockURLProtocol.install { req in
            recorder.record(req)
            let path = req.url?.path ?? ""
            if path == "/api/medications" {
                let rows = [
                    (id: "srv-A", name: "Magnesium", externalId: Optional(MedFixtures.conceptA)),
                    (id: "srv-B", name: "Lisinopril", externalId: Optional(
                        AppleHealthConceptKey.derive(fromArchivedIdentifier: Data("concept-B".utf8))
                    ))
                ]
                return (MedFixtures.ok(req), Data(MedFixtures.medListEnvelope(rows).utf8))
            }
            let count = recorder.bulkEntryCounts.last ?? 0
            let status = bulkStatus.withLock { $0 }
            return (MedFixtures.ok(req), Data(Harness.bulkAnswer(count, status: status).utf8))
        }
        let (api, keychain) = MedFixtures.makeAPI()
        reader = SinceHonouringReader(medications: medications, doses: doses)
        let sessions = AuthenticatedSessionLeaseRegistry()
        _ = sessions.activate(ownerID: MedFixtures.ownerID)
        let suite = "trailing.importer.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        self.defaults = defaults
        let storage = HealthSyncCursorStorage.userDefaults(defaults)
        importer = try AppleHealthMedicationImporter(
            reader: reader,
            repo: MedicationsRepository(api: api, outbox: OutboxQueue(inMemory: true)),
            keychain: keychain,
            registry: AppleHealthMirrorRegistry(
                userID: MedFixtures.ownerID,
                defaultsProvider: { UserDefaults(suiteName: suite) ?? .standard }
            ),
            admission: HealthSyncImporterAdmission
                .keychainBound(keychain: keychain, registry: sessions)
                .provider(for: .appleMedication),
            ledgerStorage: storage,
            syncTrigger: SyncTriggerContext()
        )
        ledger = try AppleHealthDoseLedger(
            storage: storage,
            key: #require(HealthSyncCursorKey(
                ownerID: MedFixtures.ownerID,
                source: .appleMedication,
                typeIdentifier: AppleHealthDoseLedger.typeIdentifier
            ))
        )
        lease = try HealthSyncAuthenticatedLease.admit(
            from: sessions,
            ownerID: MedFixtures.ownerID,
            source: .appleMedication,
            bearerProvider: { "bearer-abc" }
        )
    }

    /// Every later bulk entry comes back `duplicate`, as for a repeat.
    func answerDuplicate() {
        bulkStatus.withLock { $0 = "duplicate" }
    }

    static func bulkAnswer(_ count: Int, status: String) -> String {
        let entries = (0 ..< count).map { #"{"index":\#($0),"status":"\#(status)","id":"intake-\#($0)"}"# }
        let inserted = status == "inserted" ? count : 0
        let duplicates = status == "duplicate" ? count : 0
        return #"""
        {"data":{"processed":\#(count),"inserted":\#(inserted),"updated":0,"duplicates":\#(duplicates),\#
        "skipped":[],"entries":[\#(entries.joined(separator: ","))]},"error":null}
        """#
    }

    /// The dose UUIDs of every bulk POST, sorted within each POST.
    var postedIDs: [[String]] {
        recorder.bulkBodies.map { body in
            ((body["entries"] as? [[String: Any]]) ?? []).compactMap { $0["externalId"] as? String }.sorted()
        }
    }
}

/// A reader that returns only the doses from `since` on, like the HealthKit
/// predicate, and records where each read started.
private final class SinceHonouringReader: AppleHealthMedicationReading, @unchecked Sendable {
    private struct State {
        var medications: [AppleHealthMedicationRecord]
        var doses: [AppleHealthDoseRecord]
        var readStarts: [Date?] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(medications: [AppleHealthMedicationRecord], doses: [AppleHealthDoseRecord]) {
        state = OSAllocatedUnfairLock(initialState: State(medications: medications, doses: doses))
    }

    func update(medications: [AppleHealthMedicationRecord]? = nil, doses: [AppleHealthDoseRecord]) {
        state.withLock {
            if let medications { $0.medications = medications }
            $0.doses = doses
        }
    }

    var readStarts: [Date?] {
        state.withLock { $0.readStarts }
    }

    var isAvailable: Bool {
        true
    }

    func requestAuthorization() async throws {}

    func readMedications() async throws -> [AppleHealthMedicationRecord] {
        state.withLock { $0.medications }
    }

    func readDoseEvents(since: Date?) async throws -> [AppleHealthDoseRecord] {
        state.withLock { state in
            state.readStarts.append(since)
            return state.doses.filter { dose in since.map { dose.recordedAt >= $0 } ?? true }
        }
    }
}
