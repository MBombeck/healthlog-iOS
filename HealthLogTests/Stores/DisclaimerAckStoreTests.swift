import Foundation
@testable import HealthLog
import Testing

// v1.18.6 (DISC-02) — locks the one-time medical-disclaimer acknowledgment.
//
// Covers:
// 1. **Decode** — `AuthMeDisclaimer` is decode-tolerant: a missing/null
//    `disclaimerAcknowledgedAt` → nil (treated as "not acknowledged"); a present
//    ISO timestamp decodes to a Date.
// 2. **Store** — `refresh()` maps a nil timestamp to `isAcknowledged == false`
//    and a present one to `true`; `acknowledge()` posts and flips the flag;
//    `clearOnLogout()` resets to the un-acknowledged baseline.

// MARK: - 1. Decode

@Suite("AuthMeDisclaimer — decode tolerance")
struct AuthMeDisclaimerDecodeTests {
    @Test("Missing field → nil (not acknowledged)")
    func missingFieldDecodesNil() throws {
        let data = Data(#"{"username":"x"}"#.utf8)
        let decoded = try JSONDecoder.hlDefault.decode(AuthMeDisclaimer.self, from: data)
        #expect(decoded.disclaimerAcknowledgedAt == nil)
    }

    @Test("Explicit null → nil (acknowledged-never)")
    func nullDecodesNil() throws {
        let data = Data(#"{"disclaimerAcknowledgedAt":null}"#.utf8)
        let decoded = try JSONDecoder.hlDefault.decode(AuthMeDisclaimer.self, from: data)
        #expect(decoded.disclaimerAcknowledgedAt == nil)
    }

    @Test("Present ISO timestamp decodes to a Date")
    func presentTimestampDecodes() throws {
        let data = Data(#"{"disclaimerAcknowledgedAt":"2026-06-18T10:00:00.000Z"}"#.utf8)
        let decoded = try JSONDecoder.hlDefault.decode(AuthMeDisclaimer.self, from: data)
        #expect(decoded.disclaimerAcknowledgedAt != nil)
    }
}

// MARK: - 2. Store

@MainActor
@Suite("DisclaimerAckStore — lifecycle")
struct DisclaimerAckStoreTests {
    /// Handler-based stub mirroring `AIProviderStoreTests.StubAPIClient`.
    private final class StubAPIClient: APIClientProtocol, @unchecked Sendable {
        var sendHandler: (@Sendable (any Sendable) async throws -> any Sendable)?

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            guard let handler = sendHandler else { throw HLError.unknown("no handler") }
            let result = try await handler(request)
            guard let typed = result as? T else {
                throw HLError.decoding("type mismatch — got \(type(of: result)), expected \(T.self)")
            }
            return typed
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {}
        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.canceled
        }
    }

    private func makeStore(api: StubAPIClient) -> DisclaimerAckStore {
        DisclaimerAckStore(repo: DisclaimerAckRepository(api: api))
    }

    @Test("refresh: nil timestamp → not acknowledged, hasLoaded true")
    func refreshNilNotAcknowledged() async {
        let api = StubAPIClient()
        api.sendHandler = { _ in AuthMeDisclaimer(disclaimerAcknowledgedAt: nil) }
        let store = makeStore(api: api)
        await store.refresh()
        #expect(store.isAcknowledged == false)
        #expect(store.hasLoaded == true)
        #expect(store.error == nil)
    }

    @Test("refresh: present timestamp → acknowledged")
    func refreshPresentAcknowledged() async {
        let api = StubAPIClient()
        api.sendHandler = { _ in AuthMeDisclaimer(disclaimerAcknowledgedAt: .now) }
        let store = makeStore(api: api)
        await store.refresh()
        #expect(store.isAcknowledged == true)
        #expect(store.hasLoaded == true)
    }

    @Test("acknowledge: posts version, flips isAcknowledged")
    func acknowledgeFlipsFlag() async {
        let api = StubAPIClient()
        api.sendHandler = { req in
            // The POST decodes into DisclaimerAckResponse; the GET into AuthMeDisclaimer.
            if req is APIRequest<DisclaimerAckResponse> {
                return DisclaimerAckResponse(acknowledgedVersion: DisclaimerAckStore.clientDisclaimerVersion)
            }
            return AuthMeDisclaimer(disclaimerAcknowledgedAt: nil)
        }
        let store = makeStore(api: api)
        #expect(store.isAcknowledged == false)
        await store.acknowledge()
        #expect(store.isAcknowledged == true)
        #expect(store.error == nil)
    }

    @Test("clearOnLogout: resets to un-acknowledged baseline")
    func clearOnLogoutResets() async {
        let api = StubAPIClient()
        api.sendHandler = { _ in AuthMeDisclaimer(disclaimerAcknowledgedAt: .now) }
        let store = makeStore(api: api)
        await store.refresh()
        #expect(store.isAcknowledged == true)
        store.clearOnLogout()
        #expect(store.isAcknowledged == false)
        #expect(store.hasLoaded == false)
    }

    // MARK: - Fail-soft: a transient /me error must NOT lock the user out

    @Test("refresh: transient /me error leaves hasLoaded false → gate stays down")
    func refreshErrorDoesNotGate() async {
        let api = StubAPIClient()
        api.sendHandler = { _ in throw HLError.offline }
        let store = makeStore(api: api)
        await store.refresh()
        // The read failed → hasLoaded never flipped, so the gate decision is
        // false (no lock-out on a blip).
        #expect(store.hasLoaded == false)
        #expect(store.error != nil)
        #expect(DisclaimerAckStore.shouldGate(
            hasLoaded: store.hasLoaded,
            isAcknowledged: store.isAcknowledged
        ) == false)
    }

