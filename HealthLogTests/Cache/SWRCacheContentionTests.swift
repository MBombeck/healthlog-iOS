import Foundation
@testable import HealthLog
import SwiftData
import Testing

// MARK: - The gate

/// A gate a `Decodable` initializer can block on, carried as a `@TaskLocal` so
/// two concurrently-decoding tasks cannot see each other's gate.
///
/// Synchronous by necessity and by intent: `Decodable.init(from:)` cannot
/// `await`, and a decode is synchronous work. This *is* a slow decode — the
/// 77 KB medications list at the head of a foreground fan-out — with the
/// duration made controllable instead of merely large, so the witness below is
/// a statement about ordering rather than a race against a stopwatch.
///
/// The production decoder is untouched. Nothing here exists outside the test
/// target.
final class SWRDecodeGate: @unchecked Sendable {
    /// Set inside the task whose decode should block. Task-locals follow the
    /// task across an actor hop, so this is visible inside `SWRCache`'s
    /// `@ModelActor` methods today and inside whatever executor the decode
    /// runs on after 21-02 — which is exactly why the witness survives the
    /// change it exists to demand.
    @TaskLocal static var current: SWRDecodeGate?

    private let lock = NSLock()
    private var hasEntered = false
    private let released = DispatchSemaphore(value: 0)

    /// Called from `Decodable.init`. Announces arrival, then blocks until
    /// ``open()``. The 10-second ceiling means a mis-wired test fails; it never
    /// hangs the suite. `wait` is legal here and only here: this function is
    /// synchronous, which is the whole point of it.
    func enterAndWait() {
        lock.lock()
        hasEntered = true
        lock.unlock()
        _ = released.wait(timeout: .now() + 10)
    }

    private var entered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasEntered
    }

    /// Polls for arrival without blocking a cooperative thread of its own.
    func waitUntilEntered(within timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if entered { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }

    func open() {
        released.signal()
    }
}

/// A payload whose decode parks on the task-local gate.
struct GatedPayload: Codable, Equatable {
    let id: String

    init(id: String) {
        self.id = id
    }

    enum CodingKeys: String, CodingKey {
        case id
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        SWRDecodeGate.current?.enterAndWait()
    }
}

/// The other key's payload — small, ordinary, and with no gate anywhere near it.
struct UngatedPayload: Codable, Equatable {
    let id: String
}

/// Records whether a first paint landed, and when.
actor FirstPaintWitness {
    private(set) var landed = false

    func mark() {
        landed = true
    }
}

/// Deterministic reachability stub. Offline **with** a cached row is the one
/// ladder arm that emits `.cached` and finishes without touching the network,
/// so every number these suites produce is the cache path and nothing else.
final class OfflineReachability: ReachabilityProviding, @unchecked Sendable {
    var isOnlineStream: AsyncStream<Bool> {
        get async {
            AsyncStream { continuation in
                continuation.yield(false)
                continuation.finish()
            }
        }
    }

    func isCurrentlyOnline() async -> Bool {
        false
    }
}

// MARK: - The witness

/// **Phase 21 (21-01) — the concurrency witness.**
///
/// R3 is "alles unterhalb der Medikamente lädt Sekunden bis Minuten", and the
/// structural cause that survived measurement is `SWRCache` (`:13-14`): a
/// `@ModelActor` whose `read` performs a synchronous `modelContext.fetch`
/// **plus a full `JSONDecoder.decode` while holding the actor's serial
/// executor**. Every SWR-backed surface awaits `cache.read` before it can
/// yield `.cached` or `.empty`, so every surface's first paint queues behind
/// every other surface's decode.
///
/// This suite states that as an ordering property of the **shipped** API —
/// `SWRCoordinator.observe`, which 21-02 does not change the signature of — so
/// it compiles unmodified before and after and changes verdict on behaviour
/// alone. It is RED on landing and 21-02 is the plan that turns it green.
///
/// It is also the guard on the fix's one fragile assumption. 21-02 works
/// because a `nonisolated async` function runs on the generic executor
/// (SE-0338) rather than inheriting its caller's actor. Enabling
/// `NonisolatedNonsendingByDefault`, or adding `nonisolated(nonsending)` to
/// the decode hop, would silently reinstate the serialization this suite
/// exists to forbid — and would turn this test red the moment it happened.
@Suite("SWRCache — one key's decode must not hold another key's first paint")
struct SWRCacheContentionTests {
    @Test("Ein langsamer Decode eines Keys hält den First Paint eines anderen Keys auf")
    func slowDecodeOfOneKeyMustNotDelayAnotherKeysFirstPaint() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        try await cache.write(
            .medicationsList,
            payload: JSONEncoder.hlDefault.encode(GatedPayload(id: "slow"))
        )
        try await cache.write(
            .userProfile,
            payload: JSONEncoder.hlDefault.encode(UngatedPayload(id: "fast"))
        )
        let coordinator = SWRCoordinator(cache: cache, reachability: OfflineReachability())

        // Key A enters its decode and stays there.
        let gate = SWRDecodeGate()
        let slow = Task {
            await SWRDecodeGate.$current.withValue(gate) {
                let stream = await coordinator.observe(.medicationsList, decoding: GatedPayload.self) {
                    GatedPayload(id: "unreachable-offline")
                }
                for await _ in stream {}
            }
        }
        #expect(
            await gate.waitUntilEntered(within: .seconds(5)),
            "the gated decode never started, so this run would prove nothing either way"
        )

        // Key B: a different key, a small payload, and no gate on its task at
        // all. Nothing about B's own work can take 750 ms — a cached read of a
        // ~20-byte row is microseconds — so if B has not painted by then, it
        // is waiting on A and on nothing else.
        let witness = FirstPaintWitness()
        let fast = Task {
            let stream = await coordinator.observe(.userProfile, decoding: UngatedPayload.self) {
                UngatedPayload(id: "unreachable-offline")
            }
            for await state in stream {
                if case .cached = state {
                    await witness.mark()
                    break
                }
            }
        }
        try await Task.sleep(for: .milliseconds(750))
        let paintedWhileTheOtherKeyWasBlocked = await witness.landed

        gate.open()
        _ = await fast.value
        _ = await slow.value

        #expect(
            paintedWhileTheOtherKeyWasBlocked,
            """
            EXPECTED_RED: R3 — the second key's first paint waited for the first key's decode. \
            SWRCache.read decodes on the @ModelActor's serial executor, so every SWR-backed \
            surface queues behind every other surface's decode.
            """
        )
    }
}
