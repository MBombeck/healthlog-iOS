import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Locks the wire contract + SWR ladder for `GET /api/workouts`
/// (server v1.4.32) and `GET /api/workouts/{id}`.
///
/// Covers:
/// - list decoding (workouts + meta envelope)
/// - SWR cache fresh → no network second call
/// - SWR cache stale → network fires; stale returned on error
/// - per-id detail path decode
/// - empty list decodes cleanly
@Suite("WorkoutsRepository — wire contract + SWR ladder", .serialized)
struct WorkoutsRepositoryTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        return APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
    }

    /// Repo against the real `APIClient` (stub session) + an in-memory
    /// outbox — the read paths under test here never touch the outbox.
    private func makeRepo(
        cacheTTL: TimeInterval = 60,
        clock: @escaping @Sendable () -> Date = Date.init
    ) throws -> WorkoutsRepository {
        try WorkoutsRepository(
            api: makeAPI(),
            outbox: OutboxQueue(inMemory: true),
            cacheTTL: cacheTTL,
            clock: clock
        )
    }

    @Test("list — decodes workouts + meta envelope")
    func listDecodesEnvelope() async throws {
        let repo = try makeRepo()
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{
              "workouts":[{
                "id":"w1","sportType":"running",
                "startedAt":"2026-05-15T07:00:00Z","endedAt":"2026-05-15T07:30:00Z",
                "durationSec":1800,"distanceM":5000,"activeEnergyKcal":320,
                "avgHr":155,"maxHr":172,"source":"APPLE_HEALTH","externalId":"hk:abc"
              }],
              "meta":{"total":1,"limit":50,"offset":0,"droppedDuplicates":2}
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let response = try await repo.list()
        #expect(response.workouts.count == 1)
        #expect(response.workouts[0].id == "w1")
        #expect(response.workouts[0].sportType == "running")
        #expect(response.workouts[0].durationSec == 1800)
        #expect(response.workouts[0].source == "APPLE_HEALTH")
        #expect(response.meta.droppedDuplicates == 2)
    }

    @Test("list — WHOOP-sourced row (server WHOOP ingest, v1.11.0) decodes and is never dropped")
    func listDecodesWhoopRow() async throws {
        // W-WORKOUT-E2E (2026-06-11): the server upserts WHOOP workouts as
        // `source = "WHOOP"` with a WHOOP sport label (`sport_name` or the
        // generic `whoop_sport_<id>` token) — NOT an HK activity identifier.
        // The list DTO must carry such rows verbatim; v0.14.1 found the
        // measurement-side decoder silently dropping WHOOP rows, this pins
        // the workout list against the same failure mode.
        let repo = try makeRepo()
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{
              "workouts":[{
                "id":"w-whoop","sportType":"whoop_sport_1",
                "startedAt":"2026-06-10T16:00:00Z","endedAt":"2026-06-10T17:30:00Z",
                "durationSec":5400,"distanceM":24000,"activeEnergyKcal":810,
                "avgHr":141,"maxHr":168,"source":"WHOOP","externalId":"whoop:abc-123"
              },{
                "id":"w-ah","sportType":"cycling",
                "startedAt":"2026-06-10T16:01:00Z","endedAt":"2026-06-10T17:29:00Z",
                "durationSec":5280,"distanceM":23900,"activeEnergyKcal":790,
                "avgHr":140,"maxHr":166,"source":"APPLE_HEALTH","externalId":"hk:def"
              }],
              "meta":{"total":2,"limit":50,"offset":0,"droppedDuplicates":0}
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let response = try await repo.list()
        #expect(response.workouts.count == 2, "a WHOOP-sourced row must never be dropped client-side")
        #expect(response.workouts[0].source == "WHOOP")
        #expect(response.workouts[0].sportType == "whoop_sport_1")
        #expect(response.workouts[0].externalId == "whoop:abc-123")
    }

    @Test("list — empty payload decodes cleanly")
    func listEmpty() async throws {
        let repo = try makeRepo()
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{"workouts":[],"meta":{"total":0,"limit":50,"offset":0,"droppedDuplicates":0}},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let response = try await repo.list()
        #expect(response.workouts.isEmpty)
        #expect(response.meta.total == 0)
    }

    @Test("list — SWR cache returns warm read without re-firing network")
    func listSWRCacheHit() async throws {
        let repo = try makeRepo()
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.handler = { req in
            // CU-07: the handler is process-global — only OUR route counts.
            if req.targets("/api/workouts") { calls += 1 }
            let body = Data(#"""
            {"data":{"workouts":[],"meta":{"total":0,"limit":50,"offset":0,"droppedDuplicates":0}},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        _ = try await repo.list()
        _ = try await repo.list() // warm
        #expect(calls == 1, "second list() must hit the in-memory cache")
    }

    @Test("list — stale cache returned on network failure")
    func listSWRStaleOnError() async throws {
        // Use a clock the test controls so the TTL elapses on demand.
        let clockBox = ClockBox(now: Date(timeIntervalSinceReferenceDate: 0))
        let repo = try makeRepo(
            cacheTTL: 60,
            clock: { clockBox.now }
        )
        nonisolated(unsafe) var phase = 0
        MockURLProtocol.handler = { req in
            // CU-07: only OUR route advances the phase machine.
            if req.targets("/api/workouts") { phase += 1 }
            if phase == 1 {
                let body = Data(#"""
                {"data":{
                  "workouts":[{
                    "id":"w1","sportType":"running",
                    "startedAt":"2026-05-15T07:00:00Z","endedAt":null,
                    "durationSec":1800,"distanceM":5000,"activeEnergyKcal":320,
                    "avgHr":155,"maxHr":172,"source":"APPLE_HEALTH","externalId":null
                  }],
                  "meta":{"total":1,"limit":50,"offset":0,"droppedDuplicates":0}
                },"error":null}
                """#.utf8)
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        // First warm fetch.
        let first = try await repo.list()
        #expect(first.workouts.count == 1)
        // Advance past TTL so the next read is forced to the wire — and the wire 500s.
        clockBox.now = clockBox.now.addingTimeInterval(120)
        let stale = try await repo.list()
        #expect(stale.workouts.count == 1, "stale slot must be returned on network failure")
    }

    @Test("workout(id:) — decodes single entry")
    func workoutDetail() async throws {
        let repo = try makeRepo()
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{
              "id":"w2","sportType":"cycling",
              "startedAt":"2026-05-12T08:00:00Z","endedAt":"2026-05-12T09:30:00Z",
              "durationSec":5400,"distanceM":35000,"activeEnergyKcal":900,
              "avgHr":140,"maxHr":172,"source":"APPLE_HEALTH","externalId":null
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let entry = try await repo.workout(id: "w2")
        #expect(entry.id == "w2")
        #expect(entry.sportType == "cycling")
        #expect(entry.distanceM == 35000)
    }

    @Test("workout(id:) — decodes rich HR detail envelope")
    func workoutDetailRichHR() async throws {
        // v0.5.4-SP5 — pin the wire shape of the detail endpoint:
        // minHr / stepCount / elevationM / canonicalId all flow through
        // to the DTO so the detail screen can render the HR chart +
        // stats grid.
        let repo = try makeRepo()
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{
              "id":"w-rich","sportType":"running",
              "startedAt":"2026-05-12T08:00:00Z","endedAt":"2026-05-12T08:30:00Z",
              "durationSec":1800,"distanceM":5000,"activeEnergyKcal":320,
              "avgHr":145,"maxHr":170,"minHr":98,
              "stepCount":5800,"elevationM":12.5,"pauseDurationSec":0,
              "source":"APPLE_HEALTH","externalId":"hk:abc",
              "canonicalId":"w-rich"
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let entry = try await repo.workout(id: "w-rich")
        #expect(entry.id == "w-rich")
        #expect(entry.minHr == 98)
        #expect(entry.stepCount == 5800)
        #expect(entry.elevationM == 12.5)
        #expect(entry.canonicalId == "w-rich")
    }

    @Test("workout(id:) — handles missing rich fields gracefully")
    func workoutDetailWithoutRichFields() async throws {
        // Withings + manual entries ship no rich extras; minHr /
        // stepCount / elevation are absent. The DTO must decode
        // without errors and surface nil for every optional.
        let repo = try makeRepo()
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{
              "id":"w-min","sportType":"yoga",
              "startedAt":"2026-05-12T08:00:00Z","endedAt":"2026-05-12T08:30:00Z",
              "durationSec":1800,"distanceM":null,"activeEnergyKcal":120,
              "avgHr":null,"maxHr":null,
              "source":"MANUAL","externalId":null,
              "canonicalId":"w-min","route":null
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let entry = try await repo.workout(id: "w-min")
        #expect(entry.minHr == nil)
        #expect(entry.stepCount == nil)
        #expect(entry.elevationM == nil)
        #expect(entry.canonicalId == "w-min")
        #expect(entry.route == nil)
    }

    @Test("workout(id:) — decodes GeoJSON LineString route geometry")
    func workoutDetailWithRoute() async throws {
        // v0.5.4-SP5 — Apple-Health-sourced workouts ship a
        // `WorkoutRoute` row with the GPS GeoJSON LineString +
        // per-coordinate timestamps. The DTO must decode the geometry
        // verbatim so the map layer can render a polyline.
        let repo = try makeRepo()
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{
              "id":"w-gps","sportType":"running",
              "startedAt":"2026-05-12T08:00:00Z","endedAt":"2026-05-12T08:30:00Z",
              "durationSec":1800,"distanceM":5000,"activeEnergyKcal":320,
              "avgHr":145,"maxHr":170,
              "source":"APPLE_HEALTH","externalId":"hk:gps",
              "canonicalId":"w-gps",
              "route":{
                "geometry":{"type":"LineString","coordinates":[[11.0,49.0],[11.01,49.01,123.4]]},
                "sampleTimestamps":["2026-05-12T08:00:00Z","2026-05-12T08:01:00Z"]
              }
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let entry = try await repo.workout(id: "w-gps")
        let route = try #require(entry.route)
        #expect(route.geometry.type == "LineString")
        #expect(route.geometry.coordinates.count == 2)
        #expect(route.geometry.coordinates[0][0] == 11.0)
        #expect(route.geometry.coordinates[0][1] == 49.0)
        // Third element (altitude) survives the decode for the
        // second point.
        #expect(route.geometry.coordinates[1].count == 3)
        #expect(route.sampleTimestamps?.count == 2)
    }

    @Test("invalidateCache — wipes list + detail slots so next reads hit the wire")
    func invalidateCacheWipesSlots() async throws {
        // V0.5.2 R2 / H1: logout must reach the per-repo actor cache so
        // the next user never sees the previous user's workouts.
        let repo = try makeRepo()
        nonisolated(unsafe) var calls = 0
        let listBody = Data(#"""
        {"data":{"workouts":[],"meta":{"total":0,"limit":50,"offset":0,"droppedDuplicates":0}},"error":null}
        """#.utf8)
        let detailBody = Data(#"""
        {"data":{
          "id":"w1","sportType":"running",
          "startedAt":"2026-05-15T07:00:00Z","endedAt":null,
          "durationSec":1800,"distanceM":5000,"activeEnergyKcal":320,
          "avgHr":155,"maxHr":172,"source":"APPLE_HEALTH","externalId":null
        },"error":null}
        """#.utf8)
        MockURLProtocol.handler = { req in
            // CU-07: count only the two routes this test drives — the list and
            // the `w1` detail — never a parallel suite's request.
            if req.targets("/api/workouts") || req.targets("/api/workouts/w1") { calls += 1 }
            let body = req.targets("/api/workouts/w1") ? detailBody : listBody
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        _ = try await repo.list()
        _ = try await repo.workout(id: "w1") // populate detail slot
        #expect(calls == 2)
        // Warm reads — same call count.
        _ = try await repo.list()
        _ = try await repo.workout(id: "w1")
        #expect(calls == 2, "second pair must hit cache")
        // Invalidate — both slots must drop.
        await repo.invalidateCache()
        _ = try await repo.list()
        _ = try await repo.workout(id: "w1")
        #expect(calls == 4, "post-invalidate reads must round-trip again")
    }

    @MainActor
    @Test("WorkoutsStore — load mirrors repo into observable state")
    func storeLoadMirrors() async throws {
        let repo = try makeRepo()
        let store = WorkoutsStore(repo: repo)
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{
              "workouts":[{
                "id":"w3","sportType":"running",
                "startedAt":"2026-05-10T07:00:00Z","endedAt":null,
                "durationSec":1800,"distanceM":4000,"activeEnergyKcal":260,
                "avgHr":140,"maxHr":160,"source":"WITHINGS","externalId":null
              }],
              "meta":{"total":1,"limit":50,"offset":0,"droppedDuplicates":0}
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.load()
        #expect(store.workouts.count == 1)
        #expect(store.workouts[0].id == "w3")
        #expect(store.meta?.total == 1)
        #expect(store.error == nil)
    }

    @Test("retriable transport plus failed outbox enqueue surfaces notPersisted")
    func uploadFailureWithoutDurableQueueIsHonest() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { nil })
        await outbox.useCipher(OutboxPayloadCipher(keychain: WorkoutEnqueueFailingKeychain()))
        let repo = WorkoutsRepository(api: makeAPI(), outbox: outbox)
        MockURLProtocol.handler = { req in
            guard let url = req.url, let response = HTTPURLResponse(
                url: url,
                statusCode: 408,
                httpVersion: nil,
                headerFields: nil
            ) else {
                throw URLError(.badURL)
            }
            return (response, Data())
        }
        let workout = WorkoutIngestDTO(
            sportType: "running",
            startedAt: Date(timeIntervalSince1970: 1_750_000_000),
            endedAt: Date(timeIntervalSince1970: 1_750_001_800),
            externalId: "hk:not-persisted"
        )

        var thrown: HLError?
        do {
            _ = try await repo.uploadBatch([workout])
        } catch let error as HLError {
            thrown = error
        }
        guard case .notPersisted = thrown else {
            Issue.record("expected HLError.notPersisted, got \(String(describing: thrown))")
            return
        }
        #expect(thrown?.shouldPersistToOutbox == false)
        #expect(await outbox.snapshot.isEmpty, "a failed enqueue must never be reported as durably queued")
    }
}

/// Mutable clock-holder used to drive the repository's TTL deterministically.
/// Reference type so the closure captures by-reference rather than by-copy.
private final class ClockBox: @unchecked Sendable {
    var now: Date
    init(now: Date) {
        self.now = now
    }
}

private struct WorkoutEnqueueFailingKeychain: KeychainStoring {
    func setString(_: String, forKey _: String) throws {
        throw KeychainError.osStatus(-1)
    }

    func getString(forKey _: String) -> String? {
        nil
    }

    func setData(_: Data, forKey _: String) throws {
        throw KeychainError.osStatus(-1)
    }

    func getData(forKey _: String) -> Data? {
        nil
    }

    func remove(forKey _: String) throws {}
    func removeAll() throws {}
}

// swiftlint:enable force_unwrapping
