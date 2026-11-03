import Foundation
@testable import HealthLog
import os
import Testing

/// **1.4 / iOS 27 — Apple Health doses behind a limited history window.**
///
/// The dose ledger used to drop a pending dose that a sweep did not see again,
/// on the grounds that it was deleted in Apple Health. With a limited window a
/// pending dose older than the window cannot be seen again, so dropping it would
/// lose an intake that never reached the server (`AppleHealthDoseLedger`, the
/// lines that filter `observed`). These pin the ledger rule and the importer
/// path that feeds it: ask for the window before the read, start the read no
/// earlier than the window, and judge absences against it.
@Suite("Apple Health doses with a limited history window (iOS 27)", .serialized, .mockURLSession)
struct AppleHealthLimitedDoseHistoryTests {
    private static let owner = "account-limited"
    private static let held = Date(timeIntervalSince1970: 1_790_000_000)
    private static let boundary = held.addingTimeInterval(86400)

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

    private func makeLedger() throws -> AppleHealthDoseLedger {
        let suite = "a3.limited.ledger.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let key = try #require(HealthSyncCursorKey(
            ownerID: Self.owner,
            source: .appleMedication,
            typeIdentifier: AppleHealthDoseLedger.typeIdentifier
        ))
        return AppleHealthDoseLedger(storage: .userDefaults(defaults), key: key)
    }

    /// A ledger with one dose held back at ``held``.
    private func ledgerHoldingOneDose() throws -> AppleHealthDoseLedger {
        let ledger = try makeLedger()
        try ledger.commit(observed: ["dose-held": Self.held], accountedFor: [], requiring: lease())
        return ledger
    }

    // MARK: - The ledger

    @Test("a pending dose before a limited window stays pending when the sweep cannot see it")
    func pendingBeforeTheWindowIsKept() throws {
        let ledger = try ledgerHoldingOneDose()
        try ledger.commit(
            observed: [:],
            accountedFor: [],
            readWindow: .limited(from: Self.boundary),
            requiring: lease()
        )
        #expect(ledger.pendingIdentities() == ["dose-held"])
        #expect(ledger.resumeInstant() == Self.held)
    }

    @Test("a pending dose inside the window that is gone was deleted and is dropped")
    func pendingInsideTheWindowIsDropped() throws {
        let ledger = try ledgerHoldingOneDose()
        try ledger.commit(
            observed: [:],
            accountedFor: [],
            readWindow: .limited(from: Self.held.addingTimeInterval(-60)),
            requiring: lease()
        )
        #expect(ledger.pendingIdentities().isEmpty)
    }

    @Test("when HealthKit cannot say how far back it reads, nothing pending is dropped")
    func unknownWindowKeepsEverything() throws {
        let ledger = try ledgerHoldingOneDose()
        try ledger.commit(observed: [:], accountedFor: [], readWindow: .unknown, requiring: lease())
        #expect(ledger.pendingIdentities() == ["dose-held"])
    }

    @Test("full access keeps the 1.3 rule: a dose that does not come back was deleted")
    func fullAccessDropsAsBefore() throws {
        let ledger = try ledgerHoldingOneDose()
        try ledger.commit(observed: [:], accountedFor: [], readWindow: .unlimited, requiring: lease())
        #expect(ledger.pendingIdentities().isEmpty)
    }

    @Test("a kept dose that comes back once access widens is settled as usual")
    func keptDoseSettlesLater() throws {
        let ledger = try ledgerHoldingOneDose()
        try ledger.commit(observed: [:], accountedFor: [], readWindow: .limited(from: Self.boundary), requiring: lease())
        try ledger.commit(
            observed: ["dose-held": Self.held],
            accountedFor: ["dose-held"],
            readWindow: .unlimited,
            requiring: lease()
        )
        #expect(ledger.pendingIdentities().isEmpty)
    }

    // MARK: - The importer

    @Test("the importer clamps its read to the window and keeps the hidden held dose")
    func importerKeepsTheHiddenHeldDose() async throws {
        let (api, keychain) = MedFixtures.makeAPI()
        try keychain.setString(Self.owner, forKey: KeychainKey.userID)
        let recorder = MedicationRequestRecorder()
        // The server mirrors nothing, so the dose's concept is unknown and the
        // dose is held back: no mirror POST, no bulk POST.
        MockURLProtocol.install { req in
            recorder.record(req)
            return (MedFixtures.ok(req), Data(MedFixtures.medListEnvelope([]).utf8))
        }
        let dose = AppleHealthDoseRecord(
            eventUUID: "dose-held",
            conceptIdentifier: MedFixtures.conceptA,
            logStatus: .taken,
            scheduledAt: Self.held,
            takenAt: Self.held
        )
        let reader = WindowedDoseReader(doses: [dose], window: .unlimited)
        let suite = "a3.limited.importer.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = AppleHealthMirrorRegistry(userID: Self.owner, defaultsProvider: { UserDefaults(suiteName: suite) ?? .standard })
        _ = sessions.activate(ownerID: Self.owner)
        let importer = try AppleHealthMedicationImporter(
            reader: reader,
            repo: MedicationsRepository(api: api, outbox: OutboxQueue(inMemory: true)),
            keychain: keychain,
            registry: registry,
            admission: HealthSyncImporterAdmission
                .keychainBound(keychain: keychain, registry: sessions)
                .provider(for: .appleMedication),
            ledgerStorage: .userDefaults(defaults),
            syncTrigger: SyncTriggerContext()
        )
        let ledger = try AppleHealthDoseLedger(
            storage: .userDefaults(defaults),
            key: #require(HealthSyncCursorKey(
                ownerID: Self.owner,
                source: .appleMedication,
                typeIdentifier: AppleHealthDoseLedger.typeIdentifier
            ))
        )

        let first = await importer.sync()
        #expect(first.dosesHeldBackNotMirrored == 1)
        #expect(ledger.pendingIdentities() == ["dose-held"])

        // The person narrows Apple Health to a recent window: the held dose is
        // now older than the window and no longer readable.
        reader.update(doses: [], window: .limited(from: Self.boundary))
        _ = await importer.sync()

        #expect(reader.readStarts.last == Self.boundary, "the read starts at the window, not before")
        #expect(ledger.pendingIdentities() == ["dose-held"], "a dose that never reached the server is kept")
        #expect(recorder.bulkPostCount == 0)
    }
}

/// A medication reader whose doses and readable window change between sweeps,
/// and which records where every dose read started.
private final class WindowedDoseReader: AppleHealthMedicationReading, @unchecked Sendable {
    private struct State {
        var doses: [AppleHealthDoseRecord]
        var window: HealthReadWindow
        var readStarts: [Date?] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(doses: [AppleHealthDoseRecord], window: HealthReadWindow) {
        state = OSAllocatedUnfairLock(initialState: State(doses: doses, window: window))
    }

    func update(doses: [AppleHealthDoseRecord], window: HealthReadWindow) {
        state.withLock {
            $0.doses = doses
            $0.window = window
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
        []
    }

    func readDoseEvents(since: Date?) async throws -> [AppleHealthDoseRecord] {
        state.withLock {
            $0.readStarts.append(since)
            return $0.doses
        }
    }

    func doseReadWindow() async -> HealthReadWindow {
        state.withLock { $0.window }
    }
}
