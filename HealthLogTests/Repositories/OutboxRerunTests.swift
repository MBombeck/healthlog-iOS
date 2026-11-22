import Foundation
@testable import HealthLog
import Synchronization
import Testing

/// Stands in for the wait before a self-armed pass. It notes how long the
/// service wanted to wait and moves the injected clock past that point, so the
/// pass that follows sees the back-off as over without any real waiting.
final class RerunSleeper: Sendable {
    private struct State {
        var delays: [TimeInterval] = []
        var stopped = false
    }

    private let state = Mutex(State())
    private let clock: C4Clock
    private let beforeWaking: @Sendable () -> Void

    /// Attempt stamps are taken from the real clock, the pass reads the
    /// injected one. The margin keeps a slow run from landing inside the
    /// back-off it has just waited out.
    private static let margin: TimeInterval = 60

    init(clock: C4Clock, beforeWaking: @escaping @Sendable () -> Void = {}) {
        self.clock = clock
        self.beforeWaking = beforeWaking
    }

    var delays: [TimeInterval] {
        state.withLock { $0.delays }
    }

    /// From now on a wait is noted and then cancelled, so no further pass starts.
    func stop() {
        state.withLock { $0.stopped = true }
    }

    func sleep(_ delay: TimeInterval) async throws {
        let stopped = state.withLock { state in
            state.delays.append(delay)
            return state.stopped
        }
        if stopped { throw CancellationError() }
        beforeWaking()
        clock.advance(by: delay + Self.margin)
    }
}

/// Holds the first pass at its server probe, the first await after it has
/// read the queue and the account, and counts every pass that got that far.
actor RerunPassGate {
    private(set) var passes = 0
    private(set) var isHolding = false
    private var waiter: CheckedContinuation<Void, Never>?

    func probe() async -> Bool {
        passes += 1
        guard passes == 1 else { return false }
        isHolding = true
        await withCheckedContinuation { waiter = $0 }
        return false
    }

    func release() {
        waiter?.resume()
        waiter = nil
    }
}

/// Nothing outside the service starts a pass while the app sits open on a
/// stable connection, and nothing follows a login. These tests check that the
/// queue moves in both cases, and that the service's own wake-ups stay bounded.
@Suite("The replay starts by itself after a back-off and after a sign-in", .serialized, .isolatedSkipRegister, .mockURLSession)
struct OutboxRerunTests {
    private static let backoff: TimeInterval = 300

    private final class Flag: Sendable {
        private let value = Mutex(false)
        var isSet: Bool {
            value.withLock { $0 }
        }

        func set() {
            value.withLock { $0 = true }
        }
    }

