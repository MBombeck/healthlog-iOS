import Foundation
@testable import HealthLog
import Testing

// (no swiftlint disables needed — all force unwraps moved through #require)

/// **V052-R3 A-H1 regression guard.** `DashboardStore` must publish an
/// observable signal that fires *after* `fanOutSettledAt` is written, so
/// the dashboard view re-evaluates `DashboardEmptyTilePolicy.shouldAutoHide`
/// past the 1.5s grace window. Without this signal a cold-launch where
/// HK + network both fail leaves tiles stuck on `.loading` forever
/// (operator-reported: pull-to-refresh was the only workaround).
///
/// Contract:
/// 1. `policyTick` starts at 0.
/// 2. Recomputing the policy (test seam) increments `policyTick`.
/// 3. `clearOnLogout` resets `policyTick` back to 0.
@Suite("DashboardStore — V052-R3 A-H1 policy-tick re-render trigger", .serialized)
struct DashboardStorePolicyTickTests {
    @MainActor
    private func makeStore() throws -> DashboardStore {
        let baseURL = try #require(URL(string: "https://test.healthlog.local"))
        let env = AppEnvironment(
            baseURL: baseURL,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.2",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        let api = APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
        return DashboardStore(repo: DashboardRepository(api: api))
    }

    @Test("policyTick starts at zero")
    @MainActor
    func policyTickStartsAtZero() throws {
        let store = try makeStore()
        #expect(store.policyTick == 0)
    }

    @Test("recomputePolicyForTesting increments policyTick")
    @MainActor
    func recomputeBumpsTick() throws {
        let store = try makeStore()
        store.recomputePolicyForTesting()
        #expect(store.policyTick == 1)
        store.recomputePolicyForTesting()
        #expect(store.policyTick == 2)
    }

    @Test("clearOnLogout resets policyTick")
    @MainActor
    func logoutResetsTick() throws {
        let store = try makeStore()
        store.recomputePolicyForTesting()
        store.recomputePolicyForTesting()
        #expect(store.policyTick == 2)
        store.clearOnLogout()
        #expect(store.policyTick == 0)
    }

    /// Integration-level: after `refreshMetricStates` fails on the wide-
    /// page fetch (recentAll throws), the policy-tick task is scheduled.
    /// We can't reliably sleep 1.6s in the unit suite, but we CAN assert
    /// the path runs without crashing and `fanOutSettledAt` lands. The
    /// post-grace tick is exercised by `DashboardEmptyTilePolicyTests`
    /// against the pure policy struct; this test pins the schedule-call
    /// integration (no exception, no main-actor isolation violation).
    @Test("refreshMetricStates failure path schedules tick without crashing")
    @MainActor
    func failurePathSchedulesTick() async throws {
        let baseURL = try #require(URL(string: "https://test.healthlog.local"))
        let env = AppEnvironment(
            baseURL: baseURL,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.2",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        let api = APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
        let outbox = try OutboxQueue(inMemory: true)
        let measurementsRepo = MeasurementsRepository(api: api, outbox: outbox)
        let store = DashboardStore(repo: DashboardRepository(api: api))

        // Force a 500 so `recentAll()` throws and the catch-branch runs.
        MockURLProtocol.handler = { request in
            let url = request.url ?? URL(fileURLWithPath: "/")
            let response = HTTPURLResponse(
                url: url,
                statusCode: 500,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ) ?? HTTPURLResponse()
            return (response, Data("{}".utf8))
        }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        await store.refreshMetricStates(
            kinds: [.weight, .pulse],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: now
        )
        // Catch branch fired → fan-out is settled.
        #expect(store.fanOutSettledAt == now)
        // Tick has NOT incremented yet — the scheduled task sleeps 1.6s
        // before bumping. The schedule call itself is fire-and-forget on
        // the main actor.
        #expect(store.policyTick == 0)
    }
}
