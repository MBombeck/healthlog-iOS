import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **v0.14.8 INV-home-compliance-slot — Home compliance ring "2 von 2" bug.**
///
/// The Home `ComplianceRingCard`'s server input is `summary.compliance` from the
/// `.dashboardSummary` SWR cache key. Pre-fix that key carried no `day:`
/// discriminant, so a prior-day "2 scheduled / 2 taken" snapshot survived the
/// midnight rollover, was SWR-served via the `.cached` arm on the next calendar
/// day, and the ring rendered a phantom "2 von 2 genommen" even though nothing
/// was taken today. The medications-tab card was already correct because
/// `.medicationsTodayIntakes(day:)` IS day-anchored (the b160 fix).
///
/// These tests pin the two-layer fix:
/// 1. `.dashboardSummary(day:)` is now day-anchored — two calendar days produce
///    structurally distinct cache keys (different `persistentHash`).
/// 2. Integration: a stale day-N summary in the cache is NOT served on day N+1
///    by a `DashboardStore` whose profile-tz key has rolled over — it fetches
///    the fresh server value instead (real `APIClient` + `MockURLProtocol`,
///    no mock server).
/// 3. `ComplianceSnapshot.reconciled` prefers the empty day-anchored local view
///    over a stale server count once meds are loaded, but still uses the server
///    snapshot on a genuine cold start (meds not yet loaded).
@Suite("DashboardSummary day-anchor — INV-home-compliance-slot", .serialized)
struct DashboardSummaryDayAnchorTests {
    // MARK: - 1. Key day-anchoring

    @Test(".dashboardSummary key differs across a day boundary")
    func keyDiffersAcrossDayBoundary() {
        let dayN = CacheKey.dashboardSummary(day: "2026-06-05")
        let dayNPlus1 = CacheKey.dashboardSummary(day: "2026-06-06")
        #expect(dayN != dayNPlus1)
        #expect(dayN.persistentHash != dayNPlus1.persistentHash)
        #expect(dayN.canonicalString == "dashboardSummary:2026-06-05")
        #expect(dayNPlus1.canonicalString == "dashboardSummary:2026-06-06")
    }

    @Test(".dashboardSummary key is stable within the same day")
    func keyStableWithinDay() {
        let a = CacheKey.dashboardSummary(day: "2026-06-06")
        let b = CacheKey.dashboardSummary(day: "2026-06-06")
        #expect(a == b)
        #expect(a.persistentHash == b.persistentHash)
    }

    /// The profile-tz day-key the store builds from must flip at the profile
    /// zone's local midnight — same boundary the medication "today" bucket uses.
    @Test("dashboardSummaryKey rolls over at profile-tz midnight")
    func keyRollsOverAtProfileMidnight() throws {
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        // 2026-06-05 23:30 Berlin (still day N) vs 2026-06-06 00:30 Berlin (day N+1).
        let f = ISO8601DateFormatter()
        let beforeMidnight = try #require(f.date(from: "2026-06-05T21:30:00Z")) // 23:30 CEST
        let afterMidnight = try #require(f.date(from: "2026-06-05T22:30:00Z")) // 00:30 CEST next day
        let keyN = MedicationDayKey.string(for: beforeMidnight, timeZone: berlin)
        let keyNPlus1 = MedicationDayKey.string(for: afterMidnight, timeZone: berlin)
        #expect(keyN == "2026-06-05")
        #expect(keyNPlus1 == "2026-06-06")
    }

    // MARK: - 2. Integration — stale day-N snapshot not served on day N+1

