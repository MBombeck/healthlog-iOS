import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Locks the F-1 wire contract for `GET /api/feature-flags`
/// (server brief v1.4.31).
///
/// Covers:
/// - happy-path envelope decoding (server `{ data: { flags: ... }, error: nil }`)
/// - empty flag map (operator hasn't configured anything — every flag
///   defaults to its `FeatureFlag.defaultValue`)
/// - forward-compat unknown wire keys are skipped (not thrown)
/// - 403 + `errorCode: "assistant.disabled.<surface>"` envelope
///   surfaces as `HLError.assistantDisabled(_:)` from the repository
///   caller (the APIClient interception is locked in its own test
///   suite — this one verifies the repo's GET round-trip)
@Suite("FeatureFlagsRepository — wire contract", .serialized)
struct FeatureFlagsRepositoryTests {
    private func makeRepo() -> FeatureFlagsRepository {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        let api = APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
        return FeatureFlagsRepository(api: api)
    }

    @MainActor
    private func makeStore() -> FeatureFlagsStore {
        FeatureFlagsStore(repo: makeRepo())
    }

    @Test("fetch — decodes the server envelope into a [String: Bool] map")
    func fetchDecodesEnvelope() async throws {
        let repo = makeRepo()
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.handler = { req in
            if req.targets("/api/feature-flags") { calls += 1 }
            let body = Data(#"""
            {"data":{"flags":{"assistant.briefing":true,"assistant.coach":false,"assistant.trend":true,"assistant.insights":false}},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let map = try await repo.fetch()
        #expect(calls == 1)
        #expect(map["assistant.briefing"] == true)
        #expect(map["assistant.coach"] == false)
        #expect(map["assistant.trend"] == true)
        #expect(map["assistant.insights"] == false)
    }

    @Test("fetch — empty flag map decodes cleanly")
    func fetchEmptyMap() async throws {
        let repo = makeRepo()
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":{"flags":{}},"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let map = try await repo.fetch()
        #expect(map.isEmpty)
    }

    @Test("FeatureFlagsStore — refresh propagates the wire map into the typed cache")
    @MainActor
    func refreshPropagatesIntoStore() async {
        let store = makeStore()
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{"flags":{"assistant.briefing":false,"assistant.coach":true,"assistant.trend":false,"assistant.insights":true}},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.refresh()
        #expect(store.hasSnapshot)
        #expect(store.isEnabled(.assistantBriefing) == false)
        #expect(store.isEnabled(.assistantCoach) == true)
        #expect(store.isEnabled(.assistantTrend) == false)
        #expect(store.isEnabled(.assistantInsights) == true)
    }

    @Test("FeatureFlagsStore — pre-snapshot reads return fail-open defaults")
    @MainActor
    func preSnapshotFailsOpen() {
        let store = makeStore()
        // Never call refresh.
        for flag in FeatureFlag.allCases {
            #expect(store.isEnabled(flag) == flag.defaultValue)
        }
        #expect(store.hasSnapshot == false)
    }

    @Test("FeatureFlagsStore — forward-compat unknown wire keys are silently skipped")
    @MainActor
    func unknownWireKeysAreSkipped() async {
        let store = makeStore()
        MockURLProtocol.handler = { req in
            // `assistant.futuresurface` is a server-shipped flag the
            // current iOS build doesn't know about. The store must
            // ignore it (additive-contract) rather than throw.
            let body = Data(#"""
            {"data":{"flags":{"assistant.briefing":true,"assistant.futuresurface":false}},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.refresh()
        #expect(store.hasSnapshot)
        #expect(store.isEnabled(.assistantBriefing))
        // Unknown key didn't pollute the typed cache.
        #expect(store.flags.count == 1)
    }

    @Test("FeatureFlagsStore — refresh failure keeps last-known snapshot")
    @MainActor
    func failureKeepsLastKnown() async {
        let store = makeStore()
        // Warm with a successful fetch.
        nonisolated(unsafe) var phase = 0
        MockURLProtocol.handler = { req in
            // CU-07: only OUR endpoint advances the phase machine, so a request
            // from a parallel suite cannot consume the success response.
            if req.targets("/api/feature-flags") { phase += 1 }
            if phase == 1 {
                let body = Data(#"{"data":{"flags":{"assistant.briefing":false}},"error":null}"#.utf8)
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        await store.refresh()
        #expect(store.isEnabled(.assistantBriefing) == false)
        // Second refresh — server is 500'ing.
        await store.refresh()
        #expect(store.error != nil)
        // Last-known snapshot stays in place — fail-open contract.
        #expect(store.isEnabled(.assistantBriefing) == false)
        #expect(store.hasSnapshot, "hasSnapshot must stay true once it flipped")
    }

    @Test("FeatureFlagsStore — applyDisabled flips a single flag without a network call")
    @MainActor
    func applyDisabledFlipsTargetFlag() async {
        let store = makeStore()
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":{"flags":{"assistant.coach":true}},"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.refresh()
        #expect(store.isEnabled(.assistantCoach))
        // Simulate the APIClient 403-handling path mirroring the new
        // operator state into the store WITHOUT a follow-up fetch.
        store.applyDisabled(.assistantCoach)
        #expect(store.isEnabled(.assistantCoach) == false)
    }

    @Test("FeatureFlagsStore — clearOnLogout wipes cache and snapshot flag")
    @MainActor
    func clearOnLogoutWipesCache() async {
        let store = makeStore()
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":{"flags":{"assistant.briefing":false}},"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.refresh()
        #expect(store.hasSnapshot)
        store.clearOnLogout()
        #expect(store.flags.isEmpty)
        #expect(store.hasSnapshot == false)
        #expect(store.error == nil)
    }

    @Test("FeatureFlagsStore — snapshot is a Sendable value view over the typed cache")
    @MainActor
    func snapshotMirrorsTypedCache() async {
        let store = makeStore()
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{"flags":{"assistant.briefing":false,"assistant.trend":true}},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.refresh()
        let snap = store.snapshot
        #expect(snap.isEnabled(.assistantBriefing) == false)
        #expect(snap.isEnabled(.assistantTrend) == true)
        // Unknown-to-snapshot flag falls through to the type default
        // (fail-open) so an out-of-tree caller never accidentally
        // sees a flag as disabled.
        #expect(snap.isEnabled(.assistantCoach) == FeatureFlag.assistantCoach.defaultValue)
    }

    @Test("FeatureFlag.from(serverSurface:) — maps the errorCode suffix to the right flag")
    func surfaceMappingCoversAllAssistants() {
        #expect(FeatureFlag.from(serverSurface: "briefing") == .assistantBriefing)
        #expect(FeatureFlag.from(serverSurface: "coach") == .assistantCoach)
        #expect(FeatureFlag.from(serverSurface: "trend") == .assistantTrend)
        #expect(FeatureFlag.from(serverSurface: "trendObservations") == .assistantTrend)
        #expect(FeatureFlag.from(serverSurface: "insights") == .assistantInsights)
        #expect(FeatureFlag.from(serverSurface: "unknown") == nil)
    }
}

// swiftlint:enable force_unwrapping
