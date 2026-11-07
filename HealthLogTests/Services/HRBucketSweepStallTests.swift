#if canImport(HealthKit)
    import Foundation
    @testable import HealthLog
    import Testing

    /// SYNC-HR (1.5) — #159 / HealthLog#1326 (mills1975): the 10-minute
    /// heart rate stopped for most of a day, pull to refresh did not bring it
    /// back, a force-quit did.
    ///
    /// The shape: a sweep whose HealthKit statistics query never answered.
    /// `sync()` folded every later request into that sweep and waited on it
    /// without a limit, so the path stayed dead until the process ended.
    /// These tests play that query and pin the four exits: the next request
    /// after the deadline starts over, a late answer writes nothing, no
    /// waiter waits past the deadline, and a closing window stops the query.
    @Suite("SYNC-HR — HR bucket sweep never stalls (#159, #1326)", .timeLimit(.minutes(1)))
    struct HRBucketSweepStallTests {
        private typealias S = HRBucketSweepTestSupport

        private static let cutover = S.iso("2026-10-06T00:00:00.000Z")
        private static let now = S.iso("2026-11-01T09:55:00.000Z")

        @Test(
            "(a) a HealthKit read that never answers is left after the deadline; the next request uploads; the late answer changes nothing"
        )
        func stalledReadIsLeftBehind() async {
            let reader = S.Reader(rows: [S.row("2026-11-01T09:40:00.000Z")], hangCount: 1)
            let h = S.harness(service: reader, cutover: Self.cutover, now: Self.now)

            let first = Task { await h.coordinator.sync() }
            #expect(await S.eventually { reader.queries == 1 })

            // Inside the deadline a request joins the running sweep. REG: the
            // request (the body of `requestHRBucketSweep()`) signals from the
            // coordinator, and the barrier returns only after its decision, so
            // the clock cannot move past the deadline before the request looked.
            h.clock.advance(by: 60)
            let joined = ArrivalGate()
            let request = Task { await h.coordinator.sync(signalling: joined) }
            await joined.waitForArrival()
            await h.coordinator.drainedBarrier()
            #expect(h.api.posted.isEmpty)
            #expect(reader.queries == 1, "a request inside the deadline started a sweep of its own")

            // Past it, the next request leaves the stuck sweep and uploads.
            h.clock.advance(by: HealthKitHRBucketSyncCoordinator.defaultStaleAfter)
            let second = Task { await h.coordinator.sync() }
            let uploaded = await S.eventually { h.api.postedIds == [S.bucketId("2026-11-01T09:40:00.000Z")] }
            #expect(uploaded, "the request after the deadline did not upload; posted \(h.api.postedIds)")
            #expect(await S.eventually { reader.cancelledWhileHanging == 1 }, "the stuck sweep was not cancelled")
            // REG: the recovery sweep writes its ledger AFTER the post the
            // line above sees. Snapshot once it has returned, not once it posted.
            #expect(await second.value == 1, "the recovery sweep did not finish with its one bucket")
            let ledgerAfterRecovery = h.ledger

            // HealthKit answers the abandoned sweep at last, with other values.
            // Both callers left on it return only once its task has ended, so
            // whatever the late answer could write is written by then.
            reader.replaceRows([S.row("2026-11-01T09:40:00.000Z", bpm: 99), S.row("2026-11-01T09:50:00.000Z", bpm: 99)])
            reader.release()
            _ = await first.value
            _ = await request.value
            #expect(h.ledger == ledgerAfterRecovery, "a late answer of an abandoned sweep wrote to the ledger")
            #expect(h.api.posted.count == 1, "a late answer of an abandoned sweep posted")
        }

        @Test("a waiter on a stuck sweep returns at the deadline, and at once when it is already past")
        func waitersAreBounded() async {
            let reader = S.Reader(rows: [], hangCount: 1)
            let h = S.harness(service: reader, cutover: Self.cutover, now: Self.now, staleAfter: 0.4)
            let first = Task { await h.coordinator.sync() }
            #expect(await S.eventually { reader.queries == 1 })

            let coordinator = h.coordinator
            let bounded: Void? = await S.completes(within: 3) { await coordinator.awaitHRBucketSweep() }
            #expect(bounded != nil, "awaitHRBucketSweep waited past the deadline")

            // Past the deadline by the coordinator's clock: no wait at all.
            h.clock.advance(by: 1)
            let immediate: Void? = await S.completes(within: 1) { await coordinator.awaitHRBucketSweep() }
            #expect(immediate != nil)

            reader.release()
            _ = await first.value
        }

        @Test("(d) a closing background window stops the HealthKit query itself")
        func expiryStopsTheQuery() async {
            let store = S.SilentStore()
            let service = HealthKitHRBucketService(executor: store, queryTimeout: .seconds(600))
            let h = S.harness(service: service, cutover: Self.cutover, now: Self.now)
            let expired = Flag()

            let coordinator = h.coordinator
            let sweep = S.Box<Int>()
            Task { await sweep.set(coordinator.sync { expired.value }) }
            #expect(await S.eventually { store.executed == 1 })
            expired.set()

            #expect(await S.eventually { store.stoppedTheExecutedQuery }, "the expired sweep left its query running")
            #expect(await S.eventually { sweep.value == 0 }, "the caller kept waiting after its window closed")
            #expect(h.api.posted.isEmpty)
            // Abandoned, not failed: the raw path is not told the bucket path broke.
            #expect(h.ledger.lastFailureAt == nil)
        }

        @Test("the statistics query answers exactly once: on cancellation, stopped")
        func cancelledQueryIsStopped() async {
            let store = S.SilentStore()
            let service = HealthKitHRBucketService(executor: store, queryTimeout: .seconds(600))
            let read = Task {
                try await service.bucketRows(from: Self.now.addingTimeInterval(-3600), to: Self.now)
            }
            #expect(await S.eventually { store.executed == 1 })
            read.cancel()
            let outcome = await S.completes(within: 3) { await read.result.map { _ in true } }
            #expect(outcome != nil, "a cancelled query kept its caller waiting")
            if case let .failure(error)? = outcome { #expect(error is CancellationError) }
            #expect(store.stopped == 1)
            #expect(store.stoppedTheExecutedQuery)
        }

        @Test("the statistics query answers exactly once: past its time limit, stopped")
        func silentQueryTimesOut() async {
            let store = S.SilentStore()
            let service = HealthKitHRBucketService(executor: store, queryTimeout: .milliseconds(200))
            let from = Self.now.addingTimeInterval(-3600), to = Self.now
            let outcome = await S.completes(within: 3) {
                await Task { try await service.bucketRows(from: from, to: to) }.result.map(\.count)
            }
            #expect(outcome != nil, "a query that never answers kept its caller waiting")
            if case let .failure(error)? = outcome { #expect(error is HealthKitQueryTimedOut) }
            #expect(store.stopped == 1)
            #expect(HealthKitHRBucketService.defaultQueryTimeout == .seconds(60))
        }

        @Test("a timed-out query is a named failure and the next sweep reads again")
        func timedOutQueryIsRecorded() async {
            let store = S.SilentStore()
            let service = HealthKitHRBucketService(executor: store, queryTimeout: .milliseconds(200))
            let h = S.harness(service: service, cutover: Self.cutover, now: Self.now)
            let coordinator = h.coordinator
            #expect(await S.completes(within: 3) { await coordinator.sync() } == 0)
            #expect(h.ledger.lastEvent?.gate == .queryFailed)
            h.clock.advance(by: 600)
            _ = await S.completes(within: 3) { await coordinator.sync() }
            #expect(store.executed == 2)
        }

        @Test("a capability that never returns does not hold back samples, workouts or the outbox")
        func hangingCapabilityDoesNotHoldTheRound() async {
            let entered = Entered()
            func make(_ capability: HealthSyncCapability) -> HealthSyncCapabilityRegistry.Run {
                { _ in
                    await entered.add(capability)
                    if capability == .heartRateBuckets {
                        // Never answers and ignores cancellation.
                        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                    }
                    return .ran(capability)
                }
            }
            let registry = HealthSyncCapabilityRegistry(
                speziSampleCollection: make(.speziSampleCollection),
                workoutImport: make(.workoutImport),
                ecgUpload: make(.ecgUpload),
                dailyStatistics: make(.dailyStatistics),
                heartRateBuckets: make(.heartRateBuckets),
                nutrientDailyTotals: make(.nutrientDailyTotals),
                moodStateOfMindImport: make(.moodStateOfMindImport),
                appleMedicationImport: make(.appleMedicationImport),
                cycleImport: make(.cycleImport),
                heartHealthEvents: make(.heartHealthEvents),
                outboxDrain: make(.outboxDrain),
                serverMirror: make(.serverMirror)
            )
            let orchestrator = HealthSyncOrchestrator(registry: registry)
            let pass = Task {
                await HealthSyncOrchestrator.$capabilityDeadline.withValue(.milliseconds(300)) {
                    await orchestrator.run(.manual)
                }
            }
            let finished = await S.eventually(within: 10) { await entered.contains(.outboxDrain) }
            #expect(finished, "the round stopped at the hanging capability")
            guard finished else { return }
            let result = await pass.value
            #expect(result.result(for: .heartRateBuckets)?.disposition == .expired)
            #expect(result.result(for: .speziSampleCollection)?.disposition == .ran)
            #expect(result.result(for: .workoutImport)?.disposition == .ran)
            #expect(result.result(for: .outboxDrain)?.disposition == .ran)
            #expect(HealthSyncOrchestrator.capabilityDeadline == .seconds(150))
        }

        // MARK: - Sync diagnostics (item 7, server #586 promise 1)

        @Test("last accepted value: the server's PULSE entry when it sends one, the ledger otherwise")
        func lastAcceptedPrefersTheServer() {
            var ledger = HRBucketSyncLedger()
            ledger.lastAcceptedBucket = S.iso("2026-11-01T09:40:00.000Z")
            let snapshot = HRBucketDiagnosticsSnapshot(cutover: Self.cutover, ledger: ledger)
            let server = S.iso("2026-11-02T07:10:00.000Z")

            // Server with the field.
            #expect(snapshot.lastAccepted(freshness: [MetricFreshness(type: "PULSE", lastSeenAt: server)]) == server)
            // Server without it: older server, no PULSE entry, or not loaded.
            #expect(snapshot.lastAccepted(freshness: nil) == ledger.lastAcceptedBucket)
            #expect(snapshot.lastAccepted(freshness: []) == ledger.lastAcceptedBucket)
            #expect(snapshot.lastAccepted(freshness: [MetricFreshness(type: "PULSE")]) == ledger.lastAcceptedBucket)
            #expect(snapshot.lastAccepted(freshness: [MetricFreshness(type: "WEIGHT", lastSeenAt: server)]) == ledger.lastAcceptedBucket)
        }

        @Test("a sweep past its deadline reads as running since its start, and the report carries age and generation")
        func overdueSweepIsNamed() {
            let start = S.iso("2026-11-01T09:40:00.000Z")
            let snapshot = HRBucketDiagnosticsSnapshot(
                cutover: Self.cutover,
                ledger: HRBucketSyncLedger(),
                activity: HRBucketSweepActivity(generation: 7, startedAt: start)
            )
            #expect(snapshot.overdueSweep(now: start.addingTimeInterval(60)) == nil)
            #expect(snapshot.overdueSweep(now: start.addingTimeInterval(121))?.generation == 7)
            let line = SyncDiagnosticsReport.inFlight(snapshot.activity, now: start.addingTimeInterval(300))
            #expect(line.contains("generation 7"))
            #expect(line.contains("age 300s"))
            #expect(line.contains("overdue"))
            #expect(SyncDiagnosticsReport.inFlight(nil, now: start) == "none")
            let words = HKSyncDiagnosticsVocabulary.heartRateBucketRunningSince(start)
            #expect(!words.isEmpty && !words.contains("settings.hkdiag"))
        }

        private final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var raised = false
            var value: Bool {
                lock.withLock { raised }
            }

            func set() {
                lock.withLock { raised = true }
            }
        }

        private actor Entered {
            private var seen: Set<HealthSyncCapability> = []
            func add(_ capability: HealthSyncCapability) {
                seen.insert(capability)
            }

            func contains(_ capability: HealthSyncCapability) -> Bool {
                seen.contains(capability)
            }
        }
    }
#endif
