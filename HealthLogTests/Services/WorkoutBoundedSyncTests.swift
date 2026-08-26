import Foundation
@testable import HealthLog
import Synchronization
import Testing

#if canImport(HealthKit)
    import HealthKit

    @Suite("Bounded direct workout synchronization", .serialized)
    struct WorkoutBoundedSyncTests {
        @Test("Fresh processing deltas larger than the route cap stay on one finite page")
        func freshProcessingDeltaIsBounded() {
            let available = WorkoutIngestDTO.maxWorkoutsPerBatch * 3

            #expect(WorkoutHealthKitImporter.pageLimit(for: .processing) == WorkoutIngestDTO.maxWorkoutsPerBatch)
            #expect(min(available, WorkoutHealthKitImporter.pageLimit(for: .processing)) == WorkoutIngestDTO.maxWorkoutsPerBatch)
        }

        @Test("Stale incremental deltas larger than the series-safe cap stay on one finite page")
        func staleIncrementalDeltaIsBounded() {
            let available = WorkoutIngestDTO.maxWorkoutsPerBatch * 3

            #expect(
                WorkoutHealthKitImporter.pageLimit(for: .incrementalOnly)
                    == WorkoutIngestDTO.maxWorkoutsPerSeriesBatch
            )
            #expect(
                min(available, WorkoutHealthKitImporter.pageLimit(for: .incrementalOnly))
                    == WorkoutIngestDTO.maxWorkoutsPerSeriesBatch
            )
        }

        @Test("Revoke empty page retains the old anchor and regrant data can advance it")
        func revokeEmptyRegrantAnchorPolicy() {
            #expect(WorkoutHealthKitImporter.shouldSkipAnchorSave(hadPersistedAnchor: true, fetchedCount: 0))
            #expect(!WorkoutHealthKitImporter.shouldSkipAnchorSave(hadPersistedAnchor: true, fetchedCount: 1))
        }

        @Test("Same-partition compatible callers join the same result")
        func samePartitionCallersJoinResult() async {
            let coordinator = WorkoutSyncPassCoordinator()
            let probe = WorkoutPassProbe(results: [false])

            let arrival = ArrivalGate()

            async let first = coordinator.run(partition: "user-A", mode: .processing) {
                await probe.run(mode: $0)
            }
            await probe.waitForRunCount(1)
            // 22-02 (D-14-02-A, coordinator half) — the second caller must be
            // INSIDE `coordinator.run` before the first pass is released.
            // Without this barrier the release could complete the first pass
            // before the joiner ever reached the join decision, the joiner would
            // then legitimately start a SECOND pass, and the probe would overrun
            // — which used to kill the host rather than say so.
            async let joined = { () async -> Bool in
                await arrival.arrive()
                return await coordinator.run(partition: "user-A", mode: .incrementalOnly) {
                    await probe.run(mode: $0)
                }
            }()
            await arrival.waitForArrival()
            await probe.release()

            #expect(await first == false)
            #expect(await joined == false)
            #expect(await probe.modes == [.processing])
        }

        @Test("A processing request behind a short pass schedules one stronger follow-up")
        func processingUpgradeSchedulesOneFollowUp() async {
            let coordinator = WorkoutSyncPassCoordinator()
            let probe = WorkoutPassProbe(results: [true, false])

            let arrival = ArrivalGate(expected: 2)

            async let short = coordinator.run(partition: "user-A", mode: .incrementalOnly) {
                await probe.run(mode: $0)
            }
            await probe.waitForRunCount(1)
            // 22-02 — same barrier as above: both upgrade callers must have
            // entered `coordinator.run` before the short pass is released, or
            // one of them races the completion and starts a third pass.
            async let processingOne = { () async -> Bool in
                await arrival.arrive()
                return await coordinator.run(partition: "user-A", mode: .processing) {
                    await probe.run(mode: $0)
                }
            }()
            async let processingTwo = { () async -> Bool in
                await arrival.arrive()
                return await coordinator.run(partition: "user-A", mode: .processing) {
                    await probe.run(mode: $0)
                }
            }()
            await arrival.waitForArrival()
            await probe.release()

            #expect(await short)
            #expect(await processingOne == false)
            #expect(await processingTwo == false)
            #expect(await probe.modes == [.incrementalOnly, .processing])
        }

        @Test("A different partition waits and receives only its own pass result")
        func accountSwitchRunsOwnPartition() async {
            let coordinator = WorkoutSyncPassCoordinator()
            let probe = WorkoutPassProbe(results: [false, true])

            async let userA = coordinator.run(partition: "user-A", mode: .processing) {
                await probe.run(partition: "user-A", mode: $0)
            }
            await probe.waitForRunCount(1)
            async let userB = coordinator.run(partition: "user-B", mode: .processing) {
                await probe.run(partition: "user-B", mode: $0)
            }
            #expect(await probe.partitions == ["user-A"])
            await probe.release()

            #expect(await userA == false)
            #expect(await userB)
            #expect(await probe.partitions == ["user-A", "user-B"])
        }

        /// **22-02 (D-14-02-A / D-17-01-A / D-21-EXEC-A) — one mechanism, three
        /// observations.**
        ///
        /// `WorkoutPassProbe.run` ended in `pendingResults.removeFirst()`. When
        /// a lost race let the coordinator run one pass more than the case
        /// seeded, that call TRAPPED: the whole test host died, the run
        /// restarted, and the census was destroyed. Three separate plans
        /// recorded that as three separate flakes. It is one line.
        ///
        /// A dead host is strictly worse than a red. This case drives the
        /// overrun deliberately and requires the probe to RECORD a readable
        /// failure naming the counts and keep running. Against the pre-22-02
        /// probe this case brought the host down — which is the RED, and it was
        /// run and observed (`22-02-probe-trap`, exit 65 with the host lost).
        @Test("Ein Ueberlauf der Probe ist ein lesbarer Fehlschlag, kein toter Testhost")
        func probeOverrunRecordsAFailureInsteadOfTrapping() async {
            // The report sink is injected rather than left at `Issue.record`, so
            // this case can assert WHAT the overrun says without spending an
            // expected failure on the run (the gate contract is 0 skips and 0
            // expectedFailures; a demonstration must not move either number).
            let reported = ReportedIssues()
            let probe = WorkoutPassProbe(results: [true], report: { reported.append($0) })
            // The first run blocks until released; nothing here is racing, so
            // open the gate before driving it.
            await probe.release()

            let seeded = await probe.run(mode: .processing)
            #expect(seeded, "the seeded result is served as before")

            let overrun = await probe.run(mode: .processing)

            #expect(overrun == false, "an unseeded pass returns a safe default instead of trapping")
            #expect(await probe.overrunCount == 1, "the overrun is counted, not fatal")
            #expect(await probe.modes.count == 2, "the probe survived to record both runs")
            #expect(reported.lines.count == 1, "exactly one failure is reported for one overrun")
            let line = reported.lines.first ?? ""
            #expect(line.contains("WorkoutPassProbe overrun"), "the line names itself")
            #expect(line.contains("seeded 1"), "the line names the seeded count")
            #expect(line.contains("pass #2"), "the line names which pass overran")
        }

        @Test("A new auth generation invalidates the captured direct-workout lease")
        func authGenerationInvalidatesCapturedLease() {
            let registry = WorkoutImportLeaseRegistry()
            let userA = registry.activate(ownerUserID: "user-A", authIsCurrent: { true })

            #expect(userA.isCurrent)
            let userB = registry.activate(ownerUserID: "user-B", authIsCurrent: { true })

            #expect(!userA.isCurrent)
            #expect(userB.isCurrent)
            #expect(userB.authGeneration > userA.authGeneration)
            registry.invalidate()
            #expect(!userB.isCurrent)
        }

        @Test("Cancelling an anchored query stops HealthKit exactly once and ignores a late callback")
        func anchoredQueryCancellationStopsExactlyOnce() async {
            let probe = WorkoutAnchoredQueryDriverProbe()
            let source = LiveWorkoutAnchoredQuerySource(driver: probe.driver)
            let task = Task {
                try await source.fetch(anchor: nil, limit: 10)
            }
            await probe.waitForExecute()

            task.cancel()
            do {
                _ = try await task.value
                Issue.record("cancelled HealthKit query unexpectedly succeeded")
            } catch is CancellationError {
                // Expected.
            } catch {
                Issue.record("unexpected cancellation error: \(error)")
            }

            probe.complete(.success(.init(workouts: [], newAnchor: nil)))
            #expect(probe.stopCount == 1)
        }

        @Test("Cancellation before query registration still stops exactly once")
        func cancellationBeforeQueryRegistrationStopsExactlyOnce() async {
            let probe = WorkoutAnchoredQueryDriverProbe()
            let registrationGate = WorkoutQueryRegistrationGate()
            let source = LiveWorkoutAnchoredQuerySource(
                driver: probe.driver,
                beforeRegister: { await registrationGate.wait() }
            )
            let task = Task {
                try await source.fetch(anchor: nil, limit: 10)
            }
            await probe.waitForQueryCreation()

            task.cancel()
            await registrationGate.open()
            do {
                _ = try await task.value
                Issue.record("cancelled HealthKit query unexpectedly succeeded")
            } catch is CancellationError {
                // Expected.
            } catch {
                Issue.record("unexpected cancellation error: \(error)")
            }

            probe.complete(.success(.init(workouts: [], newAnchor: nil)))
            #expect(probe.executeCount == 0)
            #expect(probe.stopCount == 1)
        }

        @Test("Logout invalidates the lease and cancels the importer's active anchored query")
        func logoutCancelsImporterAnchoredQuery() async {
            let probe = WorkoutAnchoredQueryDriverProbe()
            let source = LiveWorkoutAnchoredQuerySource(driver: probe.driver)
            let registry = WorkoutImportLeaseRegistry()
            let lease = registry.activate(ownerUserID: "user-A", authIsCurrent: { true })
            let importer = WorkoutHealthKitImporter(
                store: HKHealthStore(),
                repo: NoopWorkoutBatchUploader(),
                userID: "user-A",
                lifecycleStore: ImmediateWorkoutLifecycleStore(),
                anchoredQuerySource: source,
                lease: lease
            )
            let pass = Task {
                await importer.runBoundedPage(mode: .incrementalOnly)
            }
            await probe.waitForExecute()

            registry.invalidate()
            await importer.stop()

            #expect(await pass.value == .notRun)
            #expect(probe.stopCount == 1)
        }

        @Test("Cancelling the bounded-page caller stops its inner anchored query")
        func callerCancellationStopsImporterQuery() async throws {
            let probe = WorkoutAnchoredQueryDriverProbe()
            let suite = "hl.test.importer-cancel.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            let importer = WorkoutHealthKitImporter(
                store: HKHealthStore(),
                repo: NoopWorkoutBatchUploader(),
                userID: "user-A",
                defaultsBox: WorkoutDefaultsBox(suiteName: suite),
                lifecycleStore: ImmediateWorkoutLifecycleStore(),
                anchoredQuerySource: LiveWorkoutAnchoredQuerySource(driver: probe.driver)
            )
            let pass = Task { await importer.runBoundedPage(mode: .processing) }
            await probe.waitForExecute()

            pass.cancel()

            #expect(await pass.value == .notRun)
            #expect(probe.stopCount == 1)
            #expect(!HealthKitService.hasPersistedWorkoutAnchor(userID: "user-A", defaults: defaults))
            await importer.stop()
        }

        @Test("A processing page waits behind an in-flight incremental page")
        func processingWaitsBehindIncrementalPage() async {
            let source = BlockingWorkoutAnchoredSource()
            let importer = WorkoutHealthKitImporter(
                store: HKHealthStore(),
                repo: NoopWorkoutBatchUploader(),
                userID: "user-A",
                lifecycleStore: ImmediateWorkoutLifecycleStore(),
                anchoredQuerySource: source
            )
            let incremental = Task { await importer.runBoundedPage(mode: .incrementalOnly) }
            await source.waitForFetchCount(1)
            let processing = Task { await importer.runBoundedPage(mode: .processing) }
            for _ in 0 ..< 20 {
                await Task.yield()
            }
            #expect(await source.fetchCount == 1)

            await source.releaseNext()
            await source.waitForFetchCount(2)
            await source.releaseNext()

            #expect(await (incremental.value).didRun)
            #expect(await (processing.value).didRun)
            await importer.stop()
        }

        @Test("Cancelling a joined waiter does not cancel the shared importer page")
        func joinedWaiterCancellationPreservesSharedPage() async {
            let source = BlockingWorkoutAnchoredSource()
            let importer = WorkoutHealthKitImporter(
                store: HKHealthStore(),
                repo: NoopWorkoutBatchUploader(),
                userID: "user-A",
                lifecycleStore: ImmediateWorkoutLifecycleStore(),
                anchoredQuerySource: source
            )
            let processing = Task { await importer.runBoundedPage(mode: .processing) }
            await source.waitForFetchCount(1)
            let joined = Task { await importer.runBoundedPage(mode: .incrementalOnly) }
            for _ in 0 ..< 20 {
                await Task.yield()
            }

            joined.cancel()
            #expect(await source.fetchCount == 1)
            await source.releaseNext()

            #expect(await (processing.value).didRun)
            #expect(await joined.value == .notRun)
            await importer.stop()
        }

        @Test("A failed pre-anchor rearm hook retains the direct anchor")
        func failedPreAnchorHookRetainsAnchor() async throws {
            let suite = "hl.test.pre-anchor.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            let hookObservedNoAnchor = Mutex(false)
            let importer = WorkoutHealthKitImporter(
                store: HKHealthStore(),
                repo: AcceptingWorkoutBatchUploader(),
                userID: "user-A",
                defaultsBox: WorkoutDefaultsBox(suiteName: suite),
                lifecycleStore: ImmediateWorkoutLifecycleStore(),
                anchoredQuerySource: FixedCountWorkoutAnchoredSource(),
                directDTOProvider: { Self.seriesFreeDTOs(count: 11) },
                beforeSeriesFreeAnchorAdvance: { _ in
                    let isolated = UserDefaults(suiteName: suite) ?? .standard
                    hookObservedNoAnchor.withLock {
                        $0 = !HealthKitService.hasPersistedWorkoutAnchor(userID: "user-A", defaults: isolated)
                    }
                    return false
                }
            )

            #expect(await importer.runBoundedPage(mode: .processing) == .notRun)
            #expect(hookObservedNoAnchor.withLock { $0 })
            #expect(!HealthKitService.hasPersistedWorkoutAnchor(userID: "user-A", defaults: defaults))
            await importer.stop()
        }

        @Test("One failed series rejects the whole mapped direct page")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func failedSeriesRejectsWholeMappedPage() async {
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            let driver = WorkoutSeriesScriptedDriver(results: [
                .samples([WorkoutHRSample(timestamp: start, bpm: 121)]),
                .failed
            ])
            let service = HealthKitWorkoutDetailService(queryDriver: driver)
            let importer = WorkoutHealthKitImporter(
                store: HKHealthStore(),
                repo: NoopWorkoutBatchUploader(),
                userID: "user-A",
                series: service,
                lifecycleStore: ImmediateWorkoutLifecycleStore()
            )

            let outcome = await importer.buildDTOs(from: [
                WorkoutSeriesFixtures.workout(start: start),
                WorkoutSeriesFixtures.workout(start: start.addingTimeInterval(120))
            ])

            #expect(outcome == .failed(.query))
            await importer.stop()
        }

        private static func seriesFreeDTOs(count: Int) -> [WorkoutIngestDTO] {
            (0 ..< count).map { index in
                let start = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
                return WorkoutIngestDTO(
                    sportType: "running",
                    startedAt: start,
                    endedAt: start.addingTimeInterval(60),
                    source: "APPLE_HEALTH",
                    externalId: "direct-\(index)",
                    samples: nil
                )
            }
        }
    }

    private final class WorkoutAnchoredQueryDriverProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var completion: (@Sendable (Result<WorkoutAnchoredQueryPage, any Error>) -> Void)?
        private var queryWasCreated = false
        private var _executeCount = 0
        private var _stopCount = 0

        var driver: WorkoutAnchoredQueryDriver {
            WorkoutAnchoredQueryDriver(
                makeQuery: { [self] _, _, completion in
                    lock.withLock {
                        self.completion = completion
                        queryWasCreated = true
                    }
                    return HKAnchoredObjectQuery(
                        type: HKObjectType.workoutType(),
                        predicate: nil,
                        anchor: nil,
                        limit: 1
                    ) { _, _, _, _, _ in }
                },
                execute: { [self] _ in
                    lock.withLock { _executeCount += 1 }
                },
                stop: { [self] _ in
                    lock.withLock { _stopCount += 1 }
                }
            )
        }

        var executeCount: Int {
            lock.withLock { _executeCount }
        }

        var stopCount: Int {
            lock.withLock { _stopCount }
        }

        func waitForQueryCreation() async {
            while !lock.withLock({ queryWasCreated }) {
                await Task.yield()
            }
        }

        func waitForExecute() async {
            while executeCount == 0 {
                await Task.yield()
            }
        }

        func complete(_ result: Result<WorkoutAnchoredQueryPage, any Error>) {
            lock.withLock { completion }?(result)
        }
    }

    private actor WorkoutQueryRegistrationGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    private actor BlockingWorkoutAnchoredSource: WorkoutAnchoredQueryFetching {
        private var waiters: [CheckedContinuation<WorkoutAnchoredQueryPage, any Error>] = []
        private(set) var fetchCount = 0

        func fetch(anchor _: HKQueryAnchor?, limit _: Int) async throws -> WorkoutAnchoredQueryPage {
            fetchCount += 1
            return try await withCheckedThrowingContinuation { waiters.append($0) }
        }

        func waitForFetchCount(_ count: Int) async {
            while fetchCount < count {
                await Task.yield()
            }
        }

        func releaseNext() {
            waiters.removeFirst().resume(returning: WorkoutAnchoredQueryPage(workouts: [], newAnchor: nil))
        }
    }

    private actor FixedCountWorkoutAnchoredSource: WorkoutAnchoredQueryFetching {
        func fetch(anchor _: HKQueryAnchor?, limit _: Int) async throws -> WorkoutAnchoredQueryPage {
            WorkoutAnchoredQueryPage(
                workouts: [],
                newAnchor: HKQueryAnchor(fromValue: 1),
                fetchedCount: 11
            )
        }
    }

    private actor ImmediateWorkoutLifecycleStore: WorkoutHealthKitStore {
        func executeWorkoutObserver(onUpdate _: @escaping @Sendable () -> Void) async {}
        func stopWorkoutObserver() async {}
        func enableWorkoutBackgroundDelivery() async throws {}
        func disableWorkoutBackgroundDelivery() async throws {}
    }

    private actor NoopWorkoutBatchUploader: WorkoutBatchUploading {
        func uploadBatch(
            _: [WorkoutIngestDTO],
            ownerUserID _: String
        ) async throws -> WorkoutBatchResponseDTO {
            Issue.record("cancelled direct query unexpectedly reached upload")
            throw CancellationError()
        }
    }

    private actor AcceptingWorkoutBatchUploader: WorkoutBatchUploading {
        func uploadBatch(
            _ workouts: [WorkoutIngestDTO],
            ownerUserID _: String
        ) async throws -> WorkoutBatchResponseDTO {
            WorkoutBatchResponseDTO(
                processed: workouts.count,
                inserted: workouts.count,
                duplicates: 0,
                entries: workouts.indices.map {
                    WorkoutBatchResponseDTO.Entry(index: $0, status: .inserted)
                }
            )
        }
    }
#endif
