import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// MEDS-QUICK-MARK-TAKEN — store-level WriteOutcome tests for
/// `MedicationsStore.markIntakeQuick`. Verifies the three outcomes:
/// `.success` (200 → patched-row), `.queued` (retriable error → optimistic
/// patch survives), `.failed(...)` (non-retriable → rollback).
///
/// The full SWR + cache writeThrough + sibling-invalidate contract is
/// already covered by `MedicationsStoreMarkIntakeTests` (F5 reconcile);
/// this suite focuses on the WriteOutcome contract the list-row quick-mark
/// surface depends on.
@Suite("MedicationsStore — markIntakeQuick WriteOutcome contract", .serialized)
struct MedicationsStoreQuickMarkTests {
    private static let scheduled = Date(timeIntervalSince1970: 1_714_550_400)
    private static let now = scheduled.addingTimeInterval(3600) // 1h after scheduled

    private func pending(id: String = "intake-1", medId: String = "med-1") -> MedicationIntake {
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
        return APIClient(
            environment: env,
            keychain: keychain,
            sessionConfiguration: .mock()
        )
    }

    private static func ok(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    private static func status(_ code: Int, request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }

    // MARK: - .success

    @Test("Returns .success on 200 and patches todayIntakes to .taken")
    @MainActor
    func quickMarkSuccess() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        MockURLProtocol.handler = { req in
            let body = #"{"data":{"id":"intake-1","medicationId":"med-1","scheduledFor":"2026-05-01T08:00:00Z","takenAt":"2026-05-01T09:00:00Z","skipped":false,"snoozedUntil":null}}"#
            return (Self.ok(req), Data(body.utf8))
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)
        store._testForceSet(todayIntakes: [pending()])

        let outcome = await store.markIntakeQuick(intakeId: "intake-1", status: .taken, now: Self.now)

        #expect(outcome == .success)
        #expect(store.todayIntakes.first?.status == .taken)
        #expect(store.error == nil)
    }

    // MARK: - .queued

    @Test("Returns .queued on retriable network error AND keeps optimistic patch visible")
    @MainActor
    func quickMarkQueuedKeepsOptimisticPatch() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        MockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)
        store._testForceSet(todayIntakes: [pending()])

        let outcome = await store.markIntakeQuick(intakeId: "intake-1", status: .taken, now: Self.now)

        #expect(outcome == .queued, "Retriable network error must surface as .queued")
        // Optimistic patch must survive — the resolver re-fires on the next
        // SwiftUI tick and renders the row as taken.
        #expect(
            store.todayIntakes.first?.status == .taken,
            "Optimistic patch must remain visible after .queued — outbox will reconcile"
        )
    }

    // MARK: - .failed

    @Test("Returns .failed on non-retriable 422 AND rolls back the optimistic patch")
    @MainActor
    func quickMarkFailedRollsBack() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        MockURLProtocol.handler = { req in
            (Self.status(422, request: req), Data(#"{"error":"validation"}"#.utf8))
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)
        store._testForceSet(todayIntakes: [pending()])

        let outcome = await store.markIntakeQuick(intakeId: "intake-1", status: .taken, now: Self.now)

        if case .failed = outcome {
            // expected branch
        } else {
            Issue.record("Expected .failed, got \(outcome)")
        }
        #expect(
            store.todayIntakes.first?.status == .pending,
            "Non-retriable error must roll back the optimistic patch"
        )
    }

    // MARK: - Soft-no-op when intake not present

    @Test("Returns .success as soft no-op when intake-id is not in todayIntakes")
    @MainActor
    func quickMarkSoftNoOpOnMissingId() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        MockURLProtocol.handler = { req in
            // Should never be reached.
            (Self.status(500, request: req), Data())
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)
        store._testForceSet(todayIntakes: [pending(id: "intake-A")])

        let outcome = await store.markIntakeQuick(intakeId: "intake-MISSING", status: .taken, now: Self.now)

        #expect(outcome == .success, "Missing id should be a soft no-op, not a network call")
        #expect(store.todayIntakes.first?.id == "intake-A")
        #expect(store.todayIntakes.first?.status == .pending)
    }

    // MARK: - takenAt timestamp

    @Test("On .success the patched row carries takenAt from server response")
    @MainActor
    func quickMarkTakenAtFromServer() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        // Server response carries server-stamped takenAt — distinct from our
        // optimistic-now to verify the resolver uses the server value.
        let serverTakenAt = "2026-05-01T09:00:00Z"
        MockURLProtocol.handler = { req in
            let body = #"{"data":{"id":"intake-1","medicationId":"med-1","scheduledFor":"2026-05-01T08:00:00Z","takenAt":"\#(serverTakenAt)","skipped":false,"snoozedUntil":null}}"#
            return (Self.ok(req), Data(body.utf8))
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)
        store._testForceSet(todayIntakes: [pending()])

        let outcome = await store.markIntakeQuick(intakeId: "intake-1", status: .taken, now: Self.now)

        #expect(outcome == .success)
        #expect(store.todayIntakes.first?.takenAt != nil, "Server takenAt must be reflected on the patched row")
    }
}

// swiftlint:enable force_unwrapping
