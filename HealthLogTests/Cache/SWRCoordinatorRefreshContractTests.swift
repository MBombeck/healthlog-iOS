import Foundation
@testable import HealthLog
import SwiftData
import Testing

/// **Phase 21 (21-03) — the refresh contract, stated as transport counts and
/// wall-clock bounds (D-14-06-C).**
///
/// 14-06 measured the mechanism behind *"das Runterziehen bringt keine Lösung
/// … ich habe gewartet"*: `SWRCoordinator.revalidateSingleFlight` collapses
/// concurrent callers for one key onto an unstructured winner `Task`. A
/// cancelled foreground pass does not cancel the fetch it started, so a pull
/// arriving while that fetch flies issues **no request of its own** — it
/// inherits the winner's full latency with no timeout. On a slow request that
/// is indistinguishable, from the user's side, from a pull that did nothing.
///
/// The `fetch` closure IS the transport here, which is why these tests need no
/// HTTP: what is under test is the sharing contract, and the sharing contract
/// is decided before a socket is opened. Counting closure invocations is the
/// same witness 14-06 used at the URL-protocol level, one layer in.
///
/// **The two pins are as load-bearing as the two REDs.** A bounded pull is
/// worth nothing if it was bought by breaking the collapse that keeps N
/// background revalidations to one round-trip, and this suite would not notice
/// that unless it asserted it.
@Suite("SWRCoordinator refresh contract (D-14-06-C)", .serialized)
struct SWRCoordinatorRefreshContractTests {
    struct Payload: Codable, Equatable {
        let id: String
    }

    final class OnlineReachability: ReachabilityProviding, @unchecked Sendable {
        var isOnlineStream: AsyncStream<Bool> {
            get async {
                AsyncStream { continuation in
                    continuation.yield(true)
                    continuation.finish()
                }
            }
        }

        func isCurrentlyOnline() async -> Bool {
            true
        }
    }

    /// Counts fetch invocations and reports when the first one started, so a
    /// test can be sure the winner is genuinely in flight before it races it.
    final class Transport: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var started = false