    @MainActor
    private func makeAPIClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.8",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
    }

    /// Server-wire JSON (envelope) the `MockURLProtocol` returns — decoded by
    /// the real `APIClient` → `DashboardRepository.summary()`.
    private func summaryWireJSON(scheduled: Int, taken: Int) -> Data {
        Data(#"""
        {
            "data": {
                "greeting": { "salutation": "Hi", "date": "2026-06-06T08:00:00.000Z" },
                "compliance": { "scheduledToday": \#(scheduled), "takenToday": \#(taken) },
                "highlightInsight": null,
                "metrics": [],
                "lastUpdated": "2026-06-06T08:00:00.000Z"
            },
            "error": null
        }
        """#.utf8)
    }

    /// The SWR cache stores the `hlDefault`-encoded model (NOT the server
    /// envelope) — `SWRCoordinator.observe` re-encodes the decoded value. Seed
    /// rows must therefore be the model-form bytes.
    private func summaryCacheBytes(scheduled: Int, taken: Int) throws -> Data {
        let summary = DashboardSummary(
            greeting: Greeting(salutation: "Hi", date: Date(timeIntervalSince1970: 1_749_196_800)),
            compliance: ComplianceSnapshot(scheduledToday: scheduled, takenToday: taken),
            highlightInsight: nil,
            metrics: [],
            lastUpdated: nil
        )
        return try JSONEncoder.hlDefault.encode(summary)
    }

    @Test("stale day-N 2/2 snapshot is NOT served on day N+1 — fresh server wins")
    @MainActor
    func staleSnapshotNotServedAcrossMidnight() async throws {
        let api = makeAPIClient()
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coordinator = SWRCoordinator(cache: cache, reachability: AlwaysOnlineReach())
        let repo = DashboardRepository(api: api)
        let store = DashboardStore(repo: repo, swr: coordinator)
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        store.profileTimeZoneProvider = { berlin }

        // Seed a STALE day-N (yesterday) summary with compliance 2/2 — the
        // "2 von 2 genommen" snapshot the operator hit. Written under the
        // day-N key, which the store will NOT read on day N+1.
        let staleSummary = try summaryCacheBytes(scheduled: 2, taken: 2)
        try await cache.write(
            .dashboardSummary(day: "2026-06-05"),
            payload: staleSummary,
            at: Date().addingTimeInterval(-3600)
        )

        // The store's key resolves to TODAY in Berlin. The server returns the
        // fresh 0/0 (nothing taken today).
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, summaryWireJSON(scheduled: 0, taken: 0))
        }

        await store.load(force: true)

        let compliance = try #require(store.summary?.compliance)
        // The stale 2/2 must NOT leak through — the day-anchored key structurally
        // missed it, so the fresh 0/0 is what renders.
        #expect(compliance.scheduledToday == 0)
        #expect(compliance.takenToday == 0)
    }

    @Test("same-day cached summary IS served (no spurious refetch within the day)")
    @MainActor
    func sameDaySnapshotServed() async throws {
        let api = makeAPIClient()
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coordinator = SWRCoordinator(cache: cache, reachability: AlwaysOnlineReach())
        let repo = DashboardRepository(api: api)
        let store = DashboardStore(repo: repo, swr: coordinator)
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        store.profileTimeZoneProvider = { berlin }
        let today = MedicationDayKey.string(timeZone: berlin)

        // Seed TODAY's summary with 1/1 inside the 45s TTL → cache-served first.
        try await cache.write(
            .dashboardSummary(day: today),
            payload: summaryCacheBytes(scheduled: 1, taken: 1),
            at: Date().addingTimeInterval(-1)
        )
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, summaryWireJSON(scheduled: 1, taken: 1))
        }
        await store.load()
        let compliance = try #require(store.summary?.compliance)
        #expect(compliance.scheduledToday == 1)
        #expect(compliance.takenToday == 1)
    }

    // MARK: - 3. Reconciler cold-start-vs-loaded distinction

    @Test("reconciler prefers empty local over stale server when meds are loaded")
    func reconcilerPrefersEmptyLocalWhenLoaded() {
        // Server carries a stale 2/2 (the leaked prior-day snapshot). Local view
        // has 0 today-slots and meds ARE loaded → the calm empty 0/0 must win.
        let reconciled = ComplianceSnapshot.reconciled(
            server: ComplianceSnapshot(scheduledToday: 2, takenToday: 2),
            todayIntakes: [],
            activeMedicationIDs: ["med-A"],
            medicationsLoaded: true
        )
        #expect(reconciled.scheduledToday == 0)
        #expect(reconciled.takenToday == 0)
        #expect(reconciled.hasSchedule == false)
    }

    @Test("reconciler still uses server on a genuine cold start (meds not loaded)")
    func reconcilerUsesServerOnColdStart() {
        // Meds not loaded yet → the empty local view is empty only because there
        // is no data → trust the server snapshot so the cold-cache first-paint
        // still renders.
        let reconciled = ComplianceSnapshot.reconciled(
            server: ComplianceSnapshot(scheduledToday: 2, takenToday: 1),
            todayIntakes: [],
            activeMedicationIDs: ["med-A"],
            medicationsLoaded: false
        )
        #expect(reconciled.scheduledToday == 2)
        #expect(reconciled.takenToday == 1)
    }
}

/// Minimal always-online reachability stub for the integration tests above.
private final class AlwaysOnlineReach: ReachabilityProviding, @unchecked Sendable {
    var isOnlineStream: AsyncStream<Bool> {
        get async {
            AsyncStream { c in
                c.yield(true)
                c.finish()
            }
        }
    }

    func isCurrentlyOnline() async -> Bool {
        true
    }
}

// swiftlint:enable force_unwrapping
