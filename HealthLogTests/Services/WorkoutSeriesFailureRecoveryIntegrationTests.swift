import Foundation
@testable import HealthLog
import Synchronization
import Testing
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    @Suite("Workout series failure recovery integration", .serialized)
    struct WorkoutSeriesFailureRecoveryIntegrationTests {
        @Test("Direct query failure sends nothing and retry attaches samples before anchor progress")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func directFailureRetriesSamePage() async throws {
            let harness = try DirectHarness(label: "failure-retry", results: [
                .failed,
                .samples([WorkoutHRSample(timestamp: WorkoutSeriesFixtures.start, bpm: 132)])
            ])

            _ = await harness.importer.runBoundedPage(mode: .incrementalOnly)

            #expect(harness.requests.isEmpty)
            #expect(!HealthKitService.hasPersistedWorkoutAnchor(
                userID: harness.userID,
                defaults: harness.defaults
            ))

            _ = await harness.importer.runBoundedPage(mode: .incrementalOnly)

            #expect(await harness.source.requestCount == 2)
            #expect(await harness.source.onlyRequestedNilAnchors)
            #expect(harness.requests.count == 1)
            let body = try #require(harness.requests.bodies.first)
            #expect(try Self.sampleCount(in: body) == 1)
            #expect(HealthKitService.hasPersistedWorkoutAnchor(
                userID: harness.userID,
                defaults: harness.defaults
            ))
            await harness.importer.stop()
        }

        @Test("History query failure retains cursor and retry posts samples before progress")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func historyFailureRetriesSameCursor() async throws {
            let suite = "hl.test.series.history.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            let userID = "history-user"
            let cursor = WorkoutHRBackfillCursor(startDate: WorkoutSeriesFixtures.start.addingTimeInterval(600))
            WorkoutHRBackfillStore.save(
                WorkoutHRBackfillState(cursor: cursor, serverSupportsEnrichment: true),
                for: userID,
                defaults: defaults
            )
            let keychain = InMemoryKeychain()
            try keychain.setString(userID, forKey: KeychainKey.userID)
            try keychain.setString("token-A", forKey: KeychainKey.authToken)
            let requests = WorkoutSeriesRequestCapture()
            Self.installAcceptedResponse(capture: requests, status: "enriched")
            let repo = try Self.repository(keychain: keychain)
            let seriesDriver = WorkoutSeriesScriptedDriver(results: [
                .failed,
                .samples([WorkoutHRSample(timestamp: WorkoutSeriesFixtures.start, bpm: 128)])
            ])
            let historyDriver = WorkoutSeriesHistoryDriver(workout: WorkoutSeriesFixtures.workout())
            let source = HealthKitWorkoutHistorySource(
                store: HKHealthStore(),
                series: HealthKitWorkoutDetailService(queryDriver: seriesDriver),
                driver: historyDriver.driver
            )

            let first = WorkoutHRBackfillSweep(
                source: source,
                repo: repo,
                userID: userID,
                maxPageRetries: 0,
                defaultsProvider: { UserDefaults(suiteName: suite) ?? .standard }
            )
            #expect(await first.run(maxChunks: 1) == .failed)
            #expect(requests.isEmpty)
            #expect(WorkoutHRBackfillStore.load(for: userID, defaults: defaults).cursor == cursor)

            let second = WorkoutHRBackfillSweep(
                source: source,
                repo: repo,
                userID: userID,
                maxPageRetries: 0,
                defaultsProvider: { UserDefaults(suiteName: suite) ?? .standard }
            )
            #expect(await second.run(maxChunks: 1) == .progressed(enriched: 1))
            #expect(requests.count == 1)
            let body = try #require(requests.bodies.first)
            #expect(try Self.sampleCount(in: body) == 1)
            #expect(WorkoutHRBackfillStore.load(for: userID, defaults: defaults).cursor != cursor)
        }

        @Test("Direct cancellation stops the suspended series query without upload or anchor progress")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func directCancellationRetainsAnchor() async throws {
            let driver = WorkoutSeriesBlockingDriver()
            let harness = try DirectHarness(label: "cancel", driver: driver)
            let importer = harness.importer
            let pass = Task {
                await importer.runBoundedPage(mode: .incrementalOnly)
            }
            await driver.waitForStart()

            pass.cancel()

            #expect(await pass.value == .notRun)
            #expect(driver.stopCount == 1)
            #expect(harness.requests.isEmpty)
            #expect(!HealthKitService.hasPersistedWorkoutAnchor(
                userID: harness.userID,
                defaults: harness.defaults
            ))
            await importer.stop()
        }

        @Test("Successful empty direct series rearms before complete accepted progress")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func directEmptySeriesRearmsBeforeAnchor() async throws {
            let rearmCount = Mutex(0)
            let harness = try DirectHarness(
                label: "empty-rearm",
                driver: WorkoutSeriesScriptedDriver(results: [.samples([])]),
                beforeSeriesFreeAnchorAdvance: { count in
                    rearmCount.withLock { $0 += count }
                    return true
                }
            )

            #expect(await (harness.importer.runBoundedPage(mode: .incrementalOnly)).didRun)
            #expect(rearmCount.withLock { $0 } == 1)
            #expect(harness.requests.count == 1)
            let body = try #require(harness.requests.bodies.first)
            #expect(try Self.sampleCount(in: body) == 0)
            #expect(HealthKitService.hasPersistedWorkoutAnchor(
                userID: harness.userID,
                defaults: harness.defaults
            ))
            await harness.importer.stop()
        }

        @Test("History cancellation leaves the captured partition unchanged")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func historyCancellationRetainsCursor() async throws {
            let suite = "hl.test.series.history-cancel.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            let userID = "history-cancel-user"
            let cursor = WorkoutHRBackfillCursor(startDate: WorkoutSeriesFixtures.start.addingTimeInterval(600))
            let initial = WorkoutHRBackfillState(cursor: cursor, serverSupportsEnrichment: true)
            WorkoutHRBackfillStore.save(initial, for: userID, defaults: defaults)
            let driver = WorkoutSeriesBlockingDriver()
            let source = HealthKitWorkoutHistorySource(
                store: HKHealthStore(),
                series: HealthKitWorkoutDetailService(queryDriver: driver),
                driver: WorkoutSeriesHistoryDriver(workout: WorkoutSeriesFixtures.workout()).driver
            )
            let sweep = WorkoutHRBackfillSweep(
                source: source,
                repo: NoRequestWorkoutSeriesUploader(),
                userID: userID,
                defaultsProvider: { UserDefaults(suiteName: suite) ?? .standard }
            )
            let pass = Task { await sweep.run(maxChunks: 1) }
            await driver.waitForStart()

            pass.cancel()

            #expect(await pass.value == .cancelled)
            #expect(driver.stopCount == 1)
            #expect(WorkoutHRBackfillStore.load(for: userID, defaults: defaults) == initial)
        }

        @Test("History empty cooldown survives reconstruction and retries the same cursor with samples")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func historyEmptyRetriesAfterCooldown() async throws {
            let suite = "hl.test.series.history-empty.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            let userID = "history-empty-user"
            let cursor = WorkoutHRBackfillCursor(startDate: WorkoutSeriesFixtures.start.addingTimeInterval(600))
            WorkoutHRBackfillStore.save(
                WorkoutHRBackfillState(cursor: cursor, serverSupportsEnrichment: true),
                for: userID,
                defaults: defaults
            )
            let keychain = InMemoryKeychain()
            try keychain.setString(userID, forKey: KeychainKey.userID)
            try keychain.setString("token-A", forKey: KeychainKey.authToken)
            let requests = WorkoutSeriesRequestCapture()
            Self.installAcceptedResponse(capture: requests, status: "enriched")
            let now = Mutex(Date(timeIntervalSince1970: 1_700_001_000))
            let source = HealthKitWorkoutHistorySource(
                store: HKHealthStore(),
                series: HealthKitWorkoutDetailService(queryDriver: WorkoutSeriesScriptedDriver(results: [
                    .samples([]),
                    .samples([WorkoutHRSample(timestamp: WorkoutSeriesFixtures.start, bpm: 126)])
                ])),
                driver: WorkoutSeriesHistoryDriver(workout: WorkoutSeriesFixtures.workout()).driver
            )
            let first = try WorkoutHRBackfillSweep(
                source: source,
                repo: Self.repository(keychain: keychain),
                userID: userID,
                clock: { now.withLock { $0 } },
                defaultsProvider: { UserDefaults(suiteName: suite) ?? .standard }
            )

            #expect(await first.run(maxChunks: 1) == .finished)
            let cooling = WorkoutHRBackfillStore.load(for: userID, defaults: defaults)
            #expect(cooling.cursor == cursor)
            #expect(requests.isEmpty)
            now.withLock { $0 = cooling.nextExhaustionProbeAt ?? $0 }

            let reconstructed = try WorkoutHRBackfillSweep(
                source: source,
                repo: Self.repository(keychain: keychain),
                userID: userID,
                clock: { now.withLock { $0 } },
                defaultsProvider: { UserDefaults(suiteName: suite) ?? .standard }
            )
            #expect(await reconstructed.run(maxChunks: 1) == .progressed(enriched: 1))
            #expect(requests.count == 1)
            let body = try #require(requests.bodies.first)
            #expect(try Self.sampleCount(in: body) == 1)
            #expect(WorkoutHRBackfillStore.load(for: userID, defaults: defaults).cursor != cursor)
        }

        private static func repository(keychain: InMemoryKeychain) throws -> WorkoutsRepository {
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
            return try WorkoutsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        }

        private static func installAcceptedResponse(capture: WorkoutSeriesRequestCapture, status: String) {
            MockURLProtocol.handler = { request in
                guard request.url?.path == "/api/workouts/batch" else {
                    throw URLError(.unsupportedURL)
                }
                guard let responseURL = request.url,
                      let response = HTTPURLResponse(
                          url: responseURL,
                          statusCode: 200,
                          httpVersion: nil,
                          headerFields: ["Content-Type": "application/json"]
                      ) else
                {
                    throw URLError(.badServerResponse)
                }
                capture.append(Self.body(of: request))
                let json = #"{"processed":1,"inserted":0,"duplicates":0,"entries":[{"index":0,"status":"\#(status)"}]}"#
                return (
                    response,
                    Data(json.utf8)
                )
            }
        }

        private static func body(of request: URLRequest) -> Data {
            request.httpBody ?? request.httpBodyStream.map { stream in
                stream.open()
                defer { stream.close() }
                var body = Data()
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let count = stream.read(buffer, maxLength: 4096)
                    guard count > 0 else { break }
                    body.append(buffer, count: count)
                }
                return body
            } ?? Data()
        }

        private static func sampleCount(in data: Data) throws -> Int {
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let workouts = object?["workouts"] as? [[String: Any]]
            return (workouts?.first?["samples"] as? [[String: Any]])?.count ?? 0
        }

        private struct DirectHarness {
            let userID = "direct-user"
            let defaults: UserDefaults
            let requests: WorkoutSeriesRequestCapture
            let source: WorkoutSeriesAnchoredSource
            let importer: WorkoutHealthKitImporter

            @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
            init(label: String, results: [HealthKitHeartRateQueryResult]) throws {
                try self.init(
                    label: label,
                    driver: WorkoutSeriesScriptedDriver(results: results)
                )
            }

            @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
            init(
                label: String,
                driver: any HealthKitHeartRateQueryDriving,
                beforeSeriesFreeAnchorAdvance: @escaping @Sendable (Int) async -> Bool = { _ in true }
            ) throws {
                let suite = "hl.test.series.direct.\(label).\(UUID().uuidString)"
                defaults = try #require(UserDefaults(suiteName: suite))
                defaults.removePersistentDomain(forName: suite)
                let keychain = InMemoryKeychain()
                try keychain.setString(userID, forKey: KeychainKey.userID)
                try keychain.setString("token-A", forKey: KeychainKey.authToken)
                requests = WorkoutSeriesRequestCapture()
                installAcceptedResponse(capture: requests, status: "inserted")
                let repo = try repository(keychain: keychain)
                source = WorkoutSeriesAnchoredSource(workout: WorkoutSeriesFixtures.workout())
                let service = HealthKitWorkoutDetailService(
                    queryDriver: driver
                )
                importer = WorkoutHealthKitImporter(
                    store: HKHealthStore(),
                    repo: repo,
                    userID: userID,
                    defaultsBox: WorkoutDefaultsBox(suiteName: suite),
                    series: service,
                    lifecycleStore: WorkoutSeriesLifecycleStore(),
                    anchoredQuerySource: source,
                    beforeSeriesFreeAnchorAdvance: beforeSeriesFreeAnchorAdvance
                )
            }
        }
    }

    final class WorkoutSeriesScriptedDriver: HealthKitHeartRateQueryDriving, Sendable {
        private let state: Mutex<[HealthKitHeartRateQueryResult]>

        init(results: [HealthKitHeartRateQueryResult]) {
            state = Mutex(results)
        }

        func start(
            id _: UUID,
            from _: Date,
            to _: Date,
            limit _: Int,
            completion: @escaping @Sendable (HealthKitHeartRateQueryResult) -> Void
        ) {
            let result = state.withLock { values in
                values.isEmpty ? .failed : values.removeFirst()
            }
            completion(result)
        }

        func stop(id _: UUID) {}
    }

    final class WorkoutSeriesBlockingDriver: HealthKitHeartRateQueryDriving, Sendable {
        private struct State {
            var startCount = 0
            var stopCount = 0
        }

        private let state = Mutex(State())

        func start(
            id _: UUID,
            from _: Date,
            to _: Date,
            limit _: Int,
            completion _: @escaping @Sendable (HealthKitHeartRateQueryResult) -> Void
        ) {
            state.withLock { $0.startCount += 1 }
        }

        func stop(id _: UUID) {
            state.withLock { $0.stopCount += 1 }
        }

        func waitForStart() async {
            while state.withLock({ $0.startCount }) == 0 {
                await Task.yield()
            }
        }

        var stopCount: Int {
            state.withLock { $0.stopCount }
        }
    }

    enum WorkoutSeriesFixtures {
        static let start = Date(timeIntervalSince1970: 1_700_000_000)

        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        static func workout(start: Date = start) -> HKWorkout {
            HKWorkout(
                activityType: .running,
                start: start,
                end: start.addingTimeInterval(60)
            )
        }
    }

    actor WorkoutSeriesAnchoredSource: WorkoutAnchoredQueryFetching {
        private let workout: HKWorkout
        private(set) var requestedAnchors: [HKQueryAnchor?] = []

        init(workout: HKWorkout) {
            self.workout = workout
        }

        func fetch(anchor: HKQueryAnchor?, limit _: Int) async throws -> WorkoutAnchoredQueryPage {
            requestedAnchors.append(anchor)
            return WorkoutAnchoredQueryPage(
                workouts: [workout],
                newAnchor: HKQueryAnchor(fromValue: requestedAnchors.count)
            )
        }

        var requestCount: Int {
            requestedAnchors.count
        }

        var onlyRequestedNilAnchors: Bool {
            requestedAnchors.allSatisfy { $0 == nil }
        }
    }

    actor WorkoutSeriesLifecycleStore: WorkoutHealthKitStore {
        func executeWorkoutObserver(onUpdate _: @escaping @Sendable () -> Void) async {}
        func stopWorkoutObserver() async {}
        func enableWorkoutBackgroundDelivery() async throws {}
        func disableWorkoutBackgroundDelivery() async throws {}
    }

    actor NoRequestWorkoutSeriesUploader: WorkoutBatchUploading {
        func uploadBatch(
            _: [WorkoutIngestDTO],
            ownerUserID _: String
        ) async throws -> WorkoutBatchResponseDTO {
            Issue.record("cancelled series query unexpectedly reached upload")
            throw CancellationError()
        }
    }

    final class WorkoutSeriesHistoryDriver: Sendable {
        private struct State {
            var completion: WorkoutHistoryQueryDriver.Completion?
        }

        private let workout: HKWorkout
        private let state = Mutex(State())

        init(workout: HKWorkout) {
            self.workout = workout
        }

        var driver: WorkoutHistoryQueryDriver {
            WorkoutHistoryQueryDriver(
                makeQuery: { [self] _, _, _, completion in
                    state.withLock { $0.completion = completion }
                    return HKSampleQuery(
                        sampleType: HKObjectType.workoutType(),
                        predicate: nil,
                        limit: 1,
                        sortDescriptors: nil
                    ) { _, _, _ in }
                },
                execute: { [self] _ in
                    let completion = state.withLock { $0.completion }
                    completion?([workout], nil)
                },
                stop: { _ in }
            )
        }
    }

    final class WorkoutSeriesRequestCapture: Sendable {
        private let storage = Mutex<[Data]>([])

        func append(_ body: Data) {
            storage.withLock { $0.append(body) }
        }

        var bodies: [Data] {
            storage.withLock { $0 }
        }

        var count: Int {
            storage.withLock { $0.count }
        }

        var isEmpty: Bool {
            storage.withLock { $0.isEmpty }
        }
    }

#endif