        func begin() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            started = true
        }

        var requests: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        /// Synchronous by necessity: `NSLock` is unavailable from an async
        /// context, so the poll loop below reads through this instead.
        var hasStarted: Bool {
            lock.lock()
            defer { lock.unlock() }
            return started
        }

        func waitUntilFirstRequestStarted(within timeout: Duration) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if hasStarted { return true }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return false
        }
    }

    /// A winner slow enough that the bound expires long before it lands.
    static let slowWinner: Duration = .seconds(4)

    static func millis(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    static func makeCoordinator(warm: Bool) throws -> SWRCoordinator {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        return SWRCoordinator(cache: cache, reachability: OnlineReachability())
    }

    /// Seeds `key` so the walk runs from a **warm** store — the state a real
    /// device is in. A cold fixture would exercise the `.empty` arm, which is
    /// not the arm the operator's pull takes.
    static func seed(_ cache: SWRCache, key: CacheKey, id: String) async throws {
        try await cache.write(key, payload: JSONEncoder.hlDefault.encode(Payload(id: id)))
    }

    /// Starts a `.system` revalidation that will be in flight for
    /// ``slowWinner``, and returns once its fetch has genuinely begun.
    static func startSlowWinner(
        on coordinator: SWRCoordinator,
        key: CacheKey,
        transport: Transport
    ) async -> Task<Void, Never> {
        let winner = Task {
            let stream = await coordinator.observe(
                key,
                decoding: Payload.self,
                forceRevalidate: true,
                intent: .system,
                fetch: {
                    transport.begin()
                    try await Task.sleep(for: slowWinner)
                    return Payload(id: "winner")
                }
            )
            for await _ in stream {}
        }
        _ = await transport.waitUntilFirstRequestStarted(within: .seconds(5))
        return winner
    }

    // MARK: - RED 1 — the bound

    @Test("Ein user-initiierter Refresh veröffentlicht innerhalb der Schranke, nicht erst wenn der Winner landet")
    func userInitiatedRefreshPublishesWithinTheBound() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        try await Self.seed(cache, key: .healthScore, id: "warm")
        let coordinator = SWRCoordinator(cache: cache, reachability: Self.OnlineReachability())
        let transport = Self.Transport()
        let winner = await Self.startSlowWinner(on: coordinator, key: .healthScore, transport: transport)

        let clock = ContinuousClock()
        let start = clock.now
        var published: String?
        let stream = await coordinator.observe(
            .healthScore,
            decoding: Self.Payload.self,
            forceRevalidate: true,
            intent: .userInitiated,
            fetch: {
                transport.begin()
                return Self.Payload(id: "pull")
            }
        )
        for await state in stream {
            if case let .fresh(value) = state {
                published = value.id
                break
            }
        }
        let elapsed = clock.now - start
        winner.cancel()

        #expect(published != nil, "the pull published nothing at all")
        #expect(
            elapsed < SWRCoordinator.userInitiatedAttachBound + .seconds(1),
            """
            EXPECTED_RED: D-14-06-C — a user-initiated refresh inherited the in-flight winner's \
            full latency with no bound of its own. It published after \
            \(String(format: "%.0f", Self.millis(elapsed))) ms against a bound of \
            \(String(format: "%.0f", Self.millis(SWRCoordinator.userInitiatedAttachBound))) ms.
            """
        )
    }

    // MARK: - RED 2 — the transport count

    @Test("Ein user-initiierter Refresh stellt nach der Schranke einen eigenen Request")
    func userInitiatedRefreshIssuesItsOwnRequestAfterTheBound() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        try await Self.seed(cache, key: .insightsCards, id: "warm")
        let coordinator = SWRCoordinator(cache: cache, reachability: Self.OnlineReachability())
        let transport = Self.Transport()
        let winner = await Self.startSlowWinner(on: coordinator, key: .insightsCards, transport: transport)

        let stream = await coordinator.observe(
            .insightsCards,
            decoding: Self.Payload.self,
            forceRevalidate: true,
            intent: .userInitiated,
            fetch: {
                transport.begin()
                return Self.Payload(id: "pull")
            }
        )
        for await state in stream {
            if case .fresh = state { break }
        }
        let seen = transport.requests
        winner.cancel()

        #expect(
            seen == 2,
            """
            EXPECTED_RED: D-14-06-C — the transport saw \(seen) request(s), not 2. \
            One request served two loads: the pull attached to the winner instead of issuing \
            its own, which is what makes a pull on a slow key indistinguishable from a pull \
            that did nothing.
            """
        )
    }

    // MARK: - PIN 1 — the collapse survives for system callers

    @Test("PIN: Ein System-Caller hängt sich weiterhin an — genau ein Request für zwei Loads")
    func systemCallerStillAttachesToTheWinner() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        try await Self.seed(cache, key: .correlations, id: "warm")
        let coordinator = SWRCoordinator(cache: cache, reachability: Self.OnlineReachability())
        let transport = Self.Transport()

        // A winner short enough that a `.system` waiter attaching for its whole
        // duration is still a fast test — the point is the COUNT, not the wait.
        let winner = Task {
            let stream = await coordinator.observe(
                .correlations,
                decoding: Self.Payload.self,
                forceRevalidate: true,
                intent: .system,
                fetch: {
                    transport.begin()
                    try await Task.sleep(for: .milliseconds(600))
                    return Self.Payload(id: "winner")
                }
            )
            for await _ in stream {}
        }
        _ = await transport.waitUntilFirstRequestStarted(within: .seconds(5))

        var published: String?
        let stream = await coordinator.observe(
            .correlations,
            decoding: Self.Payload.self,
            forceRevalidate: true,
            intent: .system,
            fetch: {
                transport.begin()
                return Self.Payload(id: "second-system-caller")
            }
        )
        for await state in stream {
            if case let .fresh(value) = state {
                published = value.id
                break
            }
        }
        await winner.value

        #expect(transport.requests == 1, "the single-flight collapse must survive for system callers")
        #expect(published == "winner", "the attaching caller must receive the winner's value, not its own")
    }

    // MARK: - PIN 2 — the warm-store shape, which is the shape a device is in

    @Test("PIN: Der Pull-während-Winner-Walk aus einem warmen Store emittiert erst cached, dann fresh")
    func theWalkFromAWarmStoreEmitsCachedThenFresh() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        try await Self.seed(cache, key: .insightsTargets, id: "warm")
        let coordinator = SWRCoordinator(cache: cache, reachability: Self.OnlineReachability())
        let transport = Self.Transport()
        let winner = await Self.startSlowWinner(on: coordinator, key: .insightsTargets, transport: transport)

        var sequence: [String] = []
        let stream = await coordinator.observe(
            .insightsTargets,
            decoding: Self.Payload.self,
            forceRevalidate: true,
            intent: .userInitiated,
            fetch: {
                transport.begin()
                return Self.Payload(id: "pull")
            }
        )
        for await state in stream {
            switch state {
            case .empty: sequence.append("empty")
            case let .cached(value, _): sequence.append("cached(\(value.id))")
            case let .fresh(value): sequence.append("fresh(\(value.id))")
            case .failed: sequence.append("failed")
            }
            if sequence.count == 2 { break }
        }
        winner.cancel()

        // A warm store paints from cache FIRST and only then replaces it. If a
        // bounded pull had cost the user their instant repaint, this is where
        // it would show, and it is the arm a real device takes — not the cold
        // `.empty` arm the other fixtures exercise.
        //
        // Deliberately a SHAPE assertion and not a value one. Which value wins
        // the `.fresh` — the winner's, if it lands inside the bound, or the
        // pull's own, if it does not — is the coordinator's contract and the
        // two REDs above own it. Asserting `fresh(pull)` here would have made
        // this a third RED wearing a pin's name, which is precisely the
        // laundering this phase refuses elsewhere. It is green before the
        // change and green after, and that is what a pin is for.
        #expect(sequence.count == 2, "the warm-store ladder must emit exactly two states, got \(sequence)")
        #expect(sequence.first == "cached(warm)", "a warm store must repaint from cache first, got \(sequence)")
        #expect(
            sequence.last?.hasPrefix("fresh(") == true,
            "and must then replace it with a fresh value, got \(sequence)"
        )
    }
}