    @Test("a dose that met a lost connection goes out when its back-off is over, without any outside trigger")
    func failedWriteIsSentAfterItsBackoff() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { WAFixture.owner })
        try await WAFixture.enqueueIntake(outbox)

        let serverIsBack = Flag()
        let wire = WAWireLog()
        MockURLProtocol.install { req in
            wire.record(req)
            guard serverIsBack.isSet else { throw URLError(.networkConnectionLost) }
            return WAFixture.reply(req, 201, WAFixture.intakeLogged)
        }
        let clock = C4Clock()
        let sleeper = RerunSleeper(clock: clock) { serverIsBack.set() }
        let replay = WAFixture.replay(
            outbox: outbox,
            clock: clock,
            attemptBackoff: Self.backoff,
            rerunSleep: { try await sleeper.sleep($0) }
        )

        await replay.runOnce()
        #expect(await outbox.snapshot.count == 1, "the first pass failed and left the dose queued")

        await waUntil("the self-armed pass delivers the dose") { await outbox.snapshot.isEmpty }
        #expect(sleeper.delays == [Self.backoff], "one wake-up, set to the end of the back-off")
        #expect(wire.all.allSatisfy { $0.key == "wa-intake" }, "every attempt carried the key the dose was queued with")
        #expect(await outbox.deadLetterCount == 0)
    }

    @Test("the wake-ups double their wait, stop after five in a row, and start over on an outside trigger")
    func rerunsAreBoundedAndReset() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { WAFixture.owner })
        try await WAFixture.enqueueIntake(outbox)
        MockURLProtocol.install { _ in throw URLError(.networkConnectionLost) }

        let clock = C4Clock()
        let sleeper = RerunSleeper(clock: clock)
        let replay = WAFixture.replay(
            outbox: outbox,
            clock: clock,
            attemptBackoff: Self.backoff,
            rerunSleep: { try await sleeper.sleep($0) }
        )

        await replay.runOnce()
        await waUntil("five self-armed passes have run") {
            guard sleeper.delays.count == 5 else { return false }
            let streak = await replay.rerun.streak
            let running = await replay.isRunning
            return streak == OutboxReplayService.maxRerunsInARow && !running
        }
        #expect(sleeper.delays == [300, 600, 1200, 2400, 4800])
        #expect(await replay.armedRerun == nil, "after five in a row the service waits for an outside trigger")
        #expect(await outbox.snapshot.count == 1, "the dose is still queued, not dropped")
        #expect(await outbox.deadLetterCount == 0, "a lost connection costs the write nothing of its budget")

        sleeper.stop()
        await replay.runOnce()
        await waUntil("the outside trigger arms a wake-up again") { sleeper.delays.count == 6 }
        #expect(sleeper.delays.last == Self.backoff, "the count starts over, and so does the wait")
    }

    @Test("a service that was given no way to wait arms nothing")
    func noSleeperNoRerun() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { WAFixture.owner })
        try await WAFixture.enqueueIntake(outbox)
        MockURLProtocol.install { _ in throw URLError(.networkConnectionLost) }

        let replay = WAFixture.replay(outbox: outbox, attemptBackoff: Self.backoff)
        await replay.runOnce()

        #expect(await replay.armedRerun == nil)
        #expect(await outbox.snapshot.count == 1)
    }

    @Test("a pass that delivered everything arms nothing")
    func nothingWaitingNoRerun() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { WAFixture.owner })
        try await WAFixture.enqueueIntake(outbox)
        MockURLProtocol.install { req in WAFixture.reply(req, 201, WAFixture.intakeLogged) }

        let clock = C4Clock()
        let sleeper = RerunSleeper(clock: clock)
        let replay = WAFixture.replay(
            outbox: outbox,
            clock: clock,
            attemptBackoff: Self.backoff,
            rerunSleep: { try await sleeper.sleep($0) }
        )
        await replay.runOnce()

        #expect(await outbox.snapshot.isEmpty)
        #expect(await replay.armedRerun == nil)
        #expect(sleeper.delays.isEmpty)
    }

    #if !SWIFT_PACKAGE
        @Test("a completed sign-in sends what was still queued for that account")
        @MainActor
        func signInStartsAPass() async throws {
            let harness = Phase09AuthHarness(flow: .password)
            let owner = harness.userID
            let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { owner })
            try await WAFixture.enqueueIntake(outbox)

            let wire = WAWireLog()
            MockURLProtocol.install { req in
                wire.record(req)
                return WAFixture.reply(req, 201, WAFixture.intakeLogged)
            }
            let replay = WAFixture.replay(outbox: outbox, owner: owner)
            AppContainer.wireReplayAfterSignIn(authStore: harness.store, replay: replay)

            await harness.run()
            #expect(wire.all.isEmpty, "the credentials are accepted, the sign-in is not finished yet")

            harness.store.completeOnboarding()
            await waUntil("the sign-in drains the queue") { await outbox.snapshot.isEmpty }
            #expect(wire.all == [WAWireCall(method: "POST", path: "/api/medications/intake", key: "wa-intake")])
        }
    #endif

    // MARK: - A trigger that meets a running pass

    @Test("a sign-in that meets a pass begun signed out is caught up on: the account's dose goes out when that pass ends")
    func signInDuringAPassIsCaughtUpOn() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { WAFixture.owner })
        try await WAFixture.enqueueIntake(outbox)
        let wire = WAWireLog()
        MockURLProtocol.install { req in
            wire.record(req)
            return WAFixture.reply(req, 201, WAFixture.intakeLogged)
        }
        let signedIn = Mutex<String?>(nil)
        let gate = RerunPassGate()
        let replay = WAFixture.replay(
            outbox: outbox,
            currentUser: { signedIn.withLock { $0 } },
            serverHealthDegraded: { await gate.probe() }
        )

        let begunSignedOut = Task { await replay.runOnce() }
        await waUntil("the first pass has read the account and waits at its probe") { await gate.isHolding }

        signedIn.withLock { $0 = WAFixture.owner }
        await replay.runOnce()
        #expect(wire.all.isEmpty, "the trigger of the sign-in was turned away by the running pass")

        await gate.release()
        await begunSignedOut.value

        #expect(wire.all == [WAWireCall(method: "POST", path: "/api/medications/intake", key: "wa-intake")])
        #expect(await outbox.snapshot.isEmpty)
        #expect(await replay.isRunning == false)
    }

    @Test("however many triggers a pass turns away, exactly one pass follows it")
    func oneCatchUpPassForManyTriggers() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { WAFixture.owner })
        try await WAFixture.enqueueIntake(outbox)
        // The dose never gets through, so every pass finds it and reaches the probe.
        MockURLProtocol.install { _ in throw URLError(.networkConnectionLost) }
        let gate = RerunPassGate()
        let replay = WAFixture.replay(outbox: outbox, serverHealthDegraded: { await gate.probe() })

        let first = Task { await replay.runOnce() }
        await waUntil("the first pass waits at its probe") { await gate.isHolding }
        for _ in 0 ..< 3 {
            await replay.runOnce()
        }
        #expect(await gate.passes == 1, "a running pass keeps the guard")

        await gate.release()
        await first.value
        #expect(await gate.passes == 2, "one pass for the three triggers, not three and not a chain")
        #expect(await replay.isRunning == false)
        #expect(await outbox.snapshot.count == 1)

        await replay.runOnce()
        #expect(await gate.passes == 3, "a trigger that meets no pass starts its own, and nothing follows it")
    }

    @Test("a pass no trigger met is followed by none")
    func noCatchUpWithoutATrigger() async throws {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { WAFixture.owner })
        try await WAFixture.enqueueIntake(outbox)
        MockURLProtocol.install { _ in throw URLError(.networkConnectionLost) }
        let gate = RerunPassGate()
        let replay = WAFixture.replay(outbox: outbox, serverHealthDegraded: { await gate.probe() })

        let first = Task { await replay.runOnce() }
        await waUntil("the pass waits at its probe") { await gate.isHolding }
        await gate.release()
        await first.value

        #expect(await gate.passes == 1)
    }
}
