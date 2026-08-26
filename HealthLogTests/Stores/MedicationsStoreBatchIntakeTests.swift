import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **H4 (server v1.16.11) — "take all due doses" batch confirm.**
///
/// `MedicationsStore.markAllDueQuick` loops each due dose through the existing
/// single-intake path. These tests pin the success/failure tally + that every
/// due dose is patched to taken (no client dedup — each ride is independent).
@Suite("MedicationsStore — markAllDueQuick batch confirm", .serialized)
struct MedicationsStoreBatchIntakeTests {
    private static let scheduled = Date(timeIntervalSince1970: 1_714_550_400)
    private static let now = scheduled.addingTimeInterval(3600)

    private func pending(id: String, medId: String) -> MedicationIntake {
        MedicationIntake(
            id: id,
            medicationId: medId,
            scheduledAt: Self.scheduled,
            takenAt: nil,
            status: .pending
        )
    }

    private func makeAPI() -> APIClient {
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    private static func ok(_ request: URLRequest, id: String, medId: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        let body = """
        {"data":{"id":"\(id)","medicationId":"\(medId)","scheduledFor":"2026-05-01T08:00:00Z",\
        "takenAt":"2026-05-01T09:00:00Z","skipped":false,"snoozedUntil":null}}
        """
        return (response, Data(body.utf8))
    }

    @Test("All due doses confirmed → confirmed == total, allConfirmed true")
    @MainActor
    func allConfirmed() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        MockURLProtocol.handler = { req in
            // Echo a generic taken row — the store only needs a 200 + valid body.
            Self.ok(req, id: "intake-1", medId: "med-1")
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)
        store._testForceSet(todayIntakes: [
            pending(id: "intake-1", medId: "med-1"),
            pending(id: "intake-2", medId: "med-2")
        ])

        let outcome = await store.markAllDueQuick(
            intakeIds: ["intake-1", "intake-2"],
            now: Self.now
        )

        #expect(outcome.confirmed == 2)
        #expect(outcome.failed == 0)
        #expect(outcome.total == 2)
        #expect(outcome.allConfirmed)
        #expect(store.todayIntakes.allSatisfy { $0.status == .taken })
    }

    @Test("Retriable network error → counted as confirmed (queued for replay)")
    @MainActor
    func queuedCountsAsConfirmed() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)
        store._testForceSet(todayIntakes: [
            pending(id: "intake-1", medId: "med-1"),
            pending(id: "intake-2", medId: "med-2")
        ])

        let outcome = await store.markAllDueQuick(
            intakeIds: ["intake-1", "intake-2"],
            now: Self.now
        )

        #expect(outcome.confirmed == 2, "queued doses count as confirmed — outbox replays")
        #expect(outcome.failed == 0)
        // Optimistic patch survives.
        #expect(store.todayIntakes.allSatisfy { $0.status == .taken })
    }

    @Test("Non-retriable failure → counted in failed tally, not allConfirmed")
    @MainActor
    func hardFailureCounted() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        MockURLProtocol.handler = { req in
            let response = HTTPURLResponse(
                url: req.url!,
                statusCode: 422,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, Data(#"{"error":"validation"}"#.utf8))
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)
        store._testForceSet(todayIntakes: [pending(id: "intake-1", medId: "med-1")])

        let outcome = await store.markAllDueQuick(intakeIds: ["intake-1"], now: Self.now)

        #expect(outcome.confirmed == 0)
        #expect(outcome.failed == 1)
        #expect(!outcome.allConfirmed)
    }
}
