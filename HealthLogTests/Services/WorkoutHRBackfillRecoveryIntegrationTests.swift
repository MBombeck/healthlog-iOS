import Foundation

// End-to-end recovery scenarios intentionally share one serialized harness.
// swiftlint:disable file_length
@testable import HealthLog
import Synchronization
import Testing
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    @Suite("Workout HR backfill recovery integration", .serialized)
    struct WorkoutHRBackfillRecoveryIntegrationTests {
        @Test("Accepted 11-workout direct page rearms history before its one processing chunk")
        func acceptedSeriesFreePageRearmsHistory() async throws {
            let harness = try Harness(label: "direct-rearm", directPages: [Self.seriesFreePage(count: 11)])
            harness.seedFinishedHistory()

            let didRun = await harness.service.runWorkoutSyncPass(
                repo: harness.repo,
                userID: harness.userID,
                mode: .processing,
                onIngest: nil
            )

            #expect(didRun)
            #expect(await harness.history.requestCount == 1)
            #expect(await harness.history.firstObservedState?.isDone == false)
            #expect(await harness.history.firstObservedState?.cursor == nil)
            #expect(harness.requests.snapshot().map(\.containsSamples) == [false, true])
            #expect(HealthKitService.hasPersistedWorkoutAnchor(userID: harness.userID, defaults: harness.defaults))
        }

        @Test("Persisted rearm resumes at the newest saved boundary after service reconstruction")
        func persistedRearmSurvivesServiceReconstruction() async throws {
            let first = try Harness(label: "reconstruction", directPages: [Self.seriesFreePage(count: 11)])
            first.seedFinishedHistory()

            #expect(await first.runProcessingPass())
            let advanced = WorkoutHRBackfillStore.load(for: first.userID, defaults: first.defaults)
            #expect(advanced.cursor != nil)
            #expect(!advanced.isDone)

            let reconstructed = try Harness(
                label: "reconstruction",
                suite: first.suite,
                keychain: first.keychain,
                requests: first.requests,
                directPages: [[]],
                historyStart: advanced.cursor
            )
            #expect(await reconstructed.runProcessingPass())
            #expect(await reconstructed.history.firstRequestedCursor == advanced.cursor)
            #expect(reconstructed.requests.snapshot().map(\.containsSamples) == [false, true, true])
        }

        @Test("Partial acceptance never rearms a completed history walk")
        func incompleteAcceptanceDoesNotRearm() async throws {
            let harness = try Harness(
                label: "partial",
                directPages: [Self.seriesFreePage(count: 11)],
                directAcceptance: .partial
            )
            harness.seedFinishedHistory()

            _ = await harness.runProcessingPass()

            let state = WorkoutHRBackfillStore.load(for: harness.userID, defaults: harness.defaults)
            #expect(state.isDone)
            #expect(await harness.history.requestCount == 0)
            #expect(!HealthKitService.hasPersistedWorkoutAnchor(userID: harness.userID, defaults: harness.defaults))
        }

        @Test("Token rotation suspended after direct acceptance cannot rearm or query")
        func tokenRotationPreventsRearm() async throws {
            let gate = SuspensionGate()
            let harness = try Harness(
                label: "rotation",
                directPages: [Self.seriesFreePage(count: 11)],
                responseGate: gate
            )
            harness.seedFinishedHistory()
            let service = harness.service
            let repo = harness.repo
            let userID = harness.userID
            let pass = Task {
                await service.runWorkoutSyncPass(
                    repo: repo,
                    userID: userID,
                    mode: .processing,
                    onIngest: nil
                )
            }
            await gate.waitUntilBlocked()

            try harness.keychain.setString("rotated-token", forKey: KeychainKey.authToken)
            gate.release()

            #expect(await pass.value == false)
            #expect(WorkoutHRBackfillStore.load(for: harness.userID, defaults: harness.defaults).isDone)
            #expect(await harness.history.requestCount == 0)
            #expect(!HealthKitService.hasPersistedWorkoutAnchor(userID: harness.userID, defaults: harness.defaults))
        }

        @Test("A-to-B replacement suspended after upload cannot rearm either partition")
        func accountReplacementPreventsCrossPartitionRearm() async throws {
            let gate = SuspensionGate()
            let harness = try Harness(
                label: "account-replacement",
                directPages: [Self.seriesFreePage(count: 11)],
                responseGate: gate
            )
            harness.seedFinishedHistory()
            let service = harness.service
            let repo = harness.repo
            let userID = harness.userID
            let pass = Task {
                await service.runWorkoutSyncPass(
                    repo: repo,
                    userID: userID,
                    mode: .processing,
                    onIngest: nil
                )
            }
            await gate.waitUntilBlocked()

            try harness.keychain.setString("user-B", forKey: KeychainKey.userID)
            try harness.keychain.setString("token-B", forKey: KeychainKey.authToken)
            gate.release()

            #expect(await pass.value == false)
            #expect(WorkoutHRBackfillStore.load(for: harness.userID, defaults: harness.defaults).isDone)
            #expect(WorkoutHRBackfillStore.load(for: "user-B", defaults: harness.defaults) == .init())
            #expect(await harness.history.requestCount == 0)
        }

        @Test("Concrete history source classifies an error-free empty callback as exhaustion")
        func concreteSourceClassifiesEmptyCallback() async {
            let probe = HistoryQueryDriverProbe()
            let source = HealthKitWorkoutHistorySource(store: HKHealthStore(), driver: probe.driver)
            let page = Task {
                await source.page(
                    before: WorkoutHRBackfillCursor(startDate: Date()),
                    limit: WorkoutIngestDTO.maxWorkoutsPerSeriesBatch
                )
            }
            await probe.waitForExecute()
            probe.complete(samples: [], error: nil)

            #expect(await page.value == .exhausted)
            #expect(probe.stopCount == 0)
        }

        @Test("Concrete history source keeps top-level query failures retryable")
        func concreteSourceClassifiesQueryFailure() async {
            let probe = HistoryQueryDriverProbe()
            let source = HealthKitWorkoutHistorySource(store: HKHealthStore(), driver: probe.driver)
            let page = Task {
                await source.page(
                    before: WorkoutHRBackfillCursor(startDate: Date()),
                    limit: WorkoutIngestDTO.maxWorkoutsPerSeriesBatch
                )
            }
            await probe.waitForExecute()
            probe.complete(
                samples: nil,
                error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            )

            #expect(await page.value == .failed(.query))
            #expect(probe.stopCount == 0)
        }

        @Test("Concrete history source cancellation stops its query exactly once")
        func concreteSourceCancellationStopsOnce() async {
            let probe = HistoryQueryDriverProbe()
            let source = HealthKitWorkoutHistorySource(store: HKHealthStore(), driver: probe.driver)
            let page = Task {
                await source.page(
                    before: WorkoutHRBackfillCursor(startDate: Date()),
                    limit: WorkoutIngestDTO.maxWorkoutsPerSeriesBatch
                )
            }
            await probe.waitForExecute()
            page.cancel()

            #expect(await page.value == .cancelled)
            probe.complete(samples: [], error: nil)
            #expect(probe.stopCount == 1)
        }

        @Test("Force-full-sweep consumes pending only after HR rearm and anchor reset")
        func forceSweepConsumesPendingAfterDurableMutations() async throws {
            let history = AuthorizationPendingHistorySource()
            let harness = try Harness(
                label: "pending-consumption",
                directPages: [[]],
                historyOverride: history
            )
            let retained = WorkoutHRBackfillCursor(startDate: Date(timeIntervalSince1970: 1_600_000_000))
            WorkoutHRBackfillStore.save(
                WorkoutHRBackfillState(
                    cursor: retained,
                    isDone: true,
                    nextExhaustionProbeAt: Date.distantFuture,
                    serverSupportsEnrichment: true
                ),
                for: harness.userID,
                defaults: harness.defaults
            )
            harness.defaults.set(
                true,
                forKey: HKReadinessStore.workoutReadRearmPendingKey(for: harness.userID)
            )
            let anchorKey = "hl.workout.hk.anchor." + HealthKitService.partitionToken(for: harness.userID)
            HealthKitAnchorArchive.saveAnchor(
                HKQueryAnchor(fromValue: 42),
                forKey: anchorKey,
                to: harness.defaults,
                label: "workout-test"
            )
            #expect(HealthKitService.hasPersistedWorkoutAnchor(
                userID: harness.userID,
                defaults: harness.defaults
            ))

            await harness.service.startWorkoutImport(
                repo: harness.repo,
                userID: harness.userID,
                forceFullSweep: true,
                onIngest: nil
            )
            await history.waitForRequest()

            let state = WorkoutHRBackfillStore.load(for: harness.userID, defaults: harness.defaults)
            #expect(state.cursor == retained)
            #expect(!state.isDone)
            #expect(!harness.defaults.bool(
                forKey: HKReadinessStore.workoutReadRearmPendingKey(for: harness.userID)
            ))
            #expect(!HealthKitService.hasPersistedWorkoutAnchor(
                userID: harness.userID,
                defaults: harness.defaults
            ))
            await harness.service.stopWorkoutImport()
        }

        @Test("Empty callback cooldown survives reconstruction and uploads at its deadline")
        func cooldownReconstructionResumesAtDeadline() async throws {
            let harness = try Harness(label: "cooldown-chain", directPages: [[]])
            let suite = harness.suite
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let retained = WorkoutHRBackfillCursor(
                startDate: Date(timeIntervalSince1970: 1_600_000_000),
                excludedIdentifiersAtStart: ["boundary"]
            )
            WorkoutHRBackfillStore.save(
                WorkoutHRBackfillState(cursor: retained, serverSupportsEnrichment: true),
                for: harness.userID,
                defaults: harness.defaults
            )
            let emptyProbe = HistoryQueryDriverProbe()
            let emptySource = HealthKitWorkoutHistorySource(
                store: HKHealthStore(),
                driver: emptyProbe.driver
            )
            let firstSweep = WorkoutHRBackfillSweep(
                source: emptySource,
                repo: harness.repo,
                userID: harness.userID,
                clock: { now },
                maxPageRetries: 0,
                defaultsProvider: { UserDefaults(suiteName: suite) ?? .standard }
            )
            let first = Task { await firstSweep.run(maxChunks: 1) }
            await emptyProbe.waitForExecute()
            emptyProbe.complete(samples: [], error: nil)
            #expect(await first.value == .finished)

            let cooling = WorkoutHRBackfillStore.load(for: harness.userID, defaults: harness.defaults)
            let deadline = try #require(cooling.nextExhaustionProbeAt)
            #expect(cooling.cursor == retained)
            let beforeProbe = HistoryQueryDriverProbe()
            let beforeDeadline = WorkoutHRBackfillSweep(
                source: HealthKitWorkoutHistorySource(store: HKHealthStore(), driver: beforeProbe.driver),
                repo: harness.repo,
                userID: harness.userID,
                clock: { deadline.addingTimeInterval(-1) },
                defaultsProvider: { UserDefaults(suiteName: suite) ?? .standard }
            )
            #expect(await beforeDeadline.run(maxChunks: 1) == .notDue)
            #expect(beforeProbe.executeCount == 0)

            let populated = PersistedHistorySource(
                userID: harness.userID,
                suite: suite,
                initialCursor: retained
            )
            let afterDeadline = WorkoutHRBackfillSweep(
                source: populated,
                repo: harness.repo,
                userID: harness.userID,
                clock: { deadline },
                defaultsProvider: { UserDefaults(suiteName: suite) ?? .standard }
            )
            #expect(await afterDeadline.run(maxChunks: 1) == .progressed(enriched: 1))
            let resumed = WorkoutHRBackfillStore.load(for: harness.userID, defaults: harness.defaults)
            #expect(resumed.cursor != retained)
            #expect(!resumed.isDone)
            #expect(resumed.nextExhaustionProbeAt == nil)
            #expect(harness.requests.snapshot().last?.containsSamples == true)
        }

        @Test("Repeated accepted bulk pages finish the active walk then recover every omitted series")
        func repeatedBulkPagesDoNotStarveNewestRestart() async throws {
            let first = Self.seriesFreePage(count: 11, prefix: "bulk-a")
            let second = Self.seriesFreePage(count: 11, prefix: "bulk-b")
            let seriesPages = [
                Array(first.prefix(10)), Array(first.suffix(1)),
                Array(second.prefix(10)), Array(second.suffix(1))
            ].map(Self.withSeries)
            let history = ScriptedHistorySource(steps: [
                .page(seriesPages[0]), .page(seriesPages[1]), .exhausted,
                .page(seriesPages[2]), .page(seriesPages[3]), .exhausted
            ])
            let harness = try Harness(
                label: "repeated-bulk",
                directPages: [first, second, [], [], [], []],
                historyOverride: history
            )
            WorkoutHRBackfillStore.save(
                WorkoutHRBackfillState(
                    cursor: WorkoutHRBackfillCursor(startDate: Date(timeIntervalSince1970: 1_600_000_000)),
                    serverSupportsEnrichment: true
                ),
                for: harness.userID,
                defaults: harness.defaults
            )

            for _ in 0 ..< 6 {
                #expect(await harness.runProcessingPass())
            }

            let seriesRequests = harness.requests.snapshot().filter(\.containsSamples)
            let recovered = Set(seriesRequests.flatMap(\.externalIDs))
            #expect(recovered == Set((first + second).compactMap(\.externalId)))
            #expect(seriesRequests.count == 4)
            #expect(await history.requestCount == 6, "one finite history query per processing pass")
            let final = WorkoutHRBackfillStore.load(for: harness.userID, defaults: harness.defaults)
            #expect(!final.restartFromNewestAfterCurrentWalk)
            #expect(final.isDone)
            #expect(final.nextExhaustionProbeAt != nil)
        }

        private static func withSeries(_ dtos: [WorkoutIngestDTO]) -> [WorkoutIngestDTO] {
            dtos.map { dto in
                WorkoutIngestDTO(
                    sportType: dto.sportType,
                    startedAt: dto.startedAt,
                    endedAt: dto.endedAt,
                    avgHeartRate: dto.avgHeartRate,
                    source: dto.source,
                    externalId: dto.externalId,
                    samples: [.init(t: dto.startedAt, hr: 125)]
                )
            }
        }

        private static func seriesFreePage(count: Int, prefix: String = "direct") -> [WorkoutIngestDTO] {
            (0 ..< count).map { index in
                let start = Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 3600))
                return WorkoutIngestDTO(
                    sportType: "running",
                    startedAt: start,
                    endedAt: start.addingTimeInterval(1800),
                    avgHeartRate: 130,
                    source: "APPLE_HEALTH",
                    externalId: "\(prefix)-\(index)",
                    samples: nil
                )
            }
        }
    }

    private struct Harness {
        enum Acceptance: Equatable {
            case complete
            case partial
        }

        let userID = "recovery-user"
        let suite: String
        let defaults: UserDefaults
        let keychain: InMemoryKeychain
        let requests: RequestCapture
        let history: PersistedHistorySource
        let repo: WorkoutsRepository
        let service: HealthKitService

        init(
            label: String,
            suite: String? = nil,
            keychain: InMemoryKeychain? = nil,
            requests: RequestCapture? = nil,
            directPages: [[WorkoutIngestDTO]],
            historyStart: WorkoutHRBackfillCursor? = nil,
            directAcceptance: Acceptance = .complete,
            responseGate: SuspensionGate? = nil,
            historyOverride: (any WorkoutHRBackfillSourcing)? = nil
        ) throws {
            let suite = suite ?? "hl.test.recovery.\(label).\(UUID().uuidString)"
            self.suite = suite
            defaults = try #require(UserDefaults(suiteName: suite))
            if keychain == nil {
                defaults.removePersistentDomain(forName: suite)
            }
            let keychain = keychain ?? InMemoryKeychain()
            self.keychain = keychain
            try keychain.setString(userID, forKey: KeychainKey.userID)
            try keychain.setString("token-A", forKey: KeychainKey.authToken)
            let requests = requests ?? RequestCapture()
            self.requests = requests

            let directProvider = DirectDTOProvider(pages: directPages)
            history = PersistedHistorySource(
                userID: userID,
                suite: suite,
                initialCursor: historyStart
            )

            let environment = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local"),
                bundleID: "dev.healthlog.app",
                appVersion: "0.19.0",
                buildNumber: "1"
            )
            let api = APIClient(
                environment: environment,
                keychain: keychain,
                sessionConfiguration: .mock()
            )
            repo = try WorkoutsRepository(api: api, outbox: OutboxQueue(inMemory: true))

            MockURLProtocol.handler = { request in
                let body = Self.body(of: request)
                let containsSamples = String(data: body, encoding: .utf8)?.contains(#""samples""#) == true
                let externalIDs = Self.externalIDs(in: body)
                requests.append(
                    containsSamples: containsSamples,
                    externalIDs: externalIDs
                )
                let isDirectPage = !containsSamples
                if isDirectPage { responseGate?.block() }
                let postedCount = externalIDs.count
                let acceptedCount = directAcceptance == .partial && isDirectPage ? postedCount - 1 : postedCount
                let entries = (0 ..< acceptedCount).map { entryIndex in
                    #"{"index":\#(entryIndex),"status":"\#(isDirectPage ? "inserted" : "enriched")"}"#
                }.joined(separator: ",")
                let json = #"{"processed":\#(acceptedCount),"inserted":\#(isDirectPage ? acceptedCount : 0),"duplicates":0,"entries":[\#(entries)]}"#
                return Self.respond(request, json)
            }

            service = HealthKitService(
                store: HKHealthStore(),
                keychain: keychain,
                bundleID: "dev.healthlog.app",
                defaultsSuiteName: suite,
                workoutSyncDependencies: WorkoutSyncDependencies(
                    lifecycleStore: ImmediateWorkoutLifecycleStore(),
                    anchoredQuerySource: EmptyWorkoutAnchoredSource(
                        fetchedCount: directPages.first?.count ?? 0,
                        newAnchor: HKQueryAnchor(fromValue: 1)
                    ),
                    directDTOProvider: { await directProvider.next() },
                    historySource: historyOverride ?? history
                )
            )
        }

        func seedFinishedHistory() {
            WorkoutHRBackfillStore.save(
                WorkoutHRBackfillState(
                    cursor: WorkoutHRBackfillCursor(startDate: Date(timeIntervalSince1970: 1_600_000_000)),
                    isDone: true,
                    nextExhaustionProbeAt: Date.distantFuture,
                    serverSupportsEnrichment: true,
                    enrichedCount: 4
                ),
                for: userID,
                defaults: defaults
            )
        }

        func runProcessingPass() async -> Bool {
            await service.runWorkoutSyncPass(
                repo: repo,
                userID: userID,
                mode: .processing,
                onIngest: nil
            )
        }

        private static func body(of request: URLRequest) -> Data {
            request.httpBody ?? request.httpBodyStream.map { stream in
                stream.open()
                defer { stream.close() }
                var data = Data()
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let count = stream.read(buffer, maxLength: 4096)
                    guard count > 0 else { break }
                    data.append(buffer, count: count)
                }
                return data
            } ?? Data()
        }

        private static func externalIDs(in body: Data) -> [String] {
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let workouts = json["workouts"] as? [[String: Any]] else { return [] }
            return workouts.compactMap { $0["externalId"] as? String }
        }

        private static func respond(_ request: URLRequest, _ json: String) -> (HTTPURLResponse, Data?) {
            // swiftlint:disable force_unwrapping
            let response = HTTPURLResponse(
                url: request.url ?? URL(fileURLWithPath: "/"),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            // swiftlint:enable force_unwrapping
            return (response, Data(#"{"data":\#(json),"error":null}"#.utf8))
        }
    }

    private actor DirectDTOProvider {
        private var pages: [[WorkoutIngestDTO]]

        init(pages: [[WorkoutIngestDTO]]) {
            self.pages = pages
        }

        func next() -> [WorkoutIngestDTO] {
            pages.isEmpty ? [] : pages.removeFirst()
        }
    }

    private actor PersistedHistorySource: WorkoutHRBackfillSourcing {
        private let userID: String
        private let suite: String
        private let initialCursor: WorkoutHRBackfillCursor?
        private(set) var requestCount = 0
        private(set) var firstObservedState: WorkoutHRBackfillState?
        private(set) var firstRequestedCursor: WorkoutHRBackfillCursor?

        init(userID: String, suite: String, initialCursor: WorkoutHRBackfillCursor?) {
            self.userID = userID
            self.suite = suite
            self.initialCursor = initialCursor
        }

        func page(before cursor: WorkoutHRBackfillCursor, limit _: Int) -> WorkoutHRBackfillPageOutcome {
            requestCount += 1
            if firstRequestedCursor == nil { firstRequestedCursor = cursor }
            if let defaults = UserDefaults(suiteName: suite), firstObservedState == nil {
                firstObservedState = WorkoutHRBackfillStore.load(for: userID, defaults: defaults)
            }
            let start = cursor.startDate.addingTimeInterval(-3600)
            let dto = WorkoutIngestDTO(
                sportType: "running",
                startedAt: start,
                endedAt: start.addingTimeInterval(1800),
                avgHeartRate: 130,
                source: "APPLE_HEALTH",
                externalId: "history-\(requestCount)",
                samples: [.init(t: start, hr: 120)]
            )
            return .page(WorkoutHRBackfillPage(
                workouts: [dto],
                oldestStart: start,
                oldestStartIdentifiers: [dto.externalId ?? "history"],
                fetchedCount: 1
            ))
        }
    }

    private actor EmptyWorkoutAnchoredSource: WorkoutAnchoredQueryFetching {
        private let fetchedCount: Int
        private let newAnchor: HKQueryAnchor?

        init(fetchedCount: Int, newAnchor: HKQueryAnchor?) {
            self.fetchedCount = fetchedCount
            self.newAnchor = newAnchor
        }

        func fetch(anchor _: HKQueryAnchor?, limit _: Int) async throws -> WorkoutAnchoredQueryPage {
            WorkoutAnchoredQueryPage(workouts: [], newAnchor: newAnchor, fetchedCount: fetchedCount)
        }
    }

    private actor ImmediateWorkoutLifecycleStore: WorkoutHealthKitStore {
        func executeWorkoutObserver(onUpdate _: @escaping @Sendable () -> Void) async {}
        func stopWorkoutObserver() async {}
        func enableWorkoutBackgroundDelivery() async throws {}
        func disableWorkoutBackgroundDelivery() async throws {}
    }

    private actor AuthorizationPendingHistorySource: WorkoutHRBackfillSourcing {
        private var requestCount = 0

        func page(
            before _: WorkoutHRBackfillCursor,
            limit _: Int
        ) async -> WorkoutHRBackfillPageOutcome {
            requestCount += 1
            return .authorizationPending
        }

        func waitForRequest() async {
            while requestCount == 0 {
                await Task.yield()
            }
        }
    }

    private actor ScriptedHistorySource: WorkoutHRBackfillSourcing {
        enum Step: Sendable {
            case page([WorkoutIngestDTO])
            case exhausted
        }

        private var steps: [Step]
        private(set) var requestCount = 0

        init(steps: [Step]) {
            self.steps = steps
        }

        func page(
            before cursor: WorkoutHRBackfillCursor,
            limit: Int
        ) async -> WorkoutHRBackfillPageOutcome {
            requestCount += 1
            guard !steps.isEmpty else { return .exhausted }
            switch steps.removeFirst() {
            case let .page(workouts):
                let bounded = Array(workouts.prefix(limit))
                let oldest = bounded.map(\.startedAt).min() ?? cursor.startDate.addingTimeInterval(-1)
                return .page(WorkoutHRBackfillPage(
                    workouts: bounded,
                    oldestStart: oldest,
                    oldestStartIdentifiers: Set(bounded.compactMap(\.externalId)),
                    fetchedCount: bounded.count
                ))
            case .exhausted:
                return .exhausted
            }
        }
    }

    private struct CapturedRequest: Sendable {
        let containsSamples: Bool
        let externalIDs: [String]
    }

    private final class RequestCapture: Sendable {
        private let values = Mutex<[CapturedRequest]>([])

        func append(containsSamples: Bool, externalIDs: [String]) {
            values.withLock {
                $0.append(CapturedRequest(containsSamples: containsSamples, externalIDs: externalIDs))
            }
        }

        func snapshot() -> [CapturedRequest] {
            values.withLock { $0 }
        }
    }

    private final class SuspensionGate: @unchecked Sendable {
        private let condition = NSCondition()
        private let blockedSnapshot = Mutex(false)
        private var blocked = false
        private var released = false

        func block() {
            condition.lock()
            blocked = true
            blockedSnapshot.withLock { $0 = true }
            condition.broadcast()
            while !released {
                condition.wait()
            }
            condition.unlock()
        }

        func waitUntilBlocked() async {
            while !blockedSnapshot.withLock({ $0 }) {
                await Task.yield()
            }
        }

        func release() {
            condition.lock()
            released = true
            condition.broadcast()
            condition.unlock()
        }
    }

    private final class HistoryQueryDriverProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var completion: WorkoutHistoryQueryDriver.Completion?
        private var _executeCount = 0
        private var _stopCount = 0

        var driver: WorkoutHistoryQueryDriver {
            WorkoutHistoryQueryDriver(
                makeQuery: { [self] _, _, _, completion in
                    lock.withLock { self.completion = completion }
                    return HKSampleQuery(
                        sampleType: HKObjectType.workoutType(),
                        predicate: nil,
                        limit: 1,
                        sortDescriptors: nil
                    ) { _, _, _ in }
                },
                execute: { [self] _ in lock.withLock { _executeCount += 1 } },
                stop: { [self] _ in lock.withLock { _stopCount += 1 } }
            )
        }

        var stopCount: Int {
            lock.withLock { _stopCount }
        }

        var executeCount: Int {
            lock.withLock { _executeCount }
        }

        func waitForExecute() async {
            while lock.withLock({ _executeCount }) == 0 {
                await Task.yield()
            }
        }

        func complete(samples: [HKSample]?, error: (any Error)?) {
            lock.withLock { completion }?(samples, error)
        }
    }

#endif
