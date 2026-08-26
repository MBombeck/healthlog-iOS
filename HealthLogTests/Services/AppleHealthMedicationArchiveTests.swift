import Foundation
@testable import HealthLog
import os
import Testing

@Suite("Apple Health medication archive mirror", .serialized)
struct AppleHealthMedicationArchiveTests {
    @Test("An archived Apple Health medication is re-posted inactive")
    func archivedMedicationIsRepostedInactive() async throws {
        let environment = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local"),
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        try keychain.setString("bearer-abc", forKey: KeychainKey.authToken)
        // **Phase 07 / plan 07-05.** A bearer alone is no longer a sweep: the
        // importer admits an *account* before its first read, because the dose
        // ledger it writes is an owner partition. This fixture used to carry a
        // token and no user id, which now correctly refuses.
        try keychain.setString("archive-user", forKey: KeychainKey.userID)
        let api = APIClient(environment: environment, keychain: keychain, sessionConfiguration: .mock())
        let concept = AppleHealthConceptKey.derive(fromArchivedIdentifier: Data("archive-concept".utf8))
        let recordedBody = OSAllocatedUnfairLock(initialState: Data?.none)
        MockURLProtocol.handler = { request in
            if request.httpMethod == "GET" {
                let json = #"{"data":[{"id":"srv-existing","name":"Lisinopril","dose":"1","active":true,"externalSource":"APPLE_HEALTH","externalId":"\#(concept)"}],"error":null}"#
                return (Self.ok(request), Data(json.utf8))
            }
            if request.url?.path == "/api/medications" {
                recordedBody.withLock { $0 = request.httpBody ?? request.archiveBodyStreamData() }
                let json = #"{"data":{"id":"srv-existing","name":"Lisinopril","dose":"1","active":false},"error":null}"#
                return (Self.ok(request), Data(json.utf8))
            }
            let empty = #"{"data":{"processed":0,"inserted":0,"updated":0,"duplicates":0,"skipped":[],"entries":[]},"error":null}"#
            return (Self.ok(request), Data(empty.utf8))
        }
        let reader = ArchiveMedicationReader(
            medication: AppleHealthMedicationRecord(
                conceptIdentifier: concept,
                name: "Lisinopril",
                isArchived: true
            )
        )
        let repo = try MedicationsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let registry = AppleHealthMirrorRegistry(
            userID: "archive-user",
            defaultsProvider: Self.isolatedDefaults()
        )
        let sessions = AuthenticatedSessionLeaseRegistry()
        _ = sessions.activate(ownerID: "archive-user")
        let importer = AppleHealthMedicationImporter(
            reader: reader,
            repo: repo,
            keychain: keychain,
            registry: registry,
            admission: HealthSyncImporterAdmission
                .keychainBound(keychain: keychain, registry: sessions)
                .provider(for: .appleMedication),
            ledgerStorage: .userDefaults(Self.isolatedDefaults()())
        )

        let summary = await importer.sync()
        let body = try #require(recordedBody.withLock { $0 })
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(summary.medicationsMirrored == 1)
        #expect(json["active"] as? Bool == false)
        #expect(json["dose"] as? String == "2 tablet")
    }

    private static func ok(_ request: URLRequest) -> HTTPURLResponse {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else
        {
            preconditionFailure("Mock request must carry a valid URL")
        }
        return response
    }

    private static func isolatedDefaults() -> @Sendable () -> UserDefaults {
        let suite = "applemed.archive.\(UUID().uuidString)"
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        return { UserDefaults(suiteName: suite) ?? .standard }
    }
}

private extension URLRequest {
    func archiveBodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private struct ArchiveMedicationReader: AppleHealthMedicationReading {
    let medication: AppleHealthMedicationRecord
    let isAvailable = true

    func requestAuthorization() async throws {}

    func readMedications() async throws -> [AppleHealthMedicationRecord] {
        [medication]
    }

    func readDoseEvents(since _: Date?) async throws -> [AppleHealthDoseRecord] {
        [
            AppleHealthDoseRecord(
                eventUUID: "archived-dose",
                conceptIdentifier: medication.conceptIdentifier,
                logStatus: .taken,
                scheduledAt: Date(timeIntervalSince1970: 1_783_000_000),
                doseQuantity: 2,
                doseUnit: "tablet"
            )
        ]
    }
}
