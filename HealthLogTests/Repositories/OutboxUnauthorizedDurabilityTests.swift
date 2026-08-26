import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping force_try

/// WC / D1 regression guard — **write-durability on token-expiry-during-write.**
///
/// The bug: a 401 mid-write triggers a single-flight refresh; when that refresh
/// fails *transiently* (`RefreshOutcome.transient`) `APIClient.execute` throws
/// `HLError.unauthorized`. `.unauthorized` is `isRetriable == false`, and every
/// write-path catch gated its Outbox enqueue on `isRetriable` — so the optimistic
/// write was **silently dropped** (lost measurement / mood / med-intake; the
/// watch-mood-vanishes bug the operator hit on device).
///
/// The fix: the enqueue gate moved from `isRetriable` to `shouldPersistToOutbox`
/// (which adds `.unauthorized`). These tests prove a real `APIClient` (stub
/// `URLSession`, never a mock server — PROJECT_GUIDE.md Outbox rule) + a real
/// `MeasurementsRepository` now **enqueues** on a transient-refresh 401 instead
/// of dropping, while still **NOT** enqueuing on ambiguous/permanent failures
/// (`.decoding`, a 422).
@Suite("Outbox durability on .unauthorized (WC / D1)", .serialized)
struct OutboxUnauthorizedDurabilityTests {
    // MARK: - Helpers

    /// A real `APIClient` over a stubbed `URLSession`, wired with a
    /// `refreshHandler` that always reports `.transient` — i.e. the refresh
    /// itself can't complete (network hiccup), which is exactly the condition
    /// under which `execute` throws `.unauthorized` WITHOUT logging the user out.
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

    /// Inline-builds the domain `Measurement` at the call site (expression
    /// position) so it resolves to `HealthLogCore.Measurement` via the
    /// `repo.create(_:)` parameter type, not `Foundation.Measurement<Unit>`.
    private func createSample(_ repo: MeasurementsRepository) async throws {
        _ = try await repo.create(
            .init(
                id: "local-\(UUID().uuidString)",
                kind: .weight,
                recordedAt: Date(timeIntervalSince1970: 1_714_550_400),
                value: .scalar(81.0)
            )
        )
    }

    // MARK: - (1) 401 + transient refresh → enqueued, NOT dropped

    @Test("Transient-refresh 401 on create enqueues the write (does NOT silently drop)")
    func unauthorizedOnCreateEnqueues() async throws {
        let api = makeAPI(refresh: { .transient })
        let outbox = try OutboxQueue(inMemory: true)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, nil)
        }
        let repo = MeasurementsRepository(api: api, outbox: outbox)

        var thrown: HLError?
        do {
            try await createSample(repo)
            Issue.record("create must rethrow on a transient-refresh 401")
        } catch let err as HLError {
            thrown = err
        }
        #expect(thrown == .unauthorized, "the transient-refresh 401 must surface as HLError.unauthorized")

        let snap = await outbox.snapshot
        #expect(snap.count == 1, ".unauthorized write must be persisted to the Outbox, not dropped")
        #expect(snap.first?.kind == .createMeasurement)
        // Idempotency key is persisted so the eventual post-re-login replay
        // cannot double-write (server dedups on the same key).
        #expect(!(snap.first?.idempotencyKey.isEmpty ?? true))
    }

    // MARK: - (2) negative: a 422 is permanent → NOT enqueued

    @Test("A 422 on create does NOT enqueue (permanent rejection stays dropped)")
    func unprocessableEntityDoesNotEnqueue() async throws {
        let api = makeAPI(refresh: { .transient })
        let outbox = try OutboxQueue(inMemory: true)
        let body = #"{"error":{"code":"validation.failed","message":"Invalid value"}}"#
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }
        let repo = MeasurementsRepository(api: api, outbox: outbox)

        await #expect(throws: HLError.self) {
            try await createSample(repo)
        }
        #expect(await (outbox.snapshot).isEmpty, "a 422 is permanent — replaying it forever would be worse")
    }

    // MARK: - (3) negative: a decoding failure → NOT enqueued

    @Test("A decoding failure on create does NOT enqueue (ambiguous outcome stays dropped)")
    func decodingFailureDoesNotEnqueue() async throws {
        let api = makeAPI(refresh: { .transient })
        let outbox = try OutboxQueue(inMemory: true)
        // 200 OK but a body the response decoder cannot turn into a Measurement.
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("not a measurement envelope".utf8)
            )
        }
        let repo = MeasurementsRepository(api: api, outbox: outbox)

        await #expect(throws: HLError.self) {
            try await createSample(repo)
        }
        #expect(
            await (outbox.snapshot).isEmpty,
            "a decoding failure is ambiguous (write may have landed) — enqueuing risks an unbounded replay"
        )
    }
}

// swiftlint:enable force_unwrapping force_try
