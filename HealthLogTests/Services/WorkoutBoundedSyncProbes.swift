// 22-02 — the three fixtures this plan added to `WorkoutBoundedSyncTests`.
//
// Split out rather than grown inside it: the overrun demonstration and the
// arrival barrier took that file from 508 lines to 665, past SwiftLint's
// `file_length` warning at 600, and this operation does not hand gate debt
// forward. ONLY the fixtures 22-02 introduced (plus the probe it rewrote) moved;
// the suite's older private fixtures stayed where they were, because two of
// their names are already taken by other suites in this target and renaming
// another plan's fixtures on the way past is how attribution gets lost.

import Foundation
@testable import HealthLog
import Synchronization
import Testing

#if canImport(HealthKit)
    import HealthKit

    /// **22-02 (D-14-02-A, coordinator half)** — "the later callers have
    /// entered `coordinator.run`", as a barrier instead of a hope.
    ///
    /// Honest about what it does and does not buy. It closes the large window
    /// (a child task that had not been scheduled at all when the first pass was
    /// released) and leaves a small one: the actor hop between arriving here and
    /// the join decision inside the coordinator. Closing THAT would need an
    /// observable edge on the join itself, which the shipped coordinator does
    /// not expose — recorded as the deferred half of D-14-02-A rather than
    /// papered over with a sleep.
    /// Capturing sink for the overrun demonstration — see
    /// `probeOverrunRecordsAFailureInsteadOfTrapping`.
    final class ReportedIssues: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            storage.append(line)
        }

        var lines: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    actor ArrivalGate {
        private let expected: Int
        private var arrived = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(expected: Int = 1) {
            self.expected = expected
        }

        func arrive() {
            arrived += 1
            guard arrived >= expected else { return }
            let pending = waiters
            waiters.removeAll()
            for waiter in pending {
                waiter.resume()
            }
        }

        func waitForArrival() async {
            if arrived >= expected { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    actor WorkoutPassProbe {
        private var pendingResults: [Bool]
        private var firstRunBlocked = true
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
        private(set) var modes: [WorkoutSyncPassMode] = []
        private(set) var partitions: [String] = []
        /// **22-02** — how often the coordinator ran a pass this case did not
        /// seed. Counted rather than trapped: see `run(partition:mode:)`.
        private(set) var overrunCount = 0
        private let seededCount: Int
        private let report: @Sendable (String) -> Void

        /// - Parameter report: where an overrun is reported. Defaults to
        ///   `Issue.record`, which is what every real case wants: an overrun is
        ///   a genuine finding. The overrun demonstration injects a capturing
        ///   sink so it can assert the wording without spending an expected
        ///   failure.
        init(results: [Bool], report: @escaping @Sendable (String) -> Void = { Issue.record(Comment(rawValue: $0)) }) {
            pendingResults = results
            seededCount = results.count
            self.report = report
        }

        /// **22-02 — an overrun FAILS; it does not trap.**
        ///
        /// This used to end in a bare `pendingResults.removeFirst()`. One pass
        /// more than the case seeded — a lost race in the coordinator, a
        /// scheduling hiccup under parallel load — emptied the array and killed
        /// the test HOST: the run restarted, every suite that had already
        /// reported was re-counted from a previous launch, and the census the
        /// ship gate reads became fiction. D-14-02-A, D-17-01-A and D-21-EXEC-A
        /// are three sightings of this one line. Observed directly in
        /// `22-02-probe-trap`: "Fatal error: Can't remove first element from an
        /// empty collection", followed by "Restarting after unexpected exit".
        ///
        /// A recorded failure naming both counts is a red an operator can read
        /// in ten seconds. That is the whole change.
        func run(partition: String? = nil, mode: WorkoutSyncPassMode) async -> Bool {
            modes.append(mode)
            if let partition { partitions.append(partition) }
            if modes.count == 1, firstRunBlocked {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
            guard !pendingResults.isEmpty else {
                overrunCount += 1
                report(
                    """
                    WorkoutPassProbe overrun: pass #\(modes.count) has no seeded result \
                    (seeded \(seededCount), overruns \(overrunCount), modes \(modes)). \
                    The coordinator ran a pass this case did not expect — read this line, \
                    not a crash log.
                    """
                )
                return false
            }
            return pendingResults.removeFirst()
        }

        func waitForRunCount(_ count: Int) async {
            while modes.count < count {
                await Task.yield()
            }
        }

        func release() {
            firstRunBlocked = false
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
#endif
