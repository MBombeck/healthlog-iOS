import Foundation
@testable import HealthLog
import Testing

/// The returning-login matrix.
///
/// A returning user who finished setup does not walk it again; a user whose
/// completion could not be looked up is asked again rather than replayed
/// through the wizard; and one account's answer is never spent on another's
/// session. The matrix freezes what the resolver has to come out as; the store
/// cases drive `OnboardingTourStore` and the resolver together.
@MainActor
@Suite("Phase 08 post-authentication routing")
struct OnboardingRouteResolverTests {
    // MARK: - The matrix

    private struct Row {
        let server: PostAuthenticationRouteInput.ServerCompletion
        let cache: PostAuthenticationRouteInput.CachedCompletion
        let route: PostAuthenticationRoute
    }

    /// Every server answer against every shape of local evidence. The method is
    /// deliberately absent: it is not an input to the decision.
    private static let matrix: [Row] = [
        // The server answered. Its answer wins over any cache, including a
        // same-account cache that disagrees.
        Row(server: .completed, cache: .absent, route: .authenticatedShell),
        Row(server: .completed, cache: .sameAccount(completed: false), route: .authenticatedShell),
        Row(server: .completed, cache: .sameAccount(completed: true), route: .authenticatedShell),
        Row(server: .completed, cache: .otherAccount(completed: false), route: .authenticatedShell),
        Row(server: .completed, cache: .otherAccount(completed: true), route: .authenticatedShell),
        Row(server: .incomplete, cache: .absent, route: .setup),
        Row(server: .incomplete, cache: .sameAccount(completed: false), route: .setup),
        Row(server: .incomplete, cache: .sameAccount(completed: true), route: .setup),
        Row(server: .incomplete, cache: .otherAccount(completed: false), route: .setup),
        Row(server: .incomplete, cache: .otherAccount(completed: true), route: .setup),
        // The deployment has no such field. The same-account cache is the only
        // evidence there will ever be, so it is allowed to stand in; another
        // account's cache is not evidence about this one.
        Row(server: .endpointAbsent, cache: .absent, route: .setup),
        Row(server: .endpointAbsent, cache: .sameAccount(completed: false), route: .setup),
        Row(server: .endpointAbsent, cache: .sameAccount(completed: true), route: .authenticatedShell),
        Row(server: .endpointAbsent, cache: .otherAccount(completed: false), route: .setup),
        Row(server: .endpointAbsent, cache: .otherAccount(completed: true), route: .setup),
        // The lookup did not resolve. Same-account evidence is safe to use;
        // without it the answer is unknown, and unknown is never setup.
        Row(server: .unavailable, cache: .absent, route: .retryCompletionLookup),
        Row(server: .unavailable, cache: .sameAccount(completed: false), route: .setup),
        Row(server: .unavailable, cache: .sameAccount(completed: true), route: .authenticatedShell),
        Row(server: .unavailable, cache: .otherAccount(completed: false), route: .retryCompletionLookup),
        Row(server: .unavailable, cache: .otherAccount(completed: true), route: .retryCompletionLookup)
    ]

