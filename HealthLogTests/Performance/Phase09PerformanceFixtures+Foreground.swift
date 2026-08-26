// The seams below hang off App-target symbols (`ForegroundCoordinator`,
// `ForegroundMember`), none of which exist in the SPM library build.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog

    /// **Phase 09 / plan 09-06 — a barrier that is opened, never waited out.**
    ///
    /// The foreground contracts are all about *order*: which member had finished
    /// when another one started, and whether a cancellation actually reached a
    /// member that was in the middle of something. Both need a member that stops
    /// exactly where the test wants it to stop and stays there — which a sleep
    /// cannot provide, because a sleep is a race the scheduler usually wins and
    /// occasionally loses.
    ///
    /// It resumes on cancellation as well as on ``open()``, which is what makes
    /// it a *cooperative* adapter: the deadline contract is that a cancelled
    /// member returns, and a barrier that ignored cancellation would be testing
    /// the opposite thing.
    final class Phase09Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var arrivals = 0
        private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        /// Tickets cancelled before they managed to park — the same window
        /// `FirstFrameSignal` closes, and for the same reason.
        private var cancelledTickets: Set<UUID> = []

        init() {}

        /// How many callers have reached the barrier, parked or not.
        var arrivalCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return arrivals
        }

        /// How many callers are parked right now.
        var waitingCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return waiters.count
        }

        var isOpen: Bool {
            lock.lock()
            defer { lock.unlock() }
            return opened
        }

        func open() {
            lock.lock()
            opened = true
            let parked = Array(waiters.values)
            waiters.removeAll()
            lock.unlock()
            // Resumed outside the lock: a continuation resume runs arbitrary
            // caller code, and running that under a lock is how a re-entrant
            // waiter deadlocks a pass.
            for continuation in parked {
                continuation.resume()
            }
        }

        /// The mutation is synchronous: `NSLock.lock()` is `noasync`, and taking
        /// a lock across a suspension point is the bug that annotation exists to
        /// prevent. Returns whether the barrier was already open.
        private func noteArrival() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            arrivals += 1
            return opened
        }

        func wait() async {
            let ticket = UUID()
            if noteArrival() { return }
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    let resumeImmediately: Bool
                    if opened || cancelledTickets.remove(ticket) != nil {
                        resumeImmediately = true
                    } else {
                        waiters[ticket] = continuation
                        resumeImmediately = false
                    }
                    lock.unlock()
                    if resumeImmediately { continuation.resume() }
                }
            } onCancel: {
                lock.lock()
                let parked = waiters.removeValue(forKey: ticket)
                if parked == nil, !opened { cancelledTickets.insert(ticket) }
                lock.unlock()
                parked?.resume()
            }
        }
    }

    /// **A clock that records the budget it is asked for and never spends it.**
    ///
    /// The foreground deadline is 250 ms and its drain allowance is 50 ms. A test
    /// that proved those by actually waiting would be asserting the simulator's
    /// punctuality; what is assertable without a wall clock is *which* budget the
    /// coordinator asked for, and *what it did* when that budget was declared
    /// spent. So every sleep parks until the test fires it by name, and
    /// cancellation ends it the way a real clock's would.
    final class Phase09ForegroundClock: ForegroundClock, @unchecked Sendable {
        private let lock = NSLock()
        private var requestedDurations: [Duration] = []
        private var parked: [UUID: (duration: Duration, continuation: CheckedContinuation<Void, Error>)] = [:]
        private var firedDurations: Set<Duration> = []
        private var cancelledTickets: Set<UUID> = []

        init() {}

        /// Every duration the coordinator asked for, in request order.
        var requested: [Duration] {
            lock.lock()
            defer { lock.unlock() }
            return requestedDurations
        }

        /// Declares `duration` elapsed. Every sleep of exactly that length —
        /// parked now or arriving later — returns normally.
        func fire(_ duration: Duration) {
            lock.lock()
            firedDurations.insert(duration)
            let matches = parked.filter { $0.value.duration == duration }
            for key in matches.keys {
                parked.removeValue(forKey: key)
            }
            lock.unlock()
            for match in matches.values {
                match.continuation.resume()
            }
        }

        /// Synchronous for the same `noasync` reason ``Phase09Gate/noteArrival()``
        /// is. Returns whether the requested budget has already been declared
        /// spent.
        private func noteRequest(_ duration: Duration) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            requestedDurations.append(duration)
            return firedDurations.contains(duration)
        }

        func sleep(for duration: Duration) async throws {
            let ticket = UUID()
            if noteRequest(duration) { return }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    lock.lock()
                    let resumption: Result<Void, Error>?
                    if firedDurations.contains(duration) {
                        resumption = .success(())
                    } else if cancelledTickets.remove(ticket) != nil {
                        resumption = .failure(CancellationError())
                    } else {
                        parked[ticket] = (duration, continuation)
                        resumption = nil
                    }
                    lock.unlock()
                    if let resumption { continuation.resume(with: resumption) }
                }
            } onCancel: {
                lock.lock()
                let entry = parked.removeValue(forKey: ticket)
                if entry == nil { cancelledTickets.insert(ticket) }
                lock.unlock()
                entry?.continuation.resume(throwing: CancellationError())
            }
        }
    }

    /// **The recording spy the ordering contracts are read from.**
    ///
    /// It is the test's own witness, deliberately independent of the ledger the
    /// coordinator keeps: "the coordinator says it ordered them" and "the members
    /// actually ran in that order" are two different claims, and only the second
    /// one is the contract.
    final class Phase09ForegroundSpy: @unchecked Sendable {
        struct Mark: Sendable, Equatable {
            let member: ForegroundMember
            let phase: ForegroundPassEvent.Phase
        }

        private let lock = NSLock()
        private var marks: [Mark] = []
        private var live = 0
        private var peak = 0

        init() {}

        var events: [Mark] {
            lock.lock()
            defer { lock.unlock() }
            return marks
        }

        /// The largest number of members that were simultaneously in flight.
        /// Two is already the whole overlap claim: a pass that ran its members
        /// one after another would never exceed one.
        var maxConcurrent: Int {
            lock.lock()
            defer { lock.unlock() }
            return peak
        }

        func startCount(of member: ForegroundMember) -> Int {
            events.filter { $0.member == member && $0.phase == .started }.count
        }

        func endCount(of member: ForegroundMember) -> Int {
            events.filter { $0.member == member && $0.phase == .finished }.count
        }

        func hasStarted(_ member: ForegroundMember) -> Bool {
            startCount(of: member) > 0
        }

        func hasEnded(_ member: ForegroundMember) -> Bool {
            endCount(of: member) > 0
        }

        /// How many times `later` **started** before `earlier` **finished**.
        ///
        /// Zero is the happens-before contract. A count rather than a `Bool`
        /// because the number is the diagnostic: it says how many of the badge's
        /// starts raced the medication load, not merely that one did.
        func starts(of later: ForegroundMember, beforeEndOf earlier: ForegroundMember) -> Int {
            let all = events
            let end = all.firstIndex { $0.member == earlier && $0.phase == .finished } ?? all.count
            return all[..<end].filter { $0.member == later && $0.phase == .started }.count
        }

        /// A step that records its own start and end around `body`.
        func step(
            _ member: ForegroundMember,
            _ body: @escaping @Sendable (ForegroundSession) async throws -> Void
        ) -> ForegroundStep {
            ForegroundStep(member) { [self] session in
                mark(member, .started)
                defer { mark(member, .finished) }
                try await body(session)
            }
        }

        private func mark(_ member: ForegroundMember, _ phase: ForegroundPassEvent.Phase) {
            lock.lock()
            marks.append(Mark(member: member, phase: phase))
            switch phase {
            case .started:
                live += 1
                peak = max(peak, live)
            case .finished:
                live -= 1
            case .cancelled, .failed, .skipped:
                break
            }
            lock.unlock()
        }
    }

#endif // !SWIFT_PACKAGE
