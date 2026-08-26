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

        /// Records one open. Synchronous and lock-guarded on purpose: it is
        /// called from inside the production open closure, where an `await`
        /// would change the very thing being measured.
        func record() {
            let onMain = Thread.isMainThread
            lock.lock()
            defer { lock.unlock() }
            storage.append(Open(wasMainThread: onMain))
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
            lock.unlock()
            return stream
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

    /// Waits for `condition` by yielding, never by sleeping.
    ///
    /// A bounded yield loop is not a sleep pretending to be a synchronisation:
    /// it makes no claim about elapsed time, it spends no wall clock when the
    /// condition is already true, and when the condition never becomes true the
    /// caller's own expectation is what reports it. Returns whether the
    /// condition was observed.
    @discardableResult
    func phase09Settle(
        yields: Int = 2000,
        until condition: @Sendable () async -> Bool
    ) async -> Bool {
        for _ in 0 ..< yields {
            if await condition() { return true }
            await Task.yield()
        }
        return await condition()
    }

#endif // !SWIFT_PACKAGE
