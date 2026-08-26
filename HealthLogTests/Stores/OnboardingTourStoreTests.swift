import Foundation
@testable import HealthLog
import Testing

// #32 (W-ONBOARD-TOUR-PROGRESS) — locks the server-persisted onboarding-tour /
// setup-completion state.
//
// Covers:
// 1. **Decode** — `AuthMeOnboarding` is decode-tolerant: a missing/null
//    `onboardingTourCompleted` → nil (treated as "endpoint absent / unknown");
//    a present bool decodes. `TourUpdateBody` omits absent keys.
// 2. **Store** — `markCompleted()` posts `completed:true` on advance and flips
//    the flag + local cache; `refresh()` reads the server flag and a server
//    `true` wins over a stale-`false` local cache (server-authoritative);
//    endpoint-absent (`nil`) → graceful local fallback; `clearOnLogout()` wipes.

// MARK: - 1. Decode / encode tolerance

@Suite("AuthMeOnboarding — decode tolerance")
struct AuthMeOnboardingDecodeTests {
    @Test("Missing field → nil (endpoint absent)")
    func missingFieldDecodesNil() throws {
        let data = Data(#"{"username":"x"}"#.utf8)
        let decoded = try JSONDecoder.hlDefault.decode(AuthMeOnboarding.self, from: data)
        #expect(decoded.onboardingTourCompleted == nil)
    }

    @Test("Explicit null → nil")
    func nullDecodesNil() throws {
        let data = Data(#"{"onboardingTourCompleted":null}"#.utf8)
        let decoded = try JSONDecoder.hlDefault.decode(AuthMeOnboarding.self, from: data)
        #expect(decoded.onboardingTourCompleted == nil)
    }

    @Test("Present bool decodes")
    func presentBoolDecodes() throws {
        let data = Data(#"{"onboardingTourCompleted":true}"#.utf8)
        let decoded = try JSONDecoder.hlDefault.decode(AuthMeOnboarding.self, from: data)
        #expect(decoded.onboardingTourCompleted == true)
    }

    @Test("TourUpdateBody omits absent keys, encodes present ones")
    func bodyOmitsAbsentKeys() throws {
        let body = TourUpdateBody(completed: true, outcome: .completed)
        let json = try JSONEncoder.hlDefault.encode(body)
        let obj = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        #expect(obj?["completed"] as? Bool == true)
        #expect(obj?["outcome"] as? String == "completed")
        #expect(obj?["progress"] == nil) // absent key omitted
    }
}

// MARK: - 2. Store lifecycle

@MainActor
@Suite("OnboardingTourStore — lifecycle")
struct OnboardingTourStoreTests {
    /// Handler-based stub mirroring `DisclaimerAckStoreTests.StubAPIClient`.
    private final class StubAPIClient: APIClientProtocol, @unchecked Sendable {
        var sendHandler: (@Sendable (any Sendable) async throws -> any Sendable)?
        /// Count of POSTs (the `/api/onboarding/tour` write) the store fired.
        var postCount = 0

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

    /// A throwaway in-memory UserDefaults so the local cache is isolated per test.
    private func ephemeralDefaults() throws -> UserDefaults {
        let suite = "test.onboardingTour.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeStore(api: StubAPIClient, defaults: UserDefaults) -> OnboardingTourStore {
        OnboardingTourStore(repo: OnboardingTourRepository(api: api), defaults: defaults)
    }

    @Test("markCompleted: posts completed:true on advance, flips flag + cache")
    func markCompletedPosts() async throws {
        let api = StubAPIClient()
        let defaults = try ephemeralDefaults()
        api.sendHandler = { req in
            if req is APIRequest<TourUpdateResponse> {
                api.postCount += 1
                return TourUpdateResponse(onboardingTourCompleted: true, progress: nil)
            }
            return AuthMeOnboarding(onboardingTourCompleted: nil)
        }
        let store = makeStore(api: api, defaults: defaults)
        #expect(store.isCompleted == false)
        await store.markCompleted()
        #expect(store.isCompleted == true)
        #expect(api.postCount == 1) // the POST /api/onboarding/tour fired
        #expect(defaults.bool(forKey: OnboardingTourStore.cacheKey) == true)
    }

    @Test("markCompleted: no-op when already completed (no double-post)")
    func markCompletedNoDoublePost() async throws {
        let api = StubAPIClient()
        let defaults = try ephemeralDefaults()
        api.sendHandler = { req in
            if req is APIRequest<TourUpdateResponse> {
                api.postCount += 1
                return TourUpdateResponse(onboardingTourCompleted: true, progress: nil)
            }
            return AuthMeOnboarding(onboardingTourCompleted: nil)
        }
        let store = makeStore(api: api, defaults: defaults)
        await store.markCompleted()
        await store.markCompleted()
        #expect(api.postCount == 1)
    }

    @Test("refresh: server true wins over stale-false local cache (server-authoritative)")
    func refreshServerAuthoritative() async throws {
        let api = StubAPIClient()
        let defaults = try ephemeralDefaults()
        // Stale local cache says NOT completed (e.g. fresh install).
        defaults.set(false, forKey: OnboardingTourStore.cacheKey)
        // Server says completed (user finished onboarding on another device).
        api.sendHandler = { _ in AuthMeOnboarding(onboardingTourCompleted: true) }
        let store = makeStore(api: api, defaults: defaults)
        #expect(store.isCompleted == false) // nothing is concluded before a lookup settles
        await store.refresh()
        #expect(store.isCompleted == true) // server wins
        #expect(store.hasLoaded == true)
        #expect(defaults.bool(forKey: OnboardingTourStore.cacheKey) == true)
    }

    @Test("refresh: endpoint-absent (nil) → graceful local fallback, cache unchanged")
    func refreshEndpointAbsentFallsBack() async throws {
        let api = StubAPIClient()
        let defaults = try ephemeralDefaults()
        defaults.set(true, forKey: OnboardingTourStore.cacheKey) // local says completed
        api.sendHandler = { _ in AuthMeOnboarding(onboardingTourCompleted: nil) } // older server
        let store = makeStore(api: api, defaults: defaults)
        // 08-08 — nothing is seeded from the cache at construction any more. The
        // old seed existed because an unresolved lookup was indistinguishable
        // from an incomplete one, so the store had to guess early; it now has a
        // fourth state for exactly that and guesses nowhere.
        #expect(store.isCompleted == false)
        #expect(store.hasLoaded == false)
        await store.refresh()
        #expect(store.isCompleted == true) // the request answered — the local mirror stands
        #expect(store.hasLoaded == true)
        #expect(store.resolution == .endpointAbsent)
    }

    @Test("refresh: network error → settled as unavailable, and an un-owned cache is not spent")
    func refreshNetworkErrorFailsSoft() async throws {
        let api = StubAPIClient()
        let defaults = try ephemeralDefaults()
        defaults.set(true, forKey: OnboardingTourStore.cacheKey)
        api.sendHandler = { _ in throw HLError.unknown("offline") }
        let store = makeStore(api: api, defaults: defaults)
        await store.refresh()
        // 08-08 — this case used to assert the opposite of what the Wave-0
        // contract requires, and the two cannot both hold: a legacy install-wide
        // `true` belongs to nobody in particular, so an unresolved lookup may
        // not spend it (`accountSwitchCannotReuseCompletion` is the same inputs
        // asking for the same answer). Nothing is lost — the value is untouched
        // on disk, and the very next resolved lookup uses it.
        #expect(store.isCompleted == false)
        #expect(store.hasLoaded == true) // the question was asked and did not resolve
        #expect(store.resolution == .unavailable)
        #expect(store.evidence == .absent)
        #expect(defaults.object(forKey: OnboardingTourStore.cacheKey) as? Bool == true)
    }

    // MARK: - 08-08: the cache is bound to an account

    @Test("refresh: an unresolved lookup keeps THIS owner's own cached completion")
    func unresolvedLookupKeepsOwnedCompletion() async throws {
        let api = StubAPIClient()
        let defaults = try ephemeralDefaults()
        let owner = PostAuthenticationRouteInput.Owner(id: "owner-a", generation: 3)
        api.sendHandler = { _ in AuthMeOnboarding(onboardingTourCompleted: true) }
        let store = makeStore(api: api, defaults: defaults)
        await store.refresh(owner: owner) // the server answer lands in owner A's scope
        #expect(store.isCompleted == true)

        api.sendHandler = { _ in throw HLError.unknown("offline") }
        await store.refresh(owner: owner)
        #expect(store.resolution == .unavailable)
        #expect(store.evidence == .sameAccount(completed: true))
        #expect(store.isCompleted == true) // same-account evidence IS evidence
    }

    @Test("refresh: another owner's cached completion is never spent on this account")
    func foreignCompletionIsNeverInherited() async throws {
        let api = StubAPIClient()
        let defaults = try ephemeralDefaults()
        let ownerA = PostAuthenticationRouteInput.Owner(id: "owner-a", generation: 1)
        let ownerB = PostAuthenticationRouteInput.Owner(id: "owner-b", generation: 2)
        api.sendHandler = { _ in AuthMeOnboarding(onboardingTourCompleted: true) }
        await makeStore(api: api, defaults: defaults).refresh(owner: ownerA)

        api.sendHandler = { _ in throw HLError.unknown("offline") }
        let storeB = makeStore(api: api, defaults: defaults)
        await storeB.refresh(owner: ownerB)
        #expect(storeB.evidence == .otherAccount(completed: true))
        #expect(storeB.isCompleted == false)
        // …and B's ambiguity does not erase A's answer.
        #expect(defaults.object(forKey: OnboardingTourStore.cacheKey(for: ownerA)) as? Bool == true)
    }

    /// The update path: an install that already holds the pre-Wave-1 unscoped
    /// value. It is accepted (nothing crashes), neutralised (an unresolved
    /// lookup cannot spend it), and never written back as this account's answer
    /// — the first attributed write retires it instead of adopting it.
    @Test("refresh: the legacy install-wide value is retired, not adopted")
    func legacyUnscopedValueIsRetiredNotAdopted() async throws {
        let api = StubAPIClient()
        let defaults = try ephemeralDefaults()
        defaults.set(true, forKey: OnboardingTourStore.cacheKey)
        let owner = PostAuthenticationRouteInput.Owner(id: "owner-a", generation: 1)
        api.sendHandler = { _ in AuthMeOnboarding(onboardingTourCompleted: false) }
        let store = makeStore(api: api, defaults: defaults)
        await store.refresh(owner: owner)

        #expect(store.isCompleted == false) // the server answer wins over a legacy `true`
        #expect(defaults.object(forKey: OnboardingTourStore.cacheKey) == nil) // retired
        #expect(defaults.object(forKey: OnboardingTourStore.cacheKey(for: owner)) as? Bool == false)
    }

    @Test("refresh: a result for a superseded owner is neither published nor returned")
    func supersededOwnerResultIsDropped() async throws {
        let api = StubAPIClient()
        let defaults = try ephemeralDefaults()
        let ownerA = PostAuthenticationRouteInput.Owner(id: "owner-a", generation: 1)
        let ownerB = PostAuthenticationRouteInput.Owner(id: "owner-b", generation: 2)
        let gate = AsyncGate()
        api.sendHandler = { req in
            // Only the `/me` read is held open; the tour write must stay free so
            // the superseding session can complete while the first read hangs.
            // A's answer is deliberately the OPPOSITE of B's, so "it did not
            // land" is observable rather than merely plausible.
            if req is APIRequest<TourUpdateResponse> {
                return TourUpdateResponse(onboardingTourCompleted: true, progress: nil)
            }
            await gate.enter()
            return AuthMeOnboarding(onboardingTourCompleted: false)
        }
        let store = makeStore(api: api, defaults: defaults)
        let inFlight = Task { await store.refresh(owner: ownerA) }
        await gate.waitUntilEntered()
        // A different account is admitted while the first lookup is suspended.
        await store.markCompleted(owner: ownerB)
        await gate.open()
        await inFlight.value

        // A's answer must neither overwrite B's state nor reach A's own scope:
        // by the time it arrived, nobody was asking on A's behalf.
        #expect(store.resolution == .completed)
        #expect(store.isCompleted == true)
        #expect(defaults.object(forKey: OnboardingTourStore.cacheKey(for: ownerA)) == nil)
        #expect(defaults.object(forKey: OnboardingTourStore.cacheKey(for: ownerB)) as? Bool == true)
    }

    @Test("clearOnLogout: sweeps every owner's scope, not just the current one")
    func clearOnLogoutSweepsEveryScope() async throws {
        let api = StubAPIClient()
        let defaults = try ephemeralDefaults()
        let ownerA = PostAuthenticationRouteInput.Owner(id: "owner-a", generation: 1)
        let ownerB = PostAuthenticationRouteInput.Owner(id: "owner-b", generation: 2)
        defaults.set(true, forKey: OnboardingTourStore.cacheKey)
        api.sendHandler = { _ in AuthMeOnboarding(onboardingTourCompleted: true) }
        let store = makeStore(api: api, defaults: defaults)
        await store.refresh(owner: ownerA)
        await store.refresh(owner: ownerB)

        store.clearOnLogout()
        #expect(defaults.object(forKey: OnboardingTourStore.cacheKey) == nil)
        #expect(defaults.object(forKey: OnboardingTourStore.cacheKey(for: ownerA)) == nil)
        #expect(defaults.object(forKey: OnboardingTourStore.cacheKey(for: ownerB)) == nil)
        #expect(store.resolution == nil)
        #expect(store.hasLoaded == false)
    }

    /// Lets a case observe the store while the repository call is suspended.
    private actor AsyncGate {
        private var enteredContinuation: CheckedContinuation<Void, Never>?
        private var releaseContinuation: CheckedContinuation<Void, Never>?
        private var hasEntered = false
        private var isReleased = false

        func waitUntilEntered() async {
            if hasEntered { return }
            await withCheckedContinuation { enteredContinuation = $0 }
        }

        func enter() async {
            hasEntered = true
            enteredContinuation?.resume()
            enteredContinuation = nil
            if isReleased { return }
            await withCheckedContinuation { releaseContinuation = $0 }
        }

        func open() {
            isReleased = true
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    @Test("clearOnLogout: resets flag + wipes local cache")
    func clearOnLogoutWipes() async throws {
        let api = StubAPIClient()
        let defaults = try ephemeralDefaults()
        api.sendHandler = { _ in AuthMeOnboarding(onboardingTourCompleted: true) }
        let store = makeStore(api: api, defaults: defaults)
        await store.refresh()
        #expect(store.isCompleted == true)
        store.clearOnLogout()
        #expect(store.isCompleted == false)
        #expect(store.hasLoaded == false)
        #expect(defaults.object(forKey: OnboardingTourStore.cacheKey) == nil)
    }
}
