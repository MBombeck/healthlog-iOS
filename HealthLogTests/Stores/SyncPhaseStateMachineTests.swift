import Foundation
@testable import HealthLog
import Synchronization
import Testing

// swiftlint:disable force_unwrapping

/// b178 W-SYNCVIS — locks the perceivable handshake-phase machine on
/// `SyncStateStore` (`SyncPhase`: `.idle → .syncing → .done → .idle`):
///
/// - every `handshake()` enters `.syncing` and HOLDS it for at least the
///   minimum beat, even when the GET returns instantly (the RCA: on fast
///   networks the old `isLoading`-only caption flashed by unseen),
/// - success then shows `.done` ("Daten übermittelt ✓") for the done-hold —
///   ALSO for read-only handshakes — before decaying to `.idle`,
/// - errors drop straight to `.idle` (no minimum hold, no fake confirmation),
/// - overlapping handshakes are generation-guarded: a stale `.done`-decay
///   never clobbers a newer run, and logout resets the machine.
///
/// All timing runs against the manual `SyncPhaseTestClock` below (Mutex-backed,
/// `Synchronization`, iOS 18) — zero wall-time sleeps in the assertions.
@MainActor
@Suite("SyncStateStore — handshake phase machine", .serialized)
struct SyncPhaseStateMachineTests {
    private func makeStore(
        clock: SyncPhaseTestClock,
        minimumSyncingHold: Duration = .milliseconds(600),
        doneHold: Duration = .seconds(1.5)
    ) -> SyncStateStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.8",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        return SyncStateStore(
            repo: SyncStateRepository(api: api),
            clock: clock,
            minimumSyncingHold: minimumSyncingHold,
            doneHold: doneHold
        )
    }

    private func stubSuccess() {
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{
              "userId":"usr_phase","timezone":"Europe/Berlin",
              "lastSyncedAt":"2026-06-11T08:00:00Z",
              "serverNow":"2026-06-11T08:00:01Z",
              "measurements":{"lastUpdatedAt":"2026-06-11T08:00:00Z","liveCount":5,"tombstonedCount":0}
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
    }

    private func stubFailure() {
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
    }

    /// Polls `condition` on the main actor until it holds or `timeout` passes.
    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: - Minimum visibility beat

    @Test("read-only handshake holds .syncing for the minimum beat, then shows .done")
    func minimumBeatThenDone() async {
        let clock = SyncPhaseTestClock()
        let store = makeStore(clock: clock)
        stubSuccess()

        let run = Task { await store.handshake() }
        #expect(await waitUntil { store.phase == .syncing }, "handshake must enter .syncing")

        // The GET against the mock returns near-instantly — without advancing
        // the stub clock the phase must STAY .syncing (minimum visibility).
        #expect(await waitUntil { clock.sleeperCount >= 1 }, "minimum beat must register on the clock")
        try? await Task.sleep(for: .milliseconds(80))
        #expect(store.phase == .syncing, "phase must hold .syncing until the minimum beat elapses")
        #expect(store.isLoading, "isLoading must span the held beat")

        clock.advance(by: .milliseconds(600))
        await run.value
        #expect(store.phase == .done, "a successful READ-ONLY handshake must still confirm with .done")
        #expect(store.lastHandshakeAt != nil)
        #expect(!store.isLoading)
    }

    @Test(".done decays to .idle after the done-hold")
    func doneDecaysToIdle() async {
        let clock = SyncPhaseTestClock()
        let store = makeStore(clock: clock)
        stubSuccess()

        let run = Task { await store.handshake() }
        #expect(await waitUntil { clock.sleeperCount >= 1 })
        clock.advance(by: .milliseconds(600))
        await run.value
        #expect(store.phase == .done)

        // The decay task registers its own sleeper — only then advance.
        #expect(await waitUntil { clock.sleeperCount >= 1 }, "done-decay must register on the clock")
        clock.advance(by: .seconds(1.5))
        #expect(await waitUntil { store.phase == .idle }, ".done must decay to .idle after the hold")
    }

    // MARK: - Error path

    @Test("a failing handshake drops straight to .idle — no hold, no .done")
    func errorGoesDirectlyIdle() async {
        let clock = SyncPhaseTestClock()
        let store = makeStore(clock: clock)
        stubFailure()

        // No clock.advance at all: the error path must not wait for the
        // minimum beat (the async-let beat is cancelled on scope exit).
        await store.handshake()
        #expect(store.phase == .idle, "errors must short-circuit to .idle")
        #expect(store.error != nil)
        #expect(!store.isLoading)
    }

    // MARK: - Overlap + reset

    @Test("a new handshake cancels the stale done-decay (generation guard)")
    func overlappingHandshakeKeepsNewPhase() async {
        let clock = SyncPhaseTestClock()
        let store = makeStore(clock: clock)
        stubSuccess()

        // First handshake → .done (decay pending at +1.5 s).
        let first = Task { await store.handshake() }
        #expect(await waitUntil { clock.sleeperCount >= 1 })
        clock.advance(by: .milliseconds(600))
        await first.value
        #expect(store.phase == .done)
        #expect(await waitUntil { clock.sleeperCount >= 1 })

        // Second handshake starts while the first decay is still pending.
        let second = Task { await store.handshake() }
        #expect(await waitUntil { store.phase == .syncing })

        // Advance PAST the stale decay deadline AND the new minimum beat:
        // the stale decay must not flip the fresh run's outcome to .idle.
        #expect(await waitUntil { clock.sleeperCount >= 1 })
        clock.advance(by: .seconds(2))
        await second.value
        #expect(store.phase == .done, "stale decay must not clobber the newer handshake's .done")
    }

    @Test("clearOnLogout resets the phase machine")
    func logoutResetsPhase() async {
        let clock = SyncPhaseTestClock()
        let store = makeStore(clock: clock)
        stubSuccess()

        let run = Task { await store.handshake() }
        #expect(await waitUntil { clock.sleeperCount >= 1 })
        clock.advance(by: .milliseconds(600))
        await run.value
        #expect(store.phase == .done)

        store.clearOnLogout()
        #expect(store.phase == .idle)
        #expect(store.lastHandshakeAt == nil)

        // Firing the (cancelled + generation-stale) decay must be a no-op.
        clock.advance(by: .seconds(5))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(store.phase == .idle)
    }
}

