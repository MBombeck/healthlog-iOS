import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **W-TILEHOTFIX (v0.6.2) — pin the set-once `fanOutSettledAt` contract.**
///
/// Operator on v0.6.1.28 build 68 (2026-05-24): "im Home die Dinge, wenn ich
/// von einer anderen Karte komme, immer Kurzkacheln dargestellt werden, die
/// danach weg sind." — returning to the Dashboard from another card/tab
/// briefly re-rendered the synthesised placeholder tiles that should have
/// been hidden, then re-hid them ~1.6s later.
///
/// Root cause: every `.task` re-fire on nav-pop / tab-return re-entered
/// `DashboardStore.refreshMetricStates`, which unconditionally rewrote
/// `fanOutSettledAt = now`. `DashboardEmptyTilePolicy.shouldAutoHide`
/// gates its hide decision on `elapsed = now - fanOutSettledAt >= 1.6s`.
/// Resetting the timestamp re-opened the grace window — synth placeholder
/// tiles that were correctly hidden popped back visible for one render
/// cycle until the next policy tick fired and hid them again.
///
/// Fix: `fanOutSettledAt` is set-once per resolution. Subsequent
/// `refreshMetricStates` calls leave the prior timestamp intact so
/// already-settled hide decisions stay settled. The pull-to-refresh path
/// (`resetMetricStatesForRefresh()`) clears `fanOutSettledAt = nil`, so
/// that user-driven invalidation point still re-stamps on the next pass.
@Suite("DashboardStore — W-TILEHOTFIX set-once fanOutSettledAt contract", .serialized)
struct DashboardStoreSettleStabilityTests {
    @MainActor
    private func makeStore() throws -> (DashboardStore, MeasurementsRepository) {
        let baseURL = try #require(URL(string: "https://test.healthlog.local"))
        let env = AppEnvironment(
            baseURL: baseURL,
            bundleID: "dev.healthlog.app",
            appVersion: "0.6.2",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        let api = APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
        let measurementsRepo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let store = DashboardStore(repo: DashboardRepository(api: api))
        return (store, measurementsRepo)
    }

    /// Wire payload for `/api/measurements?limit=400` — empty page so every
    /// queried kind derives to `.empty(.noData)`. Series fallback returns
    /// 404/empty too so the kinds stay `.empty`. This is the realistic
    /// state for the synth placeholder tiles the operator-bug surfaces.
    private static func emptyMeasurementsPayload() -> Data {
        Data("{\"data\":{\"measurements\":[]}}".utf8)
    }

    /// Wire payload for `/api/measurements/series` — empty so the fallback
    /// pass leaves the wide-page-derived state intact.
    private static func emptySeriesPayload() -> Data {
        Data("{\"data\":{\"series\":{\"kind\":\"WEIGHT\",\"points\":[]}}}".utf8)
    }

    /// **THE BUG-PIN.** Two successive `refreshMetricStates` calls (mirrors
    /// the `.task` re-fire on nav-pop / tab-return) must NOT re-stamp
    /// `fanOutSettledAt`. The first-settle timestamp is the canonical
    /// "when did we know enough to start hiding stuck tiles" anchor; the
    /// second call leaves it intact so `DashboardEmptyTilePolicy`'s 1.6s
    /// grace window doesn't re-open.
    @Test("Successive refreshMetricStates calls keep first-settle fanOutSettledAt")
    @MainActor
    func successiveRefreshesPreserveSettleTimestamp() async throws {
        let (store, measurementsRepo) = try makeStore()
        MockURLProtocol.handler = { request in
            let url = request.url ?? URL(fileURLWithPath: "/")
            let path = url.path
            let body: Data = if path.contains("/api/measurements/series") {
                Self.emptySeriesPayload()
            } else {
                Self.emptyMeasurementsPayload()
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ) ?? HTTPURLResponse()
            return (response, body)
        }
        let firstNow = Date(timeIntervalSince1970: 1_700_000_000)
        await store.refreshMetricStates(
            kinds: [.weight, .pulse],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: firstNow
        )
        #expect(store.fanOutSettledAt == firstNow)

        // Simulate nav-pop / tab-return — `.task` re-fires, hitting the
        // store with a fresh `now` clock. The first-settle anchor must
        // survive.
        let secondNow = firstNow.addingTimeInterval(45)
        await store.refreshMetricStates(
            kinds: [.weight, .pulse],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: secondNow
        )
        #expect(
            store.fanOutSettledAt == firstNow,
            "fanOutSettledAt must stay at the first-settle anchor — re-stamping re-opens the 1.6s auto-hide grace and re-shows synth tiles on every nav-pop."
        )
    }

