import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping force_try

/// WC2 regression guard — **write-durability at the STORE layer on
/// token-expiry-during-write.**
///
/// WC fixed the repository enqueue gate (`isRetriable` → `shouldPersistToOutbox`)
/// so a transient-refresh 401 mid-write is durably enqueued instead of dropped.
/// But the in-app *store* layer still rolled its OPTIMISTIC-UI decision back on
/// `isRetriable` — so on a `.unauthorized` it removed the optimistic row even
/// though the repo had just durably queued the write. Same "I logged it, now
/// it's gone" felt bug, one layer up.
///
/// This proves a real `MeasurementsStore` over a real `MeasurementsRepository`
/// + real `APIClient` (stub `URLSession`, NEVER a mock server — PROJECT_GUIDE.md Outbox
/// rule) KEEPS its optimistic row on a transient-refresh 401 AND the repo
/// enqueued exactly one Outbox row — while still rolling back + NOT enqueuing on
/// a permanent rejection (422).
@MainActor
@Suite("Store durability on .unauthorized (WC2)", .serialized)
struct StoreUnauthorizedDurabilityTests {
    // MARK: - Helpers

    /// A real `APIClient` over a stubbed `URLSession`, wired with a
    /// `refreshHandler` that always reports `.transient` — the refresh itself
    /// can't complete, which is exactly the condition under which `execute`
    /// throws `.unauthorized` WITHOUT logging the user out.
    private func makeAPI(refresh: @escaping @Sendable () async -> RefreshOutcome) -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(
            environment: env,
            keychain: InMemoryKeychain(),
            sessionConfiguration: .mock(),
            refreshHandler: refresh
        )
    }

    private func makeStore(outbox: OutboxQueue, refresh: @escaping @Sendable () async -> RefreshOutcome) -> MeasurementsStore {
        let api = makeAPI(refresh: refresh)
        let repo = MeasurementsRepository(api: api, outbox: outbox)
        return MeasurementsStore(repo: repo)
    }

    // MARK: - (1) 401 + transient refresh → optimistic row KEPT, write enqueued

    @Test("Transient-refresh 401 on capture KEEPS the optimistic row + enqueues the write")
    func unauthorizedOnCaptureKeepsOptimisticRow() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let store = makeStore(outbox: outbox, refresh: { .transient })
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, nil)
        }

        let ok = await store.capture(kind: .weight, value: .scalar(81.0), note: nil)

        #expect(ok == false, "a transient-refresh 401 is not a server-confirmed success")
        // The felt-quality assertion: the optimistic row must still be visible.
        #expect(store.recent.count == 1, "the optimistic row must survive a durably-queued 401 (not vanish)")
        #expect(store.recent.first?.kind == .weight)

        let snap = await outbox.snapshot
        #expect(snap.count == 1, "the write must be durably enqueued (the row the UI still shows)")
        #expect(snap.first?.kind == .createMeasurement)
        #expect(!(snap.first?.idempotencyKey.isEmpty ?? true))
    }

    // MARK: - (2) negative: a 422 → optimistic row rolled back, NOT enqueued

    @Test("A 422 on capture rolls the optimistic row back and does NOT enqueue")
    func unprocessableEntityRollsBack() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let store = makeStore(outbox: outbox, refresh: { .transient })
        let body = #"{"error":{"code":"validation.failed","message":"Invalid value"}}"#
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }

        let ok = await store.capture(kind: .weight, value: .scalar(81.0), note: nil)

        #expect(ok == false)
        #expect(store.recent.isEmpty, "a permanent 422 must roll the optimistic row back")
        #expect(await (outbox.snapshot).isEmpty, "a 422 is permanent — it must NOT be enqueued")
    }
}

// swiftlint:enable force_unwrapping force_try
