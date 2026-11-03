// The seams below hang off App-target symbols (`OutboxOpenFactory`,
// `AppContainer`), none of which exist in the SPM library build.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog

    /// **Phase 09 / plan 09-05 — an open census, with a thread column.**
    ///
    /// The claim 09-05 has to support is "the persistent outbox is opened
    /// exactly once, and not before the app drew". Both halves are counts, not
    /// clocks: *how many* SQLite opens happened, and *on which side of the
    /// first-frame barrier* they happened. Neither is observable from outside
    /// the composition root, so the census sits behind the same
    /// ``OutboxOpenFactory`` seam 09-01 landed for exactly this purpose.
    ///
    /// The thread column exists because "off the launch-critical path" is a
    /// statement about *where* the blocking open runs, which a simulator can
    /// answer honestly, rather than about *how long* it takes, which it cannot.
    final class Phase09OutboxOpenLedger: @unchecked Sendable {
        struct Open: Sendable, Equatable {
            let wasMainThread: Bool
        }

        private let lock = NSLock()
        private var storage: [Open] = []
        private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        /// Records one open. Synchronous and lock-guarded on purpose: it is
        /// called from inside the production open closure, where an `await`
        /// would change the very thing being measured.
        func record() {
            let onMain = Thread.isMainThread
            lock.lock()
            storage.append(Open(wasMainThread: onMain))
            let reached = storage.count
            let ready = waiters.filter { $0.count <= reached }
            waiters.removeAll { $0.count <= reached }
            lock.unlock()
            // Resumed outside the lock: a resume can run the waiter's code.
            for waiter in ready {
                waiter.continuation.resume()
            }
        }

        /// 1.2 V5 — suspends until at least `count` opens were recorded. The
        /// open runs on a detached executor, so a yield budget on the caller's
        /// executor was a race under load (seen in T4). This waits for the
        /// event itself; the suite's time limit is the only bound.
        func waitForOpens(atLeast count: Int) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guard registerOpenWaiter(count: count, continuation: continuation) else { return }
                continuation.resume()
            }
        }

        /// `true` when the count is already reached (the caller resumes).
        private func registerOpenWaiter(count: Int, continuation: CheckedContinuation<Void, Never>) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if storage.count >= count { return true }
            waiters.append((count, continuation))
            return false
        }

        var opens: [Open] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        var count: Int {
            opens.count
        }

        var mainThreadCount: Int {
            opens.filter(\.wasMainThread).count
        }
    }

    /// A reachability double whose online stream is *observable* and *driven*.
    ///
    /// Two properties matter for 09-05. First, the launch bootstrap must not
    /// subscribe to the stream before the barriers it is supposed to respect,
    /// so the subscription itself is recorded. Second, nothing in this fixture
    /// may fire on a timer: the stream yields exactly what a test pushes into
    /// it, so an ordering assertion is settled by the test rather than by the
    /// scheduler's goodwill.
    final class Phase09ScriptedReachability: ReachabilityProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncStream<Bool>.Continuation?
        private var subscriptions = 0
        private var subscriptionWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        private var probes = 0
        private let confirms: Bool

        init(confirmedReachable: Bool = true) {
            confirms = confirmedReachable
        }

        var isOnlineStream: AsyncStream<Bool> {
            get async { subscribe() }
        }

        /// How many times the bootstrap has asked for the stream. Zero is the
        /// proof that a barrier really is holding it back.
        var subscriptionCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return subscriptions
        }

        var probeCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return probes
        }

        func isCurrentlyOnline() async -> Bool {
            confirms
        }

        func confirmedReachable() async -> Bool {
            noteProbe()
        }

        /// The mutation itself is synchronous: `NSLock.lock()` is `noasync`, and
        /// taking a lock across a suspension point is the bug that annotation
        /// exists to prevent. Every `async` member of this double therefore does
        /// its state work in a synchronous helper.
        private func subscribe() -> AsyncStream<Bool> {
            let (stream, continuation) = AsyncStream.makeStream(of: Bool.self)
            lock.lock()
            subscriptions += 1
            self.continuation = continuation
            let reached = subscriptions
            let ready = subscriptionWaiters.filter { $0.count <= reached }
            subscriptionWaiters.removeAll { $0.count <= reached }
            lock.unlock()
            for waiter in ready {
                waiter.continuation.resume()
            }
            return stream
        }

        /// 1.2 V5 — suspends until the bootstrap subscribed at least `count`
        /// times. Event-driven for the same reason as
        /// ``Phase09OutboxOpenLedger/waitForOpens(atLeast:)``.
        func waitForSubscriptions(atLeast count: Int) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guard registerSubscriptionWaiter(count: count, continuation: continuation) else { return }
                continuation.resume()
            }
        }

        private func registerSubscriptionWaiter(count: Int, continuation: CheckedContinuation<Void, Never>) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if subscriptions >= count { return true }
            subscriptionWaiters.append((count, continuation))
            return false
        }

        private func noteProbe() -> Bool {
            lock.lock()
            probes += 1
            lock.unlock()
            return confirms
        }

        /// Push one interface edge into whichever subscription exists.
        func send(online: Bool) {
            lock.lock()
            let sink = continuation
            lock.unlock()
            sink?.yield(online)
        }

        func finish() {
            lock.lock()
            let sink = continuation
            continuation = nil
            lock.unlock()
            sink?.finish()
        }
    }

    /// **Positive probe:** waits until `condition` holds and returns whether it
    /// did. Callers assert the result (`#expect(await phase09AwaitCondition {…})`).
    ///
    /// 1.2 V5 took the yield budget off this probe because any budget is a
    /// race when the producer runs on another executor. T1 (1.4) gives it a
    /// wall-clock bound back, as a hang guard and not as a budget: a condition
    /// that is already true costs nothing, one that comes true late on a loaded
    /// machine is still seen, and one that never comes true returns `false`
    /// after `timeout`, so the caller's own expectation reports it instead of
    /// a hang that only the job time limit would end.
    @discardableResult
    func phase09AwaitCondition(
        timeout: Duration = .seconds(30),
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var turn = 0
        while await !condition() {
            guard ContinuousClock.now < deadline else { return false }
            await phase09PollTurn(turn)
            turn += 1
        }
        return true
    }

    /// **Negative probe only:** gives `condition` a window of wall time to
    /// come true and returns whether it did. Callers expect `false` ("nothing
    /// happened"). A positive probe belongs on ``phase09AwaitCondition(timeout:_:)``.
    ///
    /// T1 (1.4): the window is time, no longer 2,000 yields. Under load a yield
    /// count runs out in microseconds, before the producer has been scheduled
    /// at all. For a positive probe that read "not yet" as "never"
    /// (`StoreLoadingTruthTests`, red after 0.057 s); for a negative probe it
    /// made the check vacuous. A longer window can only turn a negative probe
    /// red when the unwanted effect really happens.
    @discardableResult
    func phase09Settle(
        for window: Duration = .milliseconds(200),
        until condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: window)
        var turn = 0
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            await phase09PollTurn(turn)
            turn += 1
        }
        return await condition()
    }

    /// One polling turn of the two probes above: plain yields while the wait
    /// is young, so a producer that is already scheduled is seen at no cost,
    /// then 1 ms naps, so a long wait neither spins a core on a loaded machine
    /// nor keeps the main queue permanently busy for a main-actor caller.
    private func phase09PollTurn(_ turn: Int) async {
        if turn < 100 {
            await Task.yield()
        } else {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

#endif // !SWIFT_PACKAGE