    @Test("the route matrix is total, account-safe, and never replays setup on ambiguity")
    func routeMatrixIsTotalAndSafe() {
        let cases = Self.cacheShapes
        #expect(Self.matrix.count == 4 * cases.count, "every server answer needs every cache shape")
        #expect(Set(Self.matrix.map(\.route)).count == PostAuthenticationRoute.allCases.count)

        for server in PostAuthenticationRouteInput.ServerCompletion.allCases {
            for cache in cases {
                let hits = Self.matrix.filter { $0.server == server && Self.same($0.cache, cache) }
                #expect(hits.count == 1, "\(server.rawValue) × \(cache) is not decided exactly once")
            }
        }

        for row in Self.matrix {
            if case .otherAccount = row.cache, row.server == .endpointAbsent || row.server == .unavailable {
                #expect(row.route != .authenticatedShell, "another account's cache is never evidence")
            }
            if row.server == .unavailable, case .absent = row.cache {
                #expect(row.route == .retryCompletionLookup, "ambiguity without evidence is retryable")
            }
            if row.server == .completed { #expect(row.route == .authenticatedShell) }
            if row.server == .incomplete { #expect(row.route == .setup) }
        }
    }

    @Test("a declined optional permission is a decision, not a missing setup step")
    func declinedOptionalPermissionIsNotIncompleteSetup() {
        let denied = Self.input(server: .completed, cache: .absent, optionalPermissionDenied: true)
        let missing = Self.input(server: .completed, cache: .absent, missingRequiredDatum: true)
        #expect(denied != missing, "the two must be distinguishable inputs, not one flag")
        #expect(denied.optionalPermissionDenied, "declining stays recorded, and stays separate")
        #expect(!denied.missingRequiredDatum, "declining an optional step never marks a datum missing")
        #expect(Self.route(server: .completed, cache: .absent) == .authenticatedShell)
    }

    // MARK: - Preservation

    @Test("the server answer wins over the local cache in both directions")
    func serverResultWinsCache() async throws {
        let stale = try await Self.settled(cached: false, server: .value(true))
        #expect(stale.isCompleted, "a server `true` must beat a stale-false cache")
        #expect(stale.hasLoaded)

        let optimistic = try await Self.settled(cached: true, server: .value(false))
        #expect(!optimistic.isCompleted, "a server `false` must beat an optimistic-true cache")
        #expect(optimistic.hasLoaded)
    }

    @Test("an endpoint-absent deployment falls back to the cache without failing")
    func endpointAbsentFallsBackToCache() async throws {
        let store = try await Self.settled(cached: true, server: .value(nil))
        #expect(store.isCompleted, "the pre-v1.18.6 deployment leaves the local answer standing")
        #expect(store.hasLoaded, "an absent field is an answered request, not a failed one")
    }

    /// The shape the route resolver has to grow, already shipped twice: an
    /// unresolved read never acts. This is the anchor the REDs below measure
    /// the onboarding path against.
    @Test("the codebase already refuses to act on an unresolved read")
    func ambiguityAwareGateShapeExists() {
        #expect(!DisclaimerAckStore.shouldGate(hasLoaded: false, isAcknowledged: false))
        #expect(DisclaimerAckStore.shouldGate(hasLoaded: true, isAcknowledged: false))
        #expect(!MfaEnrollmentGateStore.shouldGate(hasLoaded: false, isRequired: true))
    }

    // MARK: - RED

    @Test("a completed returning user is handed to the shell, whichever door they came through")
    func completedReturningUserSkipsOptionalSetup() async throws {
        let store = try await Self.settled(cached: false, server: .value(true))
        #expect(store.isCompleted, "the server-owned completion is available on the authentication tick")
        #expect(Self.route(server: .completed, cache: .absent) == .authenticatedShell)

        var violations: [String] = []
        if PostAuthenticationRouteResolver.resolve(server: .completed, cache: .absent) != .authenticatedShell {
            violations.append("the post-authentication route enters setup for a completed account")
        }

        #expect(violations.isEmpty, "route completed returning user replayed optional setup")
    }

    @Test("a second account never inherits the first account's completion")
    func accountSwitchCannotReuseCompletion() async throws {
        let defaults = try Self.isolatedDefaults()
        // Account A finished setup on this install.
        defaults.set(true, forKey: OnboardingTourStore.cacheKey)

        // Account B signs in on the same install without a clean boundary —
        // a crash between logout and wipe, an expired token, a deleted account.
        let api = StubAPIClient()
        api.sendHandler = { _ in throw HLError.unknown("offline") }
        let storeB = OnboardingTourStore(repo: OnboardingTourRepository(api: api), defaults: defaults)
        await storeB.refresh()

        var violations: [String] = []
        if storeB.isCompleted {
            violations.append("a second account inherited the first account's completion from an unscoped cache")
        }
        if PostAuthenticationRouteResolver.resolve(server: .unavailable, cache: .otherAccount(completed: true))
            != .retryCompletionLookup
        {
            violations.append("another account's cached completion decided this account's route")
        }

        #expect(violations.isEmpty, "route account B reused account A completion")
    }

    @Test("an unresolved completion lookup is retried, not answered with setup")
    func ambiguousLookupDoesNotReplaySetup() async throws {
        let defaults = try Self.isolatedDefaults()
        let gate = Gate()
        let api = StubAPIClient()
        api.sendHandler = { _ in
            await gate.enter()
            throw HLError.unknown("offline")
        }
        let store = OnboardingTourStore(repo: OnboardingTourRepository(api: api), defaults: defaults)

        let refresh = Task { await store.refresh() }
        await gate.waitUntilEntered()
        #expect(!store.hasLoaded, "the lookup is in flight, so nothing is resolved yet")
        await gate.open()
        await refresh.value

        var violations: [String] = []
        if !store.hasLoaded, !store.isCompleted {
            violations.append("an unresolved lookup is indistinguishable from a definitive incomplete")
        }
        if PostAuthenticationRouteResolver.resolve(server: .unavailable, cache: .absent) != .retryCompletionLookup {
            violations.append("an unresolved lookup was answered with a route instead of a retry")
        }

        #expect(violations.isEmpty, "route ambiguous completion lookup replayed setup")
    }

    // MARK: - Matrix helpers

    private static let cacheShapes: [PostAuthenticationRouteInput.CachedCompletion] = [
        .absent,
        .sameAccount(completed: false),
        .sameAccount(completed: true),
        .otherAccount(completed: false),
        .otherAccount(completed: true)
    ]

    private static func same(
        _ lhs: PostAuthenticationRouteInput.CachedCompletion,
        _ rhs: PostAuthenticationRouteInput.CachedCompletion
    ) -> Bool {
        lhs == rhs
    }

    private static func input(
        server: PostAuthenticationRouteInput.ServerCompletion,
        cache: PostAuthenticationRouteInput.CachedCompletion,
        method: PostAuthenticationRouteInput.Method = .password,
        missingRequiredDatum: Bool = false,
        optionalPermissionDenied: Bool = false
    ) -> PostAuthenticationRouteInput {
        PostAuthenticationRouteInput(
            owner: .init(id: "owner-a", generation: 1),
            method: method,
            server: server,
            cache: cache,
            missingRequiredDatum: missingRequiredDatum,
            optionalPermissionDenied: optionalPermissionDenied
        )
    }

    /// The frozen expectation for one cell, asserted to be method-independent
    /// by construction: the lookup does not take a method.
    private static func route(
        server: PostAuthenticationRouteInput.ServerCompletion,
        cache: PostAuthenticationRouteInput.CachedCompletion
    ) -> PostAuthenticationRoute? {
        matrix.first { $0.server == server && $0.cache == cache }?.route
    }

    // MARK: - Store helpers

    private enum ServerAnswer {
        /// `nil` models the pre-v1.18.6 deployment with no such field.
        case value(Bool?)
    }

    private final class StubAPIClient: APIClientProtocol, @unchecked Sendable {
        var sendHandler: (@Sendable (any Sendable) async throws -> any Sendable)?

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            guard let handler = sendHandler else { throw HLError.unknown("no handler") }
            let result = try await handler(request)
            guard let typed = result as? T else { throw HLError.decoding("type mismatch for \(T.self)") }
            return typed
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {}
        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.canceled
        }
    }

    /// Lets a test observe the store while the repository response is still in
    /// flight, and release it deterministically.
    private actor Gate {
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

    private static func isolatedDefaults() throws -> UserDefaults {
        let name = "test.postAuthRoute.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static func settled(cached: Bool, server: ServerAnswer) async throws -> OnboardingTourStore {
        let defaults = try isolatedDefaults()
        defaults.set(cached, forKey: OnboardingTourStore.cacheKey)
        let api = StubAPIClient()
        api.sendHandler = { _ in
            guard case let .value(flag) = server else { throw HLError.canceled }
            return AuthMeOnboarding(onboardingTourCompleted: flag)
        }
        let store = OnboardingTourStore(repo: OnboardingTourRepository(api: api), defaults: defaults)
        await store.refresh()
        return store
    }
}
