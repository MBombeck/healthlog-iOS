import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping force_try

/// A360-5 data-integrity fixes — store/model-level regression locks.
///
/// - **H-1** QuickCapture optimistic insert must survive a concurrent `load()`
///   that replaces `recent` during the in-flight `repo.create` (the saved row
///   must never vanish from the cache).
@MainActor
@Suite("MeasurementsStore — A360-5 integrity fixes", .serialized, .mockURLSession)
struct MeasurementsStoreIntegrityFixTests {
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

    private nonisolated static func response(_ code: Int, request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    // MARK: - Optimistic row survives a concurrent load

    /// While `captureReturningOutcome` is suspended on its create POST, a
    /// concurrent `load()` replaces the whole `recent` array (dropping the temp
    /// `local-…` row). Pre-fix the `firstIndex(local.id)` reconcile returned nil
    /// and the server-saved row was silently dropped. Post-fix the saved row is
    /// re-inserted, so the capture is never lost from the cache.
    @Test("H-1: captured row survives a concurrent load that clobbers `recent`")
    func captureSurvivesConcurrentLoad() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MeasurementsRepository(api: api, outbox: outbox)
        // No HealthKit writer: the repo hits the (mocked) wire so the create
        // round-trips, and there is no mirror write to wait for.
        let store = MeasurementsStore(
            repo: repo,
            undoCoordinator: UndoCoordinator()
        )

        // Delay the create POST on its (background) URLProtocol thread so the
        // mid-flight clobber lands while the create is still suspended. A short
        // sleep on the protocol thread is safe — it never blocks the main actor.
        MockURLProtocol.install { req in
            if req.httpMethod == "POST" {
                Thread.sleep(forTimeInterval: 0.4)
                let body = """
                {"data":{"id":"server-new","type":"WEIGHT","value":80,\
                "measuredAt":"2023-11-14T22:13:20Z"}}
                """
                return (Self.response(200, request: req), Data(body.utf8))
            }
            return (Self.response(200, request: req), Data(#"{"data":{"points":[]}}"#.utf8))
        }

        // Start the capture; it inserts the temp `local-…` row synchronously
        // then suspends on the (delayed) create POST.
        async let outcome = store.captureReturningOutcome(
            kind: .weight, value: .scalar(80), note: nil
        )

        // Let the capture reach its `await repo.create`, then deterministically
        // clobber `recent` on the main actor — exactly what a concurrent
        // `load()` / SWR `.fresh` re-emit would do: replace the whole array,
        // dropping the in-flight temp row. The create is still suspended on its
        // 0.4 s POST, so this models the lost-update window precisely.
        await Task.yield()
        store.recent = [Measurement(
            id: "other-1",
            kind: .weight,
            recordedAt: Date(timeIntervalSince1970: 1_699_900_000),
            value: .scalar(70)
        )]

        let result = await outcome
        #expect(result == .success)
        #expect(
            store.recent.contains { $0.id == "server-new" },
            "H-1: server-saved capture must survive a concurrent load that clobbered `recent`"
        )
        // The clobbering row must also remain — the fix INSERTS, never replaces.
        #expect(store.recent.contains { $0.id == "other-1" })
    }
}

// swiftlint:enable force_unwrapping force_try