    /// Catch-path mirror: `recentAll()` throws on both calls (500). The
    /// catch branch sets `fanOutSettledAt = now` once on the first
    /// failure and must not re-stamp on the second.
    @Test("Successive refreshMetricStates failures keep first-settle fanOutSettledAt")
    @MainActor
    func successiveFailuresPreserveSettleTimestamp() async throws {
        let (store, measurementsRepo) = try makeStore()
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
        let firstNow = Date(timeIntervalSince1970: 1_700_000_000)
        await store.refreshMetricStates(
            kinds: [.weight, .pulse],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: firstNow
        )
        #expect(store.fanOutSettledAt == firstNow)

        let secondNow = firstNow.addingTimeInterval(45)
        await store.refreshMetricStates(
            kinds: [.weight, .pulse],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: secondNow
        )
        #expect(
            store.fanOutSettledAt == firstNow,
            "Catch-path settle anchor must be set-once too — repeat failures keep the original timestamp so the auto-hide grace already-elapsed for synth tiles doesn't reset."
        )
    }

    /// `resetMetricStatesForRefresh()` (pull-to-refresh) explicitly invalidates
    /// the prior settle anchor. The next `refreshMetricStates` call MUST
    /// re-stamp `fanOutSettledAt` with the fresh `now` — pull-to-refresh
    /// is the one user-driven path that opens the grace window again, by
    /// design.
    @Test("Pull-to-refresh resets the settle anchor and the next refresh re-stamps")
    @MainActor
    func pullToRefreshReopensSettleAnchor() async throws {
        let (store, measurementsRepo) = try makeStore()
        MockURLProtocol.handler = { request in
            let url = request.url ?? URL(fileURLWithPath: "/")
            let path = url.path
            let body: Data = if path.contains("/api/measurements/series") {
                Self.emptySeriesPayload()
            } else {
                Self.emptyMeasurementsPayload()
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ) ?? HTTPURLResponse()
            return (response, body)
        }
        let firstNow = Date(timeIntervalSince1970: 1_700_000_000)
        await store.refreshMetricStates(
            kinds: [.weight],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: firstNow
        )
        #expect(store.fanOutSettledAt == firstNow)

        // Pull-to-refresh — operator explicitly invalidates prior verdicts.
        store.resetMetricStatesForRefresh()
        #expect(store.fanOutSettledAt == nil)

        let secondNow = firstNow.addingTimeInterval(120)
        await store.refreshMetricStates(
            kinds: [.weight],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: secondNow
        )
        #expect(
            store.fanOutSettledAt == secondNow,
            "After pull-to-refresh the next fan-out must re-stamp — this is the explicit user-driven re-open of the grace window."
        )
    }

    /// `clearOnLogout` also clears the anchor (existing contract); the
    /// next post-login fan-out re-stamps. Guard against a regression that
    /// over-protects the anchor against logout cleanup.
    @Test("clearOnLogout resets the settle anchor")
    @MainActor
    func clearOnLogoutResetsSettleAnchor() async throws {
        let (store, measurementsRepo) = try makeStore()
        MockURLProtocol.handler = { request in
            let url = request.url ?? URL(fileURLWithPath: "/")
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ) ?? HTTPURLResponse()
            return (response, Self.emptyMeasurementsPayload())
        }
        let firstNow = Date(timeIntervalSince1970: 1_700_000_000)
        await store.refreshMetricStates(
            kinds: [.weight],
            measurementsRepo: measurementsRepo,
            rangeDays: 30,
            now: firstNow
        )
        #expect(store.fanOutSettledAt == firstNow)
        store.clearOnLogout()
        #expect(store.fanOutSettledAt == nil)
    }
}

// swiftlint:enable force_unwrapping