    // MARK: - W-RECONCILE MED-1: the `-uitest-ack-disclaimer` bypass is DEBUG-only

    /// The test runner does NOT pass `-uitest-ack-disclaimer`, so `refresh()` must
    /// reflect the SERVER state, never short-circuit to acknowledged. This locks
    /// the contract that the compliance gate is honoured for any non-seeded run —
    /// and the bypass block itself is now `#if DEBUG`-wrapped so it cannot exist in
    /// a Release binary at all.
    @Test("no launch-arg → refresh honours server state (bypass never fires)")
    func bypassRequiresLaunchArg() async {
        #expect(ProcessInfo.processInfo.arguments.contains("-uitest-ack-disclaimer") == false)
        let api = StubAPIClient()
        api.sendHandler = { _ in AuthMeDisclaimer(disclaimerAcknowledgedAt: nil) }
        let store = makeStore(api: api)
        await store.refresh()
        // Server says not-acknowledged → store must NOT be force-acknowledged.
        #expect(store.isAcknowledged == false)
    }

    @Test("standalone: no launch-arg → refreshStandalone honours local flag")
    func standaloneBypassRequiresLaunchArg() throws {
        #expect(ProcessInfo.processInfo.arguments.contains("-uitest-ack-disclaimer") == false)
        let api = StubAPIClient()
        let defaults = try #require(UserDefaults(suiteName: "disclaimer-bypass-\(UUID().uuidString)"))
        let store = DisclaimerAckStore(repo: DisclaimerAckRepository(api: api), defaults: defaults)
        store.refreshStandalone()
        // No local ack stored + no DEBUG bypass arg → not acknowledged.
        #expect(store.isAcknowledged == false)
        #expect(store.hasLoaded == true)
    }
}

// MARK: - 3. Gate decision (G7 — before the shell)

@MainActor
@Suite("DisclaimerAckStore — gate decision (before-shell)")
struct DisclaimerAckGateDecisionTests {
    @Test("not loaded → no gate, no flash before /me answers")
    func notLoadedNoGate() {
        #expect(DisclaimerAckStore.shouldGate(hasLoaded: false, isAcknowledged: false) == false)
        #expect(DisclaimerAckStore.shouldGate(hasLoaded: false, isAcknowledged: true) == false)
    }

    @Test("loaded + acknowledged=false → gate shown before shell")
    func loadedUnacknowledgedGates() {
        #expect(DisclaimerAckStore.shouldGate(hasLoaded: true, isAcknowledged: false) == true)
    }

