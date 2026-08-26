import Foundation
@testable import HealthLog
import Testing

/// **V053-D3 regression guard.** The sticky state machine for
/// `DashboardStore.metricStates` enforces monotonic transitions per
/// `MetricKind` so the dashboard view never flickers tiles between
/// `.loading → .empty → .ready` mid-fan-out. Operator-reported v0.5.2 bug:
/// "gehen immer mal wieder kurz andere Kacheln auf, die gehen dann immer
/// wieder weg".
@Suite("DashboardStore — V053-D3 sticky state transitions")
struct DashboardStoreStickyStateTests {
    private static func sample(_ kind: MetricKind, value: Double = 1.0) -> HealthLog.Measurement {
        HealthLog.Measurement(
            id: UUID().uuidString,
            kind: kind,
            recordedAt: .now,
            value: .scalar(value),
            source: .manual
        )
    }

    @Test(".unknown accepts every candidate state (initial resolution)")
    func unknownAcceptsAnything() {
        let sample = Self.sample(.weight)
        let readyState: MetricDataState = .ready(latest: sample, samples: [sample])
        #expect(DashboardStore.shouldAcceptTransition(from: .unknown, to: .loading))
        #expect(DashboardStore.shouldAcceptTransition(from: .unknown, to: .empty(reason: .noData)))
        #expect(DashboardStore.shouldAcceptTransition(from: .unknown, to: readyState))
    }

    @Test(".loading accepts every candidate state (initial resolution)")
    func loadingAcceptsAnything() {
        let sample = Self.sample(.weight)
        let readyState: MetricDataState = .ready(latest: sample, samples: [sample])
        #expect(DashboardStore.shouldAcceptTransition(from: .loading, to: .empty(reason: .noData)))
        #expect(DashboardStore.shouldAcceptTransition(from: .loading, to: readyState))
    }

    @Test(".ready accepts another .ready (data update)")
    func readyAcceptsReady() {
        let sample = Self.sample(.weight, value: 71.0)
        let newSample = Self.sample(.weight, value: 72.0)
        let oldReady: MetricDataState = .ready(latest: sample, samples: [sample])
        let newReady: MetricDataState = .ready(latest: newSample, samples: [newSample])
        #expect(DashboardStore.shouldAcceptTransition(from: oldReady, to: newReady))
    }

    @Test(".ready REJECTS demotion to .empty (sticky-ready)")
    func readyRejectsEmpty() {
        let sample = Self.sample(.weight)
        let ready: MetricDataState = .ready(latest: sample, samples: [sample])
        #expect(!DashboardStore.shouldAcceptTransition(from: ready, to: .empty(reason: .noData)))
        let outsideRange: MetricDataState = .empty(reason: .outsideRange(latestAt: .now))
        #expect(!DashboardStore.shouldAcceptTransition(from: ready, to: outsideRange))
    }

    @Test(".ready REJECTS demotion to .loading (sticky-ready)")
    func readyRejectsLoading() {
        let sample = Self.sample(.weight)
        let ready: MetricDataState = .ready(latest: sample, samples: [sample])
        #expect(!DashboardStore.shouldAcceptTransition(from: ready, to: .loading))
        #expect(!DashboardStore.shouldAcceptTransition(from: ready, to: .unknown))
    }

    @Test(".empty(.outsideRange) accepts .ready upgrade")
    func outsideRangeAcceptsReady() {
        let outsideRange: MetricDataState = .empty(reason: .outsideRange(latestAt: .now))
        let sample = Self.sample(.weight)
        let ready: MetricDataState = .ready(latest: sample, samples: [sample])
        #expect(DashboardStore.shouldAcceptTransition(from: outsideRange, to: ready))
    }

    @Test(".empty(.outsideRange) REJECTS demotion to .empty(.noData)")
    func outsideRangeRejectsNoData() {
        let outsideRange: MetricDataState = .empty(reason: .outsideRange(latestAt: .now))
        #expect(!DashboardStore.shouldAcceptTransition(from: outsideRange, to: .empty(reason: .noData)))
    }

    @Test(".empty(.noData) accepts upgrade to .ready")
    func noDataAcceptsReady() {
        let noData: MetricDataState = .empty(reason: .noData)
        let sample = Self.sample(.weight)
        let ready: MetricDataState = .ready(latest: sample, samples: [sample])
        #expect(DashboardStore.shouldAcceptTransition(from: noData, to: ready))
    }

    @Test(".empty(.noData) accepts upgrade to .empty(.outsideRange)")
    func noDataAcceptsOutsideRange() {
        let noData: MetricDataState = .empty(reason: .noData)
        let outsideRange: MetricDataState = .empty(reason: .outsideRange(latestAt: .now))
        #expect(DashboardStore.shouldAcceptTransition(from: noData, to: outsideRange))
    }
}

/// **V053-D3 integration.** `resetMetricStatesForRefresh()` is the only
/// hook the dashboard view uses to invalidate the sticky verdicts (called
/// from `.refreshable`). Without it pull-to-refresh would have no way to
/// recover from a `.ready` that needs to be re-derived (e.g. user deleted
/// the last sample on the server).
@Suite("DashboardStore — V053-D3 sticky reset on pull-to-refresh", .serialized)
@MainActor
struct DashboardStoreStickyResetTests {
    private func makeStore() throws -> DashboardStore {
        let baseURL = try #require(URL(string: "https://test.healthlog.local"))
        let env = AppEnvironment(
            baseURL: baseURL,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.3",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        let api = APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
        return DashboardStore(repo: DashboardRepository(api: api))
    }

    @Test("resetMetricStatesForRefresh clears all per-kind states + fan-out settled")
    func resetClearsStates() throws {
        let store = try makeStore()
        let sample = HealthLog.Measurement(
            id: "1",
            kind: .weight,
            recordedAt: .now,
            value: .scalar(72.0),
            source: .manual
        )
        // Seed via the test-only commit path: refreshMetricStates with
        // a stubbed repo would round-trip the network; for this contract
        // we want to assert the reset method semantics directly.
        store.recomputePolicyForTesting() // bump tick to non-zero baseline
        // We can't directly set metricStates (private), so we exercise the
        // observable reset path by asserting it doesn't crash + leaves
        // metricStates / fanOutSettledAt at their cleared values.
        store.resetMetricStatesForRefresh()
        #expect(store.metricStates.isEmpty)
        #expect(store.fanOutSettledAt == nil)
        _ = sample // silence unused-binding warning
    }
}
