import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Locks the F-1 / R5 contract that
/// `FeatureFlagsStore.liveService()` returns a `FeatureFlagsServicing`
/// whose `isEnabled(_:)` reflects the store's current state across
/// actor boundaries — without requiring the caller to hop to the
/// MainActor.
///
/// This is the bridge that wires the on-device assistant actors
/// (`OnDeviceBriefingService`, `TrendObservationsService`) to the
/// server-deployed flag state. Without it, the actors would consult
/// stale UserDefaults defaults and the R5 contract ("gate both
/// server-AI and on-device AI behind operator flags") would break.
@Suite("FeatureFlagsStore.liveService — cross-actor flag query", .serialized)
struct FeatureFlagsLiveServiceTests {
    @MainActor
    private func makeStore() -> FeatureFlagsStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        let api = APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
        let repo = FeatureFlagsRepository(api: api)
        return FeatureFlagsStore(repo: repo)
    }

    @Test("liveService — pre-snapshot reads fail-open defaults")
    @MainActor
    func preSnapshotDefaults() {
        let store = makeStore()
        let live = store.liveService()
        // Same instance returned across calls (stable identity is
        // not a contract, but the resolver semantics must match).
        for flag in FeatureFlag.allCases {
            #expect(live.isEnabled(flag) == flag.defaultValue)
        }
    }

    @Test("liveService — reflects store mutations after refresh")
    @MainActor
    func reflectsStoreMutations() async {
        let store = makeStore()
        let live = store.liveService()
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{"flags":{"assistant.briefing":false,"assistant.trend":false}},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.refresh()
        #expect(live.isEnabled(.assistantBriefing) == false)
        #expect(live.isEnabled(.assistantTrend) == false)
        // Defaults still apply for flags not in the wire payload.
        #expect(live.isEnabled(.assistantCoach) == FeatureFlag.assistantCoach.defaultValue)
    }

    @Test("liveService — applyDisabled flips the live cell immediately")
    @MainActor
    func applyDisabledFlipsCell() async {
        let store = makeStore()
        let live = store.liveService()
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":{"flags":{"assistant.coach":true}},"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.refresh()
        #expect(live.isEnabled(.assistantCoach))
        store.applyDisabled(.assistantCoach)
        // No await — the live cell is sync. The 403 mirror handler
        // races with the placeholder render; the live cell hop is
        // synchronous so the on-device path skips the inference on
        // the same tick the 403 lands.
        #expect(live.isEnabled(.assistantCoach) == false)
    }

    @Test("liveService — clearOnLogout wipes the live cell")
    @MainActor
    func clearOnLogoutWipesCell() async {
        let store = makeStore()
        let live = store.liveService()
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":{"flags":{"assistant.briefing":false}},"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.refresh()
        #expect(live.isEnabled(.assistantBriefing) == false)
        store.clearOnLogout()
        // Post-clear, defaults apply again (next login will refresh).
        #expect(live.isEnabled(.assistantBriefing) == FeatureFlag.assistantBriefing.defaultValue)
    }

    @Test("OnDeviceBriefingService — live-flag gating short-circuits when briefing off")
    @MainActor
    func onDeviceBriefingHonoursLiveFlags() async {
        let store = makeStore()
        let live = store.liveService()
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":{"flags":{"assistant.briefing":false}},"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.refresh()
        let service = OnDeviceBriefingService(featureFlags: live)
        let outcome = await service.generate(
            measurements: [],
            healthScore: nil,
            locale: Locale(identifier: "de_DE")
        )
        #expect(outcome.fallbackReason == .featureFlagDisabled)
        #expect(outcome.briefing == nil)
    }

    @Test("TrendObservationsService — live-flag gating short-circuits when trend off")
    @MainActor
    func trendObservationsHonoursLiveFlags() async {
        let store = makeStore()
        let live = store.liveService()
        MockURLProtocol.handler = { req in
            // briefing ON, trend OFF — should still short-circuit
            // because the trend gate is AND-ed with briefing.
            let body = Data(#"""
            {"data":{"flags":{"assistant.briefing":true,"assistant.trend":false}},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.refresh()
        let service = TrendObservationsService(featureFlags: live)
        let outcome = await service.observe(
            metric: .weight,
            series: [],
            locale: Locale(identifier: "de_DE")
        )
        #expect(outcome.fallbackReason == .featureFlagDisabled)
        #expect(outcome.observation == nil)
    }
}

// swiftlint:enable force_unwrapping
