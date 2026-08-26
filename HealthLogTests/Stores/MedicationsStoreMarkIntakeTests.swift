import Foundation
@testable import HealthLog
import SwiftData
import Testing

// swiftlint:disable force_unwrapping

/// PB6-reconcile F5 regression-coverage:
/// `MedicationsStore.mark(intake:status:)` used to call
/// `swr.invalidate(MutationKind.medicationIntakeChange.affectedKeys)` —
/// which wiped `.medicationsTodayIntakes` immediately after the optimistic
/// patch landed. The next observe-pass on the Meds tab emitted `.empty`,
/// the optimistic UI got cleared back to a skeleton, then the network
/// fetch re-populated 200-600 ms later. Visible UI flash for every
/// checkbox tap.
///
/// Post-reconcile: the patched `todayIntakes` array is **writeThrough**'d
/// to the cache; only sibling keys (compliance heatmap, dashboard summary,
/// health score) are invalidated. The next observe-pass sees `.cached`
/// with the optimistic value rather than `.empty` — no flash.
@Suite("MedicationsStore — F5 mark intake cache contract", .serialized)
struct MedicationsStoreMarkIntakeTests {
    /// v0.14.1 INV-med-cadence-phantom (BUG 2) — the today-intakes cache key is
    /// now day-anchored in the store's `profileTimeZone` (defaults to `.current`
    /// in tests). Mirror the store's `todayIntakesKey` so seeds/reads match.
    private static var todayKey: CacheKey {
        .medicationsTodayIntakes(day: MedicationDayKey.string(timeZone: .current))
    }

    private final class StubReach: ReachabilityProviding, @unchecked Sendable {
        let online: Bool
        init(online: Bool) {
            self.online = online
        }

        var isOnlineStream: AsyncStream<Bool> {
            get async {
                AsyncStream { c in c.yield(online)
                    c.finish()
                }
            }
        }

        func isCurrentlyOnline() async -> Bool {
            online
        }
    }

