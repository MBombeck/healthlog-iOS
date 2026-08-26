import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// H3 — an offline (durably-enqueued) clinical-record create/update must surface
/// as SUCCESS, not failure. Surfacing it as a failure invites the user's natural
/// retry, which mints a SECOND idempotency key and creates a DUPLICATE clinical
/// record on reconnect. These drive the REAL `APIClient` against a stub
/// `URLProtocol` (per the no-mock-server doctrine): a retriable 503 routes the
/// write into the encrypted outbox, and the store reports success.
@MainActor
@Suite("Records store offline create/update (H3)", .serialized)
struct RecordsStoreOfflineTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.25.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
    }

    /// 503 on every request → retriable → the repo enqueues + re-throws.
    private func install503() {
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
    }

    // MARK: - Allergies

    @Test("offline allergy create → SUCCESS (optimistic row), enqueued exactly once, no failure")
    func allergyOfflineCreateIsSuccess() async throws {
        install503()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = AllergiesRepository(api: makeAPI(), outbox: outbox)
        let store = AllergiesStore(repository: repo)

        let created = await store.create(AllergyCreate(substance: "Penicillin"))

        // Surfaced as success — the editor dismisses, the user does NOT retry.
        #expect(created != nil)
        #expect(store.lastError == nil)
        #expect(store.records.contains { $0.substance == "Penicillin" })
        // Durably enqueued under ONE idempotency key (no duplicate vector).
        let ops = await outbox.snapshot
        #expect(ops.filter { $0.kind == .createAllergy }.count == 1)
    }

    @Test("offline allergy update → SUCCESS, enqueued exactly once, no failure")
    func allergyOfflineUpdateIsSuccess() async throws {
        install503()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = AllergiesRepository(api: makeAPI(), outbox: outbox)
        let store = AllergiesStore(repository: repo)

        let ok = await store.update(id: "allergy-1", AllergyPatch(status: .set(.resolved)))

        #expect(ok)
        #expect(store.lastError == nil)
        let ops = await outbox.snapshot
        #expect(ops.filter { $0.kind == .updateAllergy }.count == 1)
    }

    // MARK: - Family history

    @Test("offline family-history create → SUCCESS (optimistic row), enqueued once")
    func familyHistoryOfflineCreateIsSuccess() async throws {
        install503()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = FamilyHistoryRepository(api: makeAPI(), outbox: outbox)
        let store = FamilyHistoryStore(repository: repo)

        let created = await store.create(FamilyHistoryCreate(relationship: .mother, condition: "Diabetes"))

        #expect(created != nil)
        #expect(store.lastError == nil)
        #expect(store.records.contains { $0.condition == "Diabetes" })
        let ops = await outbox.snapshot
        #expect(ops.filter { $0.kind == .createFamilyHistory }.count == 1)
    }

    @Test("offline family-history update → SUCCESS, enqueued once")
    func familyHistoryOfflineUpdateIsSuccess() async throws {
        install503()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = FamilyHistoryRepository(api: makeAPI(), outbox: outbox)
        let store = FamilyHistoryStore(repository: repo)

        let ok = await store.update(id: "fh-1", FamilyHistoryPatch(condition: .set("Hypertension")))

        #expect(ok)
        #expect(store.lastError == nil)
        let ops = await outbox.snapshot
        #expect(ops.filter { $0.kind == .updateFamilyHistory }.count == 1)
    }
}
