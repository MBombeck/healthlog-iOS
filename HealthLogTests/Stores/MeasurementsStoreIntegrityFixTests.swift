import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping force_try

/// A360-5 data-integrity fixes — store/model-level regression locks.
///
/// - **H-1** QuickCapture optimistic insert must survive a concurrent `load()`
///   that replaces `recent` during the in-flight `repo.create` (the saved row
///   must never vanish from the cache).
/// - **H-2** A blood-pressure edit must preserve the diastolic peer id on the
///   merged optimistic row even when the write path returns a row WITHOUT it,
///   so the pair stays linked for the next edit.
@MainActor
@Suite("MeasurementsStore — A360-5 integrity fixes", .serialized)
struct MeasurementsStoreIntegrityFixTests {
    /// HK read stub — no samples (isolates the mirror; HK is unavailable in the
    /// unit host anyway).
    private struct EmptyHK: StandaloneHealthKitReadServing {
        func standaloneRecentSamples(kind _: MetricKind, days _: Int, limit _: Int) async -> [SeriesPoint] {
            []
        }

        func standaloneDailySeries(kind _: MetricKind, days _: Int) async -> [SeriesPoint] {
            []
        }
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

    private nonisolated static func response(_ code: Int, request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    // MARK: - H-1 — optimistic row survives a concurrent load

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
        // `isStandalone: { true }` only suppresses the store's HK mirror write;
        // the repo still hits the (mocked) wire so the create round-trips.
        let store = MeasurementsStore(
            repo: repo,
            undoCoordinator: UndoCoordinator(),
            isStandalone: { true }
        )

        // Delay the create POST on its (background) URLProtocol thread so the
        // mid-flight clobber lands while the create is still suspended. A short
        // sleep on the protocol thread is safe — it never blocks the main actor.
        MockURLProtocol.handler = { req in
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

    // MARK: - H-2 — BP edit preserves the diastolic peer id

    /// Editing a blood-pressure pair through a write path that returns a row
    /// WITHOUT the diastolic peer id (the standalone mirror collapses sys+dia
    /// onto one row) must keep the pair linked on the merged optimistic row —
    /// otherwise the next edit drops to the systolic-only PATCH path and the
    /// diastolic row drifts. Post-fix the original `dia-1` is carried forward.
    @Test("H-2: BP edit preserves the diastolic peer id when the write omits it")
    func bpEditPreservesDiastolicId() async throws {
        let local = try LocalRepository(store: LocalStore(modelContainer: LocalStore.makeInMemory()))
        let gate = StandaloneGate(local: local, healthKit: EmptyHK(), isStandalone: { true })
        let api = makeAPI()
        let repo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true), standalone: gate)
        let store = MeasurementsStore(repo: repo, undoCoordinator: UndoCoordinator(), isStandalone: { true })

        // Create a BP row through the mirror so a real externalId exists.
        let created = try await repo.create(
            Measurement(
                id: "bp-temp",
                kind: .bloodPressure,
                recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
                value: .bloodPressure(systolic: 128, diastolic: 82)
            )
        )
        // Seed the store's cache with the row, manually carrying a diastolic
        // peer id the next edit must preserve.
        let seeded = Measurement(
            id: created.id,
            kind: .bloodPressure,
            recordedAt: created.recordedAt,
            value: .bloodPressure(systolic: 128, diastolic: 82),
            source: .manual,
            bloodPressureDiastolicId: "dia-1"
        )
        store.recent = [seeded]

        let ok = await store.update(
            seeded,
            value: .bloodPressure(systolic: 130, diastolic: 84),
            recordedAt: seeded.recordedAt,
            note: nil
        )
        #expect(ok)
        let merged = try #require(store.recent.first { $0.kind == .bloodPressure })
        #expect(
            merged.bloodPressureDiastolicId == "dia-1",
            "H-2: diastolic peer id must survive the edit merge"
        )
    }
}

// swiftlint:enable force_unwrapping force_try
