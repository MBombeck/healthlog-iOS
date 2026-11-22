import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

#if canImport(HealthKit)

    /// The daily-stat sweep finishes honestly.
    ///
    /// `HealthKitStatisticsRoundTripTests` proves what one action puts on the
    /// wire. This suite proves the other half: what the sweep is allowed to
    /// *claim* afterwards. A sweep is complete only when every planned row is
    /// terminally accepted (since 1.7 a day total is never queued, #3), and
    /// "the sweep ran" is not the same statement as "the history is complete".
    @Suite("HK-STATS completion truth — terminal, durably queued, or incomplete", .serialized, .mockURLSession)
    struct HealthKitStatisticsCompletionTests {
        static let owner = "account-a"

        private func makeAPI() -> APIClient {
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        }

        private func sampleRow(value: Double = 8345) -> HealthKitDailyStatRow {
            HealthKitDailyStatRow(
                hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                dayStart: Date(timeIntervalSince1970: 1_716_000_000),
                dayKey: "2026-05-16",
                value: value,
                unit: "steps"
            )
        }

        /// The uploader carries the credential half of the admission (owner +
        /// exact bearer generation pinned onto the request); the coordinator's
        /// `HealthSyncAuthenticatedLease` carries the identity half.
        static func makeUploader(api: APIClientProtocol) -> MeasurementBatchUploader {
            MeasurementBatchUploader(
                api: api,
                throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0),
                authenticationSnapshot: {
                    MeasurementUploadAuthenticationSnapshot(ownerUserID: owner, bearerToken: "bearer-a")
                }
            )
        }

        private struct Harness {
            let coordinator: HealthKitStatisticsSyncCoordinator
            let cache: HealthKitDailyStatsCache
            let lease: HealthSyncAuthenticatedLease
            /// Retained on purpose — `AuthenticatedSessionLease` holds the
            /// registry weakly, so a dropped registry turns every admission
            /// stale.
            let registry: AuthenticatedSessionLeaseRegistry
        }

        // MARK: - Completion truth

        private func makeRetryHarness(
            api: APIClientProtocol,
            retry: (any HealthSyncBatchRetryEnqueuing)?
        ) throws -> Harness {
            let cache = try HealthKitDailyStatsCache(modelContainer: HealthKitDailyStatsCache.makeInMemory())
            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.owner)
            let lease = try HealthSyncAuthenticatedLease.admit(
                from: registry,
                ownerID: Self.owner,
                source: .dailyStatistics,
                bearerProvider: { "bearer-a" }
            )
            let coordinator = HealthKitStatisticsSyncCoordinator(
                statisticsService: HealthKitStatisticsService(),
                cache: cache,
                uploader: Self.makeUploader(api: api),
                admission: { lease },
                retry: retry
            )
            return Harness(coordinator: coordinator, cache: cache, lease: lease, registry: registry)
        }

        private func respondFailed() {
            MockURLProtocol.install { req in
                let body = #"""
                {"data":{"processed":1,"inserted":0,"duplicates":0,"skipped":[],"entries":[{"index":0,"status":"failed","reason":"persistence_error"}]},"error":null}
                """#
                let response = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(body.utf8))
            }
        }

        @Test("a non-terminal chunk is not queued: the sweep stays incomplete and the cache does not advance (#3)")
        func heldChunkIsNotQueued() async throws {
            let retry = RecordingStatsRetryQueue()
            let harness = try makeRetryHarness(api: makeAPI(), retry: retry)
            respondFailed()

            let summary = await harness.coordinator.process([sampleRow(value: 8345)], requiring: harness.lease)

            #expect(summary.failed == 1)
            #expect(summary.retryQueued == 0)
            #expect(!summary.isComplete, "the next sweep sums the day again instead of replaying this value")
            #expect(await retry.enqueueCount() == 0, "a day total never waits in the outbox")
            #expect(await harness.cache.read(
                ownerUserID: Self.owner,
                hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                dayKey: "2026-05-16"
            ) == nil)
        }

        @Test("with nowhere durable to write, the sweep reports itself incomplete")
        func heldChunkWithoutAQueueIsIncomplete() async throws {
            let harness = try makeRetryHarness(api: makeAPI(), retry: nil)
            respondFailed()

            let summary = await harness.coordinator.process([sampleRow(value: 8345)], requiring: harness.lease)

            #expect(summary.failed == 1)
            #expect(summary.retryQueued == 0)
            #expect(!summary.isComplete, "history cannot be complete while a row is neither terminal nor queued")
        }

        @Test("a durable write that itself fails leaves the sweep incomplete")
        func failingRetryQueueLeavesSweepIncomplete() async throws {
            let harness = try makeRetryHarness(api: makeAPI(), retry: RefusingStatsRetryQueue())
            respondFailed()

            let summary = await harness.coordinator.process([sampleRow(value: 8345)], requiring: harness.lease)

            #expect(summary.failed == 1)
            #expect(summary.retryQueued == 0)
            #expect(!summary.isComplete)
        }

        @Test("an accepted sweep writes every day and reports itself complete")
        func acceptedSweepIsComplete() async throws {
            let harness = try makeRetryHarness(api: makeAPI(), retry: RecordingStatsRetryQueue())
            nonisolated(unsafe) var postedBatches = 0
            MockURLProtocol.install { req in
                var count = 1
                if req.targets("/api/measurements/batch") {
                    postedBatches += 1
                    let data = req.httpBody ?? Self.readHTTPBodyStream(from: req)
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    if let data, let payload = try? decoder.decode(HealthKitBatchPayload.self, from: data) {
                        count = payload.entries.count
                    }
                }
                let entries = (0 ..< count)
                    .map { #"{"index":\#($0),"status":"inserted"}"# }
                    .joined(separator: ",")
                let body = #"{"data":{"processed":\#(count),"inserted":\#(count),"duplicates":0,"skipped":[],"entries":[\#(entries)]},"error":null}"#
                let response = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(body.utf8))
            }

            let rows = [
                sampleRow(value: 8345),
                HealthKitDailyStatRow(
                    hkIdentifier: "HKQuantityTypeIdentifierFlightsClimbed",
                    dayStart: Date(timeIntervalSince1970: 1_716_000_000),
                    dayKey: "2026-05-16",
                    value: 12,
                    unit: "flights"
                )
            ]
            let summary = await harness.coordinator.process(rows, requiring: harness.lease)

            #expect(summary.posted == 2)
            #expect(summary.failed == 0)
            #expect(summary.isComplete)
            // Both rows travelled in ONE request: the sweep batches within the
            // server limit instead of one POST per day.
            #expect(postedBatches == 1)
            #expect(try await harness.cache.count(ownerUserID: Self.owner) == 2)
        }

        @Test("a second pass over unchanged totals sends nothing and stays complete")
        func convergedSweepSendsNothing() async throws {
            let harness = try makeRetryHarness(api: makeAPI(), retry: RecordingStatsRetryQueue())
            try await harness.cache.write(
                ownerUserID: Self.owner,
                hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                dayKey: "2026-05-16",
                lastPostedValue: 8345
            )
            nonisolated(unsafe) var requestCount = 0
            MockURLProtocol.install { req in
                if req.targets(prefixedBy: "/api/measurements") { requestCount += 1 }
                let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }

            let summary = await harness.coordinator.process([sampleRow(value: 8345)], requiring: harness.lease)

            #expect(summary.skipped == 1)
            #expect(summary.isComplete)
            #expect(requestCount == 0)
        }

        @Test("a derived retry key is stable across two identical pages")
        func derivedRetryKeyIsStable() {
            let entries = [
                HealthKitBatchEntryDTO(
                    hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                    value: 8345,
                    unit: "steps",
                    startDate: Date(timeIntervalSince1970: 1_716_000_000),
                    endDate: Date(timeIntervalSince1970: 1_716_000_000),
                    externalId: "stats:HKQuantityTypeIdentifierStepCount:2026-05-16"
                ),
                HealthKitBatchEntryDTO(
                    hkIdentifier: "HKQuantityTypeIdentifierFlightsClimbed",
                    value: 12,
                    unit: "flights",
                    startDate: Date(timeIntervalSince1970: 1_716_000_000),
                    endDate: Date(timeIntervalSince1970: 1_716_000_000),
                    externalId: "stats:HKQuantityTypeIdentifierFlightsClimbed:2026-05-16"
                )
            ]
            let forward = HealthSyncRetryEnvelope(
                ownerID: Self.owner,
                source: .dailyStatistics,
                stableIdentity: HealthSampleConsumption.stableIdentity(of: entries)
            )
            let reversed = HealthSyncRetryEnvelope(
                ownerID: Self.owner,
                source: .dailyStatistics,
                stableIdentity: HealthSampleConsumption.stableIdentity(of: entries.reversed())
            )
            #expect(forward?.idempotencyKey == reversed?.idempotencyKey)
            // A different account is a different operation, never the same row.
            let other = HealthSyncRetryEnvelope(
                ownerID: "account-b",
                source: .dailyStatistics,
                stableIdentity: HealthSampleConsumption.stableIdentity(of: entries)
            )
            #expect(forward?.idempotencyKey != other?.idempotencyKey)
        }

        /// URLRequest bodies arrive as an InputStream on some Foundation paths.
        nonisolated static func readHTTPBodyStream(from request: URLRequest) -> Data? {
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
    }

    // MARK: - Stub durable-retry queue

    /// Records what the stats path would hand to the outbox. Never transmits.
    actor RecordingStatsRetryQueue: HealthSyncBatchRetryEnqueuing {
        struct Record: Sendable {
            let entries: [HealthKitBatchEntryDTO]
            let key: String
            let owner: String
        }

        private var recorded: [Record] = []

        func enqueueHealthKitRetry(
            _ entries: [HealthKitBatchEntryDTO],
            idempotencyKey: String,
            requiringCurrentOwner ownerUserID: String
        ) async throws {
            recorded.append(Record(entries: entries, key: idempotencyKey, owner: ownerUserID))
        }

        func enqueueCount() -> Int {
            recorded.count
        }

        func keys() -> [String] {
            recorded.map(\.key)
        }

        func owners() -> [String] {
            recorded.map(\.owner)
        }

        func externalIds() -> [[String]] {
            recorded.map { $0.entries.map(\.externalId) }
        }
    }

    /// A durable queue that cannot accept the write.
    struct RefusingStatsRetryQueue: HealthSyncBatchRetryEnqueuing {
        func enqueueHealthKitRetry(
            _: [HealthKitBatchEntryDTO],
            idempotencyKey _: String,
            requiringCurrentOwner _: String
        ) async throws {
            throw HLError.unknown("stats retry queue unavailable")
        }
    }

#endif

// swiftlint:enable force_unwrapping