    @Test("mark(intake:) writes-through patched intakes + invalidates only sibling keys")
    @MainActor
    func markIntakeWriteThroughAndSiblingInvalidate() async throws {
        // Arrange — SWR coordinator with a seeded SwiftData cache.
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))

        // Pre-seed sibling cache entries to prove they get invalidated.
        // Sentinel payloads are decodable so we can probe their presence
        // after the mark call via `cache.read`.
        let seedDate = Date().addingTimeInterval(-30)
        try await cache.write(
            .medicationsCompliance(days: MedicationsStore.complianceDaysWindow),
            payload: JSONEncoder.hlDefault.encode([ComplianceDay]()),
            at: seedDate
        )
        try await cache.write(
            .dashboardSummary(day: MedicationDayKey.string(timeZone: .current)),
            payload: Data("{}".utf8),
            at: seedDate
        )
        try await cache.write(
            .healthScore,
            payload: Data("{}".utf8),
            at: seedDate
        )

        // Seed `.medicationsTodayIntakes` with a single pending row so the
        // store's first load surfaces it via `.cached`.
        let pending = MedicationIntake(
            id: "intake-1",
            medicationId: "med-1",
            scheduledAt: Date(timeIntervalSince1970: 1_714_550_400),
            takenAt: nil,
            status: .pending
        )
        try await cache.write(
            Self.todayKey,
            payload: JSONEncoder.hlDefault.encode([pending])
        )

        // Mock dispatches per request path — load() fires three parallel
        // fetches (.medicationsList, .medicationsTodayIntakes, .medicationsCompliance)
        // and the POST under test. Anything else returns 404 so a stray
        // request surfaces as a test failure.
        let api = makeAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            let method = req.httpMethod ?? "GET"
            let query = req.url?.query ?? ""
            if path == "/api/medications", method == "GET" {
                // Empty wire-array — store's medications list is allowed to be empty.
                return (Self.ok(req), Data(#"{"data":[]}"#.utf8))
            }
            if path == "/api/medications/intake", method == "GET", query.contains("scope=today") {
                let body = #"{"data":[{"id":"intake-1","medicationId":"med-1","scheduledAt":"2026-05-01T08:00:00Z","takenAt":null,"status":"pending","snoozedUntil":null}]}"#
                return (Self.ok(req), Data(body.utf8))
            }
            if path == "/api/medications/intake", method == "GET", query.contains("scope=compliance") {
                return (Self.ok(req), Data(#"{"data":[]}"#.utf8))
            }
            if path == "/api/medications/intake", method == "POST" {
                let body = #"{"data":{"id":"intake-1","medicationId":"med-1","scheduledFor":"2026-05-01T08:00:00Z","takenAt":"2026-05-01T08:05:00Z","skipped":false,"snoozedUntil":null}}"#
                return (Self.ok(req), Data(body.utf8))
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!,
                Data()
            )
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo, swr: coordinator)

        // Pull the cached + freshly-fetched state into the store.
        await store.load()
        #expect(store.todayIntakes.count == 1, "Load must surface the seeded intake")
        #expect(store.todayIntakes.first?.status == .pending)

        // Act — mark the intake as taken. This drives:
        //   1. optimistic patch on todayIntakes
        //   2. POST → 200 (mocked above)
        //   3. cache writeThrough(.medicationsTodayIntakes, patched array)
        //   4. cache.invalidate sibling keys
        await store.mark(intake: "intake-1", status: .taken)

        // Assert 0 — store-level error stays nil (regression for the
        // optimistic-patch contract; the mark succeeded).
        #expect(store.error == nil, "mark must succeed cleanly with the mocked 200")

        // Assert 1 — `.medicationsTodayIntakes` cache entry still exists
        // (NOT invalidated) and holds the patched array.
        let cachedAfter: Cached<[MedicationIntake]>? = await cache.read(
            Self.todayKey,
            as: [MedicationIntake].self
        )
        #expect(
            cachedAfter != nil,
            "writeThrough must keep .medicationsTodayIntakes hot — no UI flash on next observe"
        )
        #expect(cachedAfter?.value.count == 1)
        #expect(cachedAfter?.value.first?.status == .taken, "Cache must hold the optimistic-patched value")

        // Assert 2 — sibling keys ARE invalidated.
        let complianceAfter: Cached<[ComplianceDay]>? = await cache.read(
            .medicationsCompliance(days: MedicationsStore.complianceDaysWindow),
            as: [ComplianceDay].self
        )
        #expect(complianceAfter == nil, "Compliance cache must be invalidated after intake change")

        let dashboardAfter: Cached<EmptyDTO>? = await cache.read(
            .dashboardSummary(day: MedicationDayKey.string(timeZone: .current)),
            as: EmptyDTO.self
        )
        let healthAfter: Cached<EmptyDTO>? = await cache.read(.healthScore, as: EmptyDTO.self)
        #expect(dashboardAfter == nil, "dashboardSummary must be invalidated after intake change")
        #expect(healthAfter == nil, "healthScore must be invalidated after intake change")

        // Assert 3 — store-local view of intake is .taken (regression for the
        // optimistic-patch contract).
        #expect(store.todayIntakes.first?.status == .taken)
    }

    @Test("After mark(intake:), a fresh observe emits cached + patched (not .empty)")
    @MainActor
    func reObserveAfterMarkSeesCachedNotEmpty() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))

        // Seed the cache key so `.cached` is the first emit.
        let pending = MedicationIntake(
            id: "intake-1",
            medicationId: "med-1",
            scheduledAt: Date(timeIntervalSince1970: 1_714_550_400),
            takenAt: nil,
            status: .pending
        )
        try await cache.write(
            Self.todayKey,
            payload: JSONEncoder.hlDefault.encode([pending])
        )

        let api = makeAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            let method = req.httpMethod ?? "GET"
            let query = req.url?.query ?? ""
            if path == "/api/medications", method == "GET" {
                return (Self.ok(req), Data(#"{"data":[]}"#.utf8))
            }
            if path == "/api/medications/intake", method == "GET", query.contains("scope=today") {
                let body = #"{"data":[{"id":"intake-1","medicationId":"med-1","scheduledAt":"2026-05-01T08:00:00Z","takenAt":null,"status":"pending","snoozedUntil":null}]}"#
                return (Self.ok(req), Data(body.utf8))
            }
            if path == "/api/medications/intake", method == "GET", query.contains("scope=compliance") {
                return (Self.ok(req), Data(#"{"data":[]}"#.utf8))
            }
            if path == "/api/medications/intake", method == "POST" {
                let body = #"{"data":{"id":"intake-1","medicationId":"med-1","scheduledFor":"2026-05-01T08:00:00Z","takenAt":"2026-05-01T08:05:00Z","skipped":false,"snoozedUntil":null}}"#
                return (Self.ok(req), Data(body.utf8))
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!,
                Data()
            )
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo, swr: coordinator)

        await store.load()
        await store.mark(intake: "intake-1", status: .taken)

        // The cache entry the store just writeThrough'd should hold the
        // .taken array. Read it through the SWRCoordinator's `observe`
        // path: the first emit must be `.cached` (with the patched array),
        // NOT `.empty`. This is the user-visible "no UI flash" contract.
        let stream = await coordinator.observe(
            Self.todayKey,
            decoding: [MedicationIntake].self,
            fetch: { [pending] in [pending] } // not exercised on the cached path
        )
        var firstEmit: SWRState<[MedicationIntake]>?
        for await state in stream {
            firstEmit = state
            break
        }
        switch firstEmit {
        case let .cached(value, _):
            #expect(value.first?.status == .taken, "First observe-emit must be cached + patched after mark")
        case .empty:
            Issue.record("First observe-emit was .empty — F5 regression (UI flash returns)")
        case let .fresh(value):
            // Acceptable: cache super-fresh + non-stale → fresh emit. Value
            // must still be the patched .taken.
            #expect(value.first?.status == .taken)
        case .failed, .none:
            Issue.record("First observe-emit unexpectedly \(String(describing: firstEmit))")
        }
    }

    // MARK: - Helpers

    /// Tiny round-trip-able stand-in for the actual server envelopes — we
    /// just need a decodable placeholder for the sibling-key invalidate
    /// assertions to compile.
    private struct EmptyDTO: Codable {}

    @MainActor
    private func makeAPIClient() -> APIClient {
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
}

// swiftlint:enable force_unwrapping
