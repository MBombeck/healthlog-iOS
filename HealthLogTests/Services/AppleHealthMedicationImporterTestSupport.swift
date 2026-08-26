import Foundation
@testable import HealthLog
import os
import Testing

// swiftlint:disable force_unwrapping

// Shared doubles for the Apple-Health medication suites.
//
// Split out of `AppleHealthMedicationImporterTests.swift` by plan 07-05: the
// per-dose ledger fixtures pushed that file past the 600-line gate, and these
// three types were never suite-specific — they are the canned reader, the
// request recorder, and the body-stream drain every medication-mirror test uses.

/// Shared fixtures for both Apple-Health medication suites.
///
/// A namespace rather than per-suite privates: plan 07-05 split the dose-import
/// cases into their own suite (the combined struct body crossed the
/// `type_body_length` gate), and duplicating the API/importer/ledger setup in two
/// files is exactly how two suites start testing two different things while
/// claiming to test one.
enum MedFixtures {
    // MARK: - Fixtures

    static func makeAPI(token: String? = "bearer-abc") -> (APIClient, InMemoryKeychain) {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        if let token { try? kc.setString(token, forKey: KeychainKey.authToken) }
        try? kc.setString("user-ah", forKey: KeychainKey.userID)
        return (APIClient(environment: env, keychain: kc, sessionConfiguration: .mock()), kc)
    }

    static func isolatedDefaults() -> @Sendable () -> UserDefaults {
        let suite = "applemed.tests.\(UUID().uuidString)"
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
        return { UserDefaults(suiteName: suite)! }
    }

    /// **Phase 07 / plan 07-05.** The importer now refuses a sweep it cannot
    /// admit an account for, so the fixture supplies a real Phase-06 lease
    /// registry rather than a stub — which also makes every one of these tests a
    /// statement about the owner-bound path production actually runs. The dose
    /// ledger is returned alongside the mirror registry because per-dose
    /// progression, not a date watermark, is what the sweep now records.
    /// The three handles a sweep is asserted against. A named struct rather than
    /// a tuple: per-dose progression added a third member and three anonymous
    /// positions at ten call sites is exactly what `large_tuple` is for.
    struct Fixture {
        let importer: AppleHealthMedicationImporter
        let registry: AppleHealthMirrorRegistry
        let ledger: AppleHealthDoseLedger
    }