// MARK: - SyncPhaseTestClock

/// Manual-advance `Clock<Duration>` for deterministic phase-machine tests.
/// Mutex-backed (`Synchronization`, iOS 18) — no actors, so `advance` is a
/// plain synchronous call from the test. Cancellation-aware: a cancelled
/// sleeper resumes immediately with `CancellationError` (this is what lets
/// the store's error path exit without ever advancing the clock).
final class SyncPhaseTestClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let id: UInt64
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID: UInt64 = 0
        var sleepers: [Sleeper] = []
    }

    private let state = Mutex(State())

    var now: Instant {
        state.withLock { $0.now }
    }

    var minimumResolution: Duration {
        .zero
    }

    /// Number of currently parked sleepers — the tests' "did the hold
    /// register yet?" synchronization point before advancing.
    var sleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }

    func sleep(until deadline: Instant, tolerance _: Duration?) async throws {
        let id: UInt64 = state.withLock { s in
            defer { s.nextID += 1 }
            return s.nextID
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                let resumeNow: Bool = state.withLock { s in
                    if deadline <= s.now { return true }
                    s.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: cont))
                    return false
                }
                if resumeNow { cont.resume() }
            }
        } onCancel: {
            let cancelled: CheckedContinuation<Void, any Error>? = state.withLock { s in
                guard let idx = s.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return s.sleepers.remove(at: idx).continuation
            }
            cancelled?.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock forward and resumes every sleeper whose deadline is
    /// now due (outside the lock, in deadline order).
    func advance(by duration: Duration) {
        let due: [Sleeper] = state.withLock { s in
            s.now = s.now.advanced(by: duration)
            let now = s.now
            let fired = s.sleepers.filter { $0.deadline <= now }
            s.sleepers.removeAll { $0.deadline <= now }
            return fired.sorted { $0.deadline < $1.deadline }
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }
}

// swiftlint:enable force_unwrapping