    @Test("loaded + acknowledged=true → no gate, straight to shell (no double-prompt)")
    func loadedAcknowledgedNoGate() {
        #expect(DisclaimerAckStore.shouldGate(hasLoaded: true, isAcknowledged: false) == true)
        #expect(DisclaimerAckStore.shouldGate(hasLoaded: true, isAcknowledged: true) == false)
    }
}

// MARK: - 4. Standalone (local) path — G1, flag-safe wiring

@MainActor
@Suite("DisclaimerAckStore — standalone (local) path")
struct DisclaimerAckStandaloneTests {
    /// Isolated, per-test UserDefaults suite so the local ack flag never leaks
    /// into `.standard` or across cases.
    private func makeIsolatedStore() -> (DisclaimerAckStore, UserDefaults) {
        let suiteName = "DisclaimerAckStandaloneTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            // A named suite never fails to allocate; fall back to standard so the
            // type checks, then clear our key to keep cases isolated.
            let fallback = UserDefaults.standard
            fallback.removeObject(forKey: DisclaimerAckStore.standaloneAckKey)
            let api = StubAPIClient()
            return (DisclaimerAckStore(repo: DisclaimerAckRepository(api: api), defaults: fallback), fallback)
        }
        defaults.removePersistentDomain(forName: suiteName)
        // The repo is never touched on the standalone path; a never-handler stub
        // proves that (any send() would throw).
        let api = StubAPIClient()
        let store = DisclaimerAckStore(repo: DisclaimerAckRepository(api: api), defaults: defaults)
        return (store, defaults)
    }

    private final class StubAPIClient: APIClientProtocol, @unchecked Sendable {
        func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
            throw HLError.unknown("standalone path must not hit the network")
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {}
        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.canceled
        }
    }

    @Test("fresh standalone install → refreshStandalone gates (would gate if flag on)")
    func freshStandaloneGates() {
        let (store, _) = makeIsolatedStore()
        store.refreshStandalone()
        // Local read always resolves → hasLoaded true; no prior ack → gate shown.
        #expect(store.hasLoaded == true)
        #expect(store.isAcknowledged == false)
        #expect(DisclaimerAckStore.shouldGate(
            hasLoaded: store.hasLoaded,
            isAcknowledged: store.isAcknowledged
        ) == true)
    }

    @Test("acknowledgeStandalone persists locally + dismisses the gate")
    func acknowledgeStandalonePersists() {
        let (store, defaults) = makeIsolatedStore()
        store.refreshStandalone()
        #expect(store.isAcknowledged == false)
        store.acknowledgeStandalone()
        #expect(store.isAcknowledged == true)
        #expect(defaults.string(forKey: DisclaimerAckStore.standaloneAckKey) != nil)
        #expect(DisclaimerAckStore.shouldGate(
            hasLoaded: store.hasLoaded,
            isAcknowledged: store.isAcknowledged
        ) == false)
    }

    @Test("already-acked standalone → no double-prompt across a fresh store")
    func standaloneAlreadyAckedNoDoublePrompt() {
        let (store, defaults) = makeIsolatedStore()
        store.refreshStandalone()
        store.acknowledgeStandalone()
        // Simulate a relaunch: a NEW store over the SAME persisted defaults must
        // read back the ack and NOT re-gate.
        let api = StubAPIClient()
        let reborn = DisclaimerAckStore(repo: DisclaimerAckRepository(api: api), defaults: defaults)
        reborn.refreshStandalone()
        #expect(reborn.isAcknowledged == true)
        #expect(DisclaimerAckStore.shouldGate(
            hasLoaded: reborn.hasLoaded,
            isAcknowledged: reborn.isAcknowledged
        ) == false)
    }

    @Test("clearOnLogout purges the local standalone flag")
    func clearOnLogoutPurgesLocal() {
        let (store, defaults) = makeIsolatedStore()
        store.acknowledgeStandalone()
        #expect(defaults.string(forKey: DisclaimerAckStore.standaloneAckKey) != nil)
        store.clearOnLogout()
        #expect(defaults.string(forKey: DisclaimerAckStore.standaloneAckKey) == nil)
    }
}
