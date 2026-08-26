import Foundation
@testable import HealthLog
import Testing

/// Phase 08 Wave 0 — the returning-login matrix.
///
/// A returning user who finished setup does not walk it again; a user whose
/// completion could not be looked up is asked again rather than replayed
/// through the wizard; and one account's answer is never spent on another's
/// session. The routing itself is Wave 1's work — these cases freeze what it
/// has to come out as, and prove that today nothing decides anything: all four
/// sign-in methods land on the same phase, and the single surface that reacts
/// to that phase enters setup unconditionally.
///
/// Source contracts read comment-stripped source — a doc comment naming a
/// symbol is not the symbol.
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
        let flow = try Self.strippedSource("HealthLog/Screens/Onboarding/OnboardingFlow.swift")
        if flow.contains("case .authenticating"), flow.contains("step = .healthKit"),
           !flow.contains("PostAuthenticationRoute")
        {
            violations.append("the only post-authentication transition enters setup without consulting completion")
        }
        let methods = try Self.authenticatingTransitionCount()
        #expect(methods >= 4, "every sign-in method must still land on one shared phase")
        try violations.append(contentsOf: Self.unwiredRouteViolations())

        #expect(violations.isEmpty, "EXPECTED_RED: 08-01 route completed returning user replayed optional setup")
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
        let source = try Self.strippedSource("HealthLog/Stores/OnboardingTourStore.swift")
        if source.contains("defaults.bool(forKey: Self.cacheKey)") {
            violations.append("the completion cache is read as one global bool with no owner in the key")
        }
        #expect(Self.route(server: .unavailable, cache: .otherAccount(completed: true)) == .retryCompletionLookup)

        #expect(violations.isEmpty, "EXPECTED_RED: 08-01 route account B reused account A completion")
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
        try violations.append(contentsOf: Self.ambiguityViolations())
        #expect(Self.route(server: .unavailable, cache: .absent) == .retryCompletionLookup)

        #expect(violations.isEmpty, "EXPECTED_RED: 08-01 route ambiguous completion lookup replayed setup")
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

    // MARK: - Production wiring

    /// How many production sign-in legs land on the one shared authenticated
    /// phase. Four methods, at least four transitions; the MFA legs add more.
    ///
    /// Retargeted by 09-07, which did not change this contract but did change
    /// where it is written. The legs used to each carry their own
    /// `phase = .authenticating(session.user)`; they now all call the single
    /// fenced `acceptSession(_:for:)`, which performs that one assignment in
    /// `AuthStore+Phase.swift`. Counting the call sites keeps the clause exactly
    /// as strong — "every sign-in method still lands on one shared phase" — over
    /// a codebase where the phase is now shared by construction rather than by
    /// repetition.
    private static func authenticatingTransitionCount() throws -> Int {
        let auth = try strippedSource("HealthLog/Stores/AuthStore.swift")
        return auth.components(separatedBy: "acceptSession(session, for:").count - 1
    }

    private static func unwiredRouteViolations() throws -> [String] {
        var violations: [String] = []
        if try !namesSymbol("PostAuthenticationRoute", excluding: contractPath) {
            violations.append("no production surface resolves a post-authentication route")
        }
        if try !consultsCompletion(".isCompleted") {
            violations.append("the server-owned completion flag has no production consumer")
        }
        return violations
    }

    private static func ambiguityViolations() throws -> [String] {
        var violations: [String] = []
        if try !namesSymbol("retryCompletionLookup", excluding: contractPath) {
            violations.append("network ambiguity has no representation on any production route")
        }
        if try !consultsCompletion(".hasLoaded") {
            violations.append("no production surface distinguishes an unresolved lookup from an incomplete one")
        }
        return violations
    }

    private static let contractPath = "HealthLog/Stores/PostAuthenticationRouteResolver.swift"
    private static let storePath = "HealthLog/Stores/OnboardingTourStore.swift"

    /// True when a production file that already knows about the onboarding
    /// tour also reads `member` off it.
    private static func consultsCompletion(_ member: String) throws -> Bool {
        try productionSources().contains { path, source in
            path != storePath && source.contains("onboardingTour") && source.contains(member)
        }
    }

    private static func namesSymbol(_ symbol: String, excluding excluded: String) throws -> Bool {
        try productionSources().contains { path, source in
            path != excluded && source.contains(symbol)
        }
    }

    // MARK: - Source access

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func productionSources() throws -> [(String, String)] {
        let base = root.appendingPathComponent("HealthLog")
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
            return []
        }
        var sources: [(String, String)] = []
        for case let file as URL in walker where file.pathExtension == "swift" {
            let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            sources.append((relative, strippingComments(text)))
        }
        return sources
    }

    private static func strippedSource(_ relativePath: String) throws -> String {
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        return strippingComments(text)
    }

    private static func strippingComments(_ source: String) -> String {
        stripLineComments(from: stripBlockComments(from: source))
    }

    private static func stripBlockComments(from source: String) -> String {
        var out = ""
        var rest = Substring(source)
        while let open = rest.range(of: "/*") {
            out += rest[..<open.lowerBound]
            guard let close = rest.range(of: "*/", range: open.upperBound ..< rest.endIndex) else { return out }
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    private static func stripLineComments(from source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var quoted = false
            var previous: Character = " "
            for (offset, character) in line.enumerated() {
                if character == "\"", previous != "\\" { quoted.toggle() }
                if !quoted, character == "/", previous == "/" { return String(line.prefix(offset - 1)) }
                previous = character
            }
            return String(line)
        }.joined(separator: "\n")
    }
}