    static func makeImporter(
        api: APIClientProtocol,
        keychain: InMemoryKeychain,
        reader: FakeMedicationReader
    ) throws -> Fixture {
        let repo = try MedicationsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let defaultsProvider = isolatedDefaults()
        let registry = AppleHealthMirrorRegistry(userID: "user-ah", defaultsProvider: defaultsProvider)
        let sessions = AuthenticatedSessionLeaseRegistry()
        _ = sessions.activate(ownerID: Self.ownerID)
        let admission = HealthSyncImporterAdmission.keychainBound(keychain: keychain, registry: sessions)
        let storage = HealthSyncCursorStorage.userDefaults(defaultsProvider())
        let importer = AppleHealthMedicationImporter(
            reader: reader,
            repo: repo,
            keychain: keychain,
            registry: registry,
            admission: admission.provider(for: .appleMedication),
            ledgerStorage: storage
        )
        let ledger = try AppleHealthDoseLedger(
            storage: storage,
            key: #require(
                HealthSyncCursorKey(
                    ownerID: Self.ownerID,
                    source: .appleMedication,
                    typeIdentifier: AppleHealthDoseLedger.typeIdentifier
                )
            )
        )
        return Fixture(importer: importer, registry: registry, ledger: ledger)
    }

    /// The account every fixture signs in as — the same value `makeAPI` writes
    /// into the Keychain, because the admission reads it from there.
    static let ownerID = "user-ah"

    static func medEnvelope(id: String, name: String) -> String {
        #"{"data":{"id":"\#(id)","name":"\#(name)","dose":"1"},"error":null}"#
    }

    /// `GET /api/medications` — the list envelope. Since server v1.32.25 it
    /// echoes `externalSource`, which is what makes the mirror-vs-native
    /// distinction server-true instead of registry-guessed.
    static func medListEnvelope(_ rows: [(id: String, name: String, externalId: String?)]) -> String {
        let items = rows.map { row -> String in
            let provenance = row.externalId.map {
                #","externalSource":"APPLE_HEALTH","externalId":"\#($0)""#
            } ?? ""
            return #"{"id":"\#(row.id)","name":"\#(row.name)","dose":"1"\#(provenance)}"#
        }
        return #"{"data":[\#(items.joined(separator: ","))],"error":null}"#
    }

    static let emptyBulk =
        #"{"data":{"processed":0,"inserted":0,"updated":0,"duplicates":0,"skipped":[],"entries":[]},"error":null}"#

    /// A concept key of the shape the fixed reader mints (64-char SHA-256 hex).
    static let conceptA = AppleHealthConceptKey.derive(fromArchivedIdentifier: Data("concept-A".utf8))

    // MARK: - Response helpers

    static func ok(_ req: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    }

    static func status(_ code: Int, _ req: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

// MARK: - Test doubles

/// Canned ``AppleHealthMedicationReading`` — always available; ignores `since`
/// (returns the same doses so a second sweep exercises the replay path).
final class FakeMedicationReader: AppleHealthMedicationReading, @unchecked Sendable {
    private let medications: [AppleHealthMedicationRecord]
    private let doses: [AppleHealthDoseRecord]
    private let medReads = OSAllocatedUnfairLock(initialState: 0)

    var medicationReadCount: Int {
        medReads.withLock { $0 }
    }

    init(medications: [AppleHealthMedicationRecord], doses: [AppleHealthDoseRecord]) {
        self.medications = medications
        self.doses = doses
    }

    var isAvailable: Bool {
        true
    }

    func requestAuthorization() async throws {}

    func readMedications() async throws -> [AppleHealthMedicationRecord] {
        medReads.withLock { $0 += 1 }
        return medications
    }

    func readDoseEvents(since _: Date?) async throws -> [AppleHealthDoseRecord] {
        doses
    }
}

/// Records requests + decodes the mirror / bulk bodies for assertion.
final class MedicationRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(path: String, method: String, body: Data)] = []

    func record(_ req: URLRequest) {
        let body = req.httpBody ?? req.bodyStreamData() ?? Data()
        lock.lock()
        defer { lock.unlock() }
        requests.append((req.url?.path ?? "", req.httpMethod ?? "", body))
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    /// CU-10 — mirror **creates** only. The sweep now also GETs `/api/medications`
    /// to reconcile server truth, so counting the path alone would conflate the
    /// read with the write this suite is asserting about.
    var mirrorPostCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter { $0.path == "/api/medications" && $0.method == "POST" }.count
    }

    var bulkPostCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter { $0.path == "/api/medications/intake/bulk" }.count
    }

    /// The `externalId` of the most-recent mirror POST (drives the idempotent
    /// server-id echo in the handler).
    var lastMirrorExternalId: String? {
        lastMirrorBody?["externalId"] as? String
    }

    var lastMirrorBody: [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = requests.last(where: { $0.path == "/api/medications" && $0.method == "POST" })?.body else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    var lastBulkFirstEntry: [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = requests.last(where: { $0.path == "/api/medications/intake/bulk" })?.body,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = obj["entries"] as? [[String: Any]] else { return nil }
        return entries.first
    }
}

private extension URLRequest {
    /// Some `URLSession` configurations pipe the body through a stream so
    /// `httpBody` is nil. Drain the stream synchronously (test-only, small bodies).
    func bodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buf, maxLength: 4096)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data.isEmpty ? nil : data
    }
}

// swiftlint:enable force_unwrapping
