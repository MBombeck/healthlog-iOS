import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

#if canImport(HealthKit)

    /// #115 / 0.3 (A5) — the three loss paths A3 found and named, each driven
    /// against the real `APIClient` over `MockURLProtocol` with the envelope
    /// shapes the v1.39.0 routes send (`meta.errorCode`, or none at all for a
    /// Zod 422).
    ///
    /// 1. Cycle import: a 403 `cycle.disabled` used to queue the page and let
    ///    the anchor move behind rows the server refused.
    /// 2. Heart events: a whole-batch 4xx used to queue the page, commit the
    ///    anchor, and the replay then deleted the row on the same 4xx.
    /// 3. Daily statistics: a HealthKit query that threw counted as a read
    ///    window and moved the sweep end past it.
    @Suite("HealthKit loss paths — module off, whole-batch 4xx, failed read", .serialized, .mockURLSession)
    struct HealthKitLossPathTests {
        static let owner = "account-a5"

        private static let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.0.4",
            buildNumber: "1"
        )

        /// Retained on purpose — the lease holds the registry weakly.
        private struct Admitted {
            let registry: AuthenticatedSessionLeaseRegistry
            let lease: HealthSyncAuthenticatedLease
        }

        private func admit(_ source: HealthSyncSource) throws -> Admitted {
            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.owner)
            let lease = try HealthSyncAuthenticatedLease.admit(
                from: registry,
                ownerID: Self.owner,
                source: source,
                bearerProvider: { "bearer-a" }
            )
            return Admitted(registry: registry, lease: lease)
        }

        private func makeAPI() -> APIClient {
            let keychain = InMemoryKeychain()
            try? keychain.setString("bearer-a", forKey: KeychainKey.authToken)
            try? keychain.setString(Self.owner, forKey: KeychainKey.userID)
            return APIClient(environment: Self.env, keychain: keychain, sessionConfiguration: .mock())
        }

        private func respond(status: Int, _ json: @escaping @Sendable () -> String) {
            MockURLProtocol.install { req in
                let response = HTTPURLResponse(
                    url: req.url!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(json().utf8))
            }
        }

        private func respond(_ answers: @escaping @Sendable () -> (Int, String)) {
            MockURLProtocol.install { req in
                let (status, json) = answers()
                let response = HTTPURLResponse(
                    url: req.url!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(json.utf8))
            }
        }

        private static func decide(_ page: HealthSyncPageOutcome) -> HealthSyncCommitDecision {
            HealthSyncCursorPolicy.installed.decide(page)
        }

        private static func isolatedDefaults() -> UserDefaults {
            UserDefaults(suiteName: "hk-loss-paths-\(UUID().uuidString)")!
        }

        // MARK: - 1. Cycle module off

        /// `requireCycleEnabled` in `src/lib/cycle/gate.ts` (v1.39.0).
        private static let cycleDisabled =
            #"{"data":null,"error":"Cycle tracking is not enabled","meta":{"errorCode":"cycle.disabled"}}"#

        private static func cycleWrite(_ date: String) -> CycleDayLogWrite {
            CycleDayLogWrite(
                date: date,
                flow: .medium,
                loggedAt: "\(date)T08:00:00Z",
                source: "APPLE_HEALTH",
                externalId: "cycle-hk:\(date)"
            )
        }

        @Test("403 cycle.disabled holds the anchor with nothing queued, and the page imports once the module is on")
        func cycleModuleOffHoldsTheAnchor() async throws {
            let admitted = try admit(.cycle)
            let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
            let importer = CycleHealthKitImporter(
                store: HKHealthStore(),
                repo: CycleRepository(api: makeAPI(), outbox: outbox),
                userID: Self.owner,
                defaults: Self.isolatedDefaults()
            )
            let writes = [Self.cycleWrite("2026-09-01"), Self.cycleWrite("2026-09-02")]

            respond(status: 403) { Self.cycleDisabled }
            let held = await importer.drain(writes, requiring: admitted.lease)

            #expect(await outbox.snapshot.isEmpty, "a refused page must not become a row the replay can delete")
            #expect(!held.durableRetryPersisted)
            #expect(Self.decide(held) == .hold(reason: .nonterminalEntry))

            // The module is switched on: the same window, read again, lands.
            respond(status: 200) {
                #"{"data":{"entries":[{"index":0,"status":"inserted"},{"index":1,"status":"inserted"}]},"error":null}"#
            }
            let landed = await importer.drain(writes, requiring: admitted.lease)
            #expect(Self.decide(landed) == .commit)
            #expect(!landed.hasNonterminalEntry)
        }

        // MARK: - 2. Heart events, whole-batch 4xx

        /// `apiValidationError` in `src/lib/api-response.ts` (v1.39.0): the
        /// batch route's Zod failure carries no `errorCode`.
        private static let zodFailure =
            #"{"data":null,"error":"Expected number, received string","details":{"issues":[{"path":["entries",0,"value"],"message":"Expected number"}]}}"#

        /// The route's own named refusal (`measurement.batch.too_large`).
        private static let tooLarge =
            #"{"data":null,"error":"Batch exceeds the 500-entry limit","meta":{"errorCode":"measurement.batch.too_large"}}"#

        private static let accepted =
            #"{"data":{"processed":2,"inserted":2,"duplicates":0,"skipped":[],"entries":[{"index":0,"status":"inserted"},{"index":1,"status":"inserted"}]},"error":null}"#

        private static func events(_ identities: [String]) -> [HealthKitBatchEntryDTO] {
            identities.enumerated().map { index, identity in
                HealthKitBatchEntryDTO(
                    hkIdentifier: HKCategoryTypeIdentifier.irregularHeartRhythmEvent.rawValue,
                    value: 1,
                    unit: "event",
                    startDate: Date(timeIntervalSince1970: TimeInterval(1_790_000_000 + index)),
                    endDate: Date(timeIntervalSince1970: TimeInterval(1_790_000_000 + index)),
                    categoryValue: 1,
                    externalId: identity
                )
            }
        }

        private func makeUploader() -> MeasurementBatchUploader {
            MeasurementBatchUploader(
                api: makeAPI(),
                throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0),
                syncTrigger: SyncTriggerContext(),
                authenticationSnapshot: {
                    MeasurementUploadAuthenticationSnapshot(ownerUserID: Self.owner, bearerToken: "bearer-a")
                }
            )
        }

        private func makeHeartImporter(
            lease: HealthSyncAuthenticatedLease,
            retry: RecordingStatsRetryQueue,
            suiteName: String
        ) -> HeartHealthEventImporter {
            HeartHealthEventImporter(
                store: HKHealthStore(),
                uploader: makeUploader(),
                userID: Self.owner,
                defaults: UserDefaults(suiteName: suiteName)!,
                admission: { lease },
                cursors: nil,
                retry: retry
            )
        }

        @Test("a whole-batch 422 without a code holds the anchor and queues nothing")
        func heartEventUnexplained422Holds() async throws {
            respond(status: 422) { Self.zodFailure }
            let admitted = try admit(.heartEvent)
            let retry = RecordingStatsRetryQueue()
            let suiteName = "hk-loss-paths-\(UUID().uuidString)"
            let importer = makeHeartImporter(lease: admitted.lease, retry: retry, suiteName: suiteName)
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)

            let page = await HealthKitSkippedRowRegister.$bound.withValue(register) {
                await importer.transmit(Self.events(["evt-1", "evt-2"]), requiring: admitted.lease)
            }

            #expect(await retry.enqueueCount() == 0, "a queued row would be deleted by the replay on the same 422")
            #expect(page.entries.allSatisfy { $0.classification == .nonterminal })
            #expect(Self.decide(page) == .hold(reason: .nonterminalEntry))
            #expect(await register.count(ownerID: Self.owner) == 0, "an unexplained 4xx is not a refusal")
        }

        @Test("a whole-batch refusal the route names is registered before the window moves")
        func heartEventNamedRefusalIsRegistered() async throws {
            respond(status: 422) { Self.tooLarge }
            let admitted = try admit(.heartEvent)
            let retry = RecordingStatsRetryQueue()
            let suiteName = "hk-loss-paths-\(UUID().uuidString)"
            let importer = makeHeartImporter(lease: admitted.lease, retry: retry, suiteName: suiteName)
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)

            let page = await HealthKitSkippedRowRegister.$bound.withValue(register) {
                await importer.transmit(Self.events(["evt-1", "evt-2"]), requiring: admitted.lease)
            }

            let rows = await register.rows(ownerID: Self.owner).sorted { $0.id < $1.id }
            #expect(rows.map(\.id) == ["evt-1", "evt-2"])
            #expect(rows.allSatisfy { $0.reason == "422:measurement.batch.too_large" })
            #expect(rows.first?.hkIdentifier == HKCategoryTypeIdentifier.irregularHeartRhythmEvent.rawValue)
            #expect(await retry.enqueueCount() == 0)
            #expect(Self.decide(page) == .commit)
            // Another account on the same device sees none of it.
            #expect(await register.count(ownerID: "account-b") == 0)
        }

        /// INT-A (c) — an unexplained whole-batch 4xx may hold the type's anchor
        /// for at most `maxHeldSweeps` consecutive sweeps; then the rows go into
        /// the skip register as `unclassified_4xx:<status>` and the window moves.
        @Test("an unexplained 422 holds for a bounded number of sweeps, then is registered and released")
        func heartEventUnexplained422IsBounded() async throws {
            respond(status: 422) { Self.zodFailure }
            let admitted = try admit(.heartEvent)
            let retry = RecordingStatsRetryQueue()
            let suiteName = "hk-loss-paths-\(UUID().uuidString)"
            let importer = makeHeartImporter(lease: admitted.lease, retry: retry, suiteName: suiteName)
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
            let events = Self.events(["evt-b1", "evt-b2"])

            await HealthKitSkippedRowRegister.$bound.withValue(register) {
                for sweep in 1 ..< HealthKitBatchRejection.maxHeldSweeps {
                    let page = await importer.transmit(events, requiring: admitted.lease)
                    #expect(Self.decide(page) == .hold(reason: .nonterminalEntry), "sweep \(sweep) still holds")
                }
                #expect(await register.count(ownerID: Self.owner) == 0)

                let released = await importer.transmit(events, requiring: admitted.lease)
                #expect(Self.decide(released) == .commit, "the type is no longer pinned")
                let rows = await register.rows(ownerID: Self.owner)
                #expect(rows.count == 2)
                #expect(rows.allSatisfy { $0.reason == HealthKitBatchRejection.unclassifiedReason(status: 422) })

                // The run is over: a later unexplained 422 starts counting afresh.
                let next = await importer.transmit(Self.events(["evt-b3"]), requiring: admitted.lease)
                #expect(Self.decide(next) == .hold(reason: .nonterminalEntry))
            }
            #expect(await retry.enqueueCount() == 0)
        }

        // MARK: - 2b. The replay side of the same 4xx

        private func makeReplay(outbox: OutboxQueue) -> OutboxReplayService {
            let api = makeAPI()
            return OutboxReplayService(
                outbox: outbox,
                measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
                moodRepo: MoodRepository(api: api, outbox: outbox),
                medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
                currentUserProvider: { Self.owner },
                maxAttempts: 8,
                attemptBackoff: 0
            )
        }

        private func enqueueQueuedPage(_ outbox: OutboxQueue) async throws {
            try await outbox.enqueueHealthKitBatch(
                Self.events(["evt-q1", "evt-q2"]),
                encoder: .hlBatch,
                idempotencyKey: "hk-loss-paths-\(UUID().uuidString)",
                requiringCurrentOwner: Self.owner
            )
        }

        @Test("a queued HealthKit page parks on an unexplained 422 and lands once the server takes it")
        func replayParksOnUnexplained422() async throws {
            let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
            try await enqueueQueuedPage(outbox)
            let serverTakesIt = Flag()
            respond { serverTakesIt.value ? (200, Self.accepted) : (422, Self.zodFailure) }
            let replay = makeReplay(outbox: outbox)

            await replay.runOnce()
            await replay.runOnce()

            let parked = try #require(await outbox.snapshot.first, "the row is the reading's only copy")
            #expect(parked.attempts == 0)
            #expect(await outbox.deadLetterCount == 0)

            serverTakesIt.value = true
            await replay.runOnce()
            #expect(await outbox.snapshot.isEmpty)
        }

        @Test("a queued HealthKit page the route refuses by name is recorded before it is dropped")
        func replayRegistersNamedRefusal() async throws {
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
            let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
            try await enqueueQueuedPage(outbox)
            respond(status: 422) { Self.tooLarge }

            await HealthKitSkippedRowRegister.$bound.withValue(register) {
                await makeReplay(outbox: outbox).runOnce()
            }

            #expect(await outbox.snapshot.isEmpty)
            #expect(await register.rows(ownerID: Self.owner).map(\.id).sorted() == ["evt-q1", "evt-q2"])
        }

        @Test("a named refusal the register cannot keep parks the row instead of dropping it")
        func replayParksWhenTheRefusalCannotBeRecorded() async throws {
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking(lossy: true).storage)
            let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
            try await enqueueQueuedPage(outbox)
            respond(status: 422) { Self.tooLarge }

            await HealthKitSkippedRowRegister.$bound.withValue(register) {
                await makeReplay(outbox: outbox).runOnce()
            }

            let parked = try #require(await outbox.snapshot.first, "the row is the reading's only copy")
            #expect(parked.attempts == 0)
        }

        // MARK: - 3. Daily statistics, failed read

        private static let stepRow = HealthKitDailyStatRow(
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            dayStart: Date(timeIntervalSince1970: 1_790_000_000),
            dayKey: "2026-09-21",
            value: 4321,
            unit: "steps"
        )

        @Test("a HealthKit query that threw keeps the sweep end where it was; a full read moves it")
        func statsFailedQueryHoldsTheSweep() async throws {
            nonisolated(unsafe) let defaults = Self.isolatedDefaults()
            let admitted = try admit(.dailyStatistics)
            let coordinator = try HealthKitStatisticsSyncCoordinator(
                statisticsService: HealthKitStatisticsService(),
                cache: HealthKitDailyStatsCache(modelContainer: HealthKitDailyStatsCache.makeInMemory()),
                uploader: makeUploader(),
                featureFlags: AlwaysOnFeatureFlags(),
                admission: { admitted.lease },
                defaultsProvider: { defaults }
            )
            respond(status: 200) {
                #"{"data":{"processed":1,"inserted":1,"duplicates":0,"skipped":[],"entries":[{"index":0,"status":"inserted"}]},"error":null}"#
            }
            let now = Date(timeIntervalSince1970: 1_790_100_000)

            let partial = await coordinator.finishSweep(
                HealthKitDailyStatsRead(rows: [Self.stepRow], failedTypes: 1),
                requiring: admitted.lease,
                endingAt: now
            )
            #expect(partial.posted == 1, "what was read still goes out")
            #expect(!partial.isComplete)
            #expect(await coordinator.lastCompletedSweepEnd(ownerID: Self.owner) == nil)

            let full = await coordinator.finishSweep(
                HealthKitDailyStatsRead(rows: [], failedTypes: 0),
                requiring: admitted.lease,
                endingAt: now
            )
            #expect(full.isComplete)
            #expect(await coordinator.lastCompletedSweepEnd(ownerID: Self.owner) == now)
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false

        var value: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return flag
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                flag = newValue
            }
        }
    }

#endif

// swiftlint:enable force_unwrapping
