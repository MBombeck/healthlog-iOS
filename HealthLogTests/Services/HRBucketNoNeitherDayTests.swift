#if canImport(HealthKit)
    import Foundation
    @testable import HealthLog
    import Testing

    /// #12 — no UTC day may end with neither raw heart-rate rows nor 10-minute
    /// buckets, and no day may carry both.
    ///
    /// The reporter's account had raw heart rate up to the cutover and nothing
    /// after it: the per-sample path dropped every sample on a bucket day while
    /// the sweep that should have replaced them never reached the server. These
    /// tests pin both halves of the repair — the per-sample path drops a sample
    /// only when the bucket path can be trusted with its day, and the sweep
    /// reaches every bucket day that has no buckets yet, once.
    @Suite("HR buckets — no day in neither shape (#12)")
    struct HRBucketNoNeitherDayTests {
        // MARK: - Fixtures

        private static let user = "user-12"

        private static func iso(_ value: String) -> Date {
            // swiftlint:disable:next force_unwrapping
            ISO8601DateFormatter.fractional.date(from: value)!
        }

        private static let cutover = iso("2026-09-07T00:00:00.000Z")
        private static let now = iso("2026-10-03T12:00:00.000Z")

        private final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var value: Date
            init(_ value: Date) {
                self.value = value
            }

            var now: Date {
                get { lock.withLock { value } }
                set { lock.withLock { value = newValue } }
            }
        }

        private final class Reader: HealthKitHRBucketReading, @unchecked Sendable {
            private let lock = NSLock()
            private var rows: [HealthKitHRBucketRow]
            private(set) var queries: [(Date, Date)] = []
            var error: Error?

            init(rows: [HealthKitHRBucketRow]) {
                self.rows = rows
            }

            func add(_ row: HealthKitHRBucketRow) {
                lock.withLock { rows.append(row) }
            }

            func bucketRows(from: Date, to: Date) async throws -> [HealthKitHRBucketRow] {
                try lock.withLock {
                    queries.append((from, to))
                    if let error { throw error }
                    return rows.filter { $0.bucketStartUTC >= from && $0.bucketStartUTC < to }
                }
            }
        }

        private final class ServerAPI: APIClientProtocol, @unchecked Sendable {
            private let lock = NSLock()
            private var _posted: [[HealthKitBatchEntryDTO]] = []
            var failure: Error?

            var posted: [[HealthKitBatchEntryDTO]] {
                lock.withLock { _posted }
            }

            var postedIds: [String] {
                posted.flatMap { $0.map(\.externalId) }
            }

            func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
                guard let body = request.body else { throw HLError.unknown("test stub: no body") }
                if let failure = lock.withLock({ failure }) { throw failure }
                let payload = try BatchUploadOutcomeTests.batchDecoder().decode(HealthKitBatchPayload.self, from: body)
                lock.withLock { _posted.append(payload.entries) }
                let response = HealthKitBatchResponseDTO(
                    processed: payload.entries.count,
                    inserted: payload.entries.count,
                    duplicates: 0,
                    skipped: [],
                    entries: payload.entries.indices.map { .init(index: $0, status: .inserted) }
                )
                guard let typed = response as? T else { throw HLError.unknown("test stub: T mismatch") }
                return typed
            }

            func sendVoid(_: APIRequest<EmptyPayload>) async throws {}
            func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
                throw HLError.unknown("test stub: download not implemented")
            }
        }

        private struct Flags: FeatureFlagsServicing {
            var hrBuckets = true
            func isEnabled(_ flag: FeatureFlag) -> Bool {
                flag == .enableHRBuckets ? hrBuckets : flag.defaultValue
            }
        }

        private struct Harness {
            let suite: String
            let clock: Clock
            let reader: Reader
            let api: ServerAPI
            let coordinator: HealthKitHRBucketSyncCoordinator

            var defaults: UserDefaults {
                // swiftlint:disable:next force_unwrapping
                UserDefaults(suiteName: suite)!
            }

            var ledger: HRBucketSyncLedger {
                HRBucketSyncLedgerStore.load(userId: HRBucketNoNeitherDayTests.user, defaults: defaults)
            }

            func rawGateDrops(_ date: Date) -> Bool {
                HRBucketRawGate.shouldDrop(
                    sampleDate: date,
                    userId: HRBucketNoNeitherDayTests.user,
                    now: clock.now,
                    defaults: defaults
                )
            }
        }

        private func harness(rows: [HealthKitHRBucketRow] = [], flags: Flags = Flags()) -> Harness {
            let suite = "test.hrbucket.neither.\(UUID().uuidString)"
            // swiftlint:disable:next force_unwrapping
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            defaults.set(Self.cutover, forKey: HRBucketCutoverStore.key(for: Self.user))
            let keychain = InMemoryKeychain()
            try? keychain.setString("token", forKey: KeychainKey.authToken)
            try? keychain.setString(Self.user, forKey: KeychainKey.userID)
            let clock = Clock(Self.now)
            let reader = Reader(rows: rows)
            let api = ServerAPI()
            let coordinator = HealthKitHRBucketSyncCoordinator(
                service: reader,
                uploader: MeasurementBatchUploader(api: api, throttle: BatchSyncThrottle()),
                featureFlags: flags,
                keychain: keychain,
                isStandalone: { false },
                clock: { clock.now },
                // swiftlint:disable:next force_unwrapping
                defaultsProvider: { UserDefaults(suiteName: suite)! }
            )
            return Harness(suite: suite, clock: clock, reader: reader, api: api, coordinator: coordinator)
        }

        private static func row(_ start: String, bpm: Double = 70) -> HealthKitHRBucketRow {
            HealthKitHRBucketRow(bucketStartUTC: iso(start), averageBpm: bpm, minBpm: bpm - 2, maxBpm: bpm + 2)
        }

        /// One bucket at 08:00Z on every day from the cutover through today.
        private static var oneBucketPerDay: [HealthKitHRBucketRow] {
            let first = HRBucketSyncLedger.day(of: cutover)
            let last = HRBucketSyncLedger.day(of: now)
            return (first ... last).map { day in
                HealthKitHRBucketRow(
                    bucketStartUTC: HRBucketSyncLedger.start(ofDay: day).addingTimeInterval(8 * 3600),
                    averageBpm: 70,
                    minBpm: 68,
                    maxBpm: 72
                )
            }
        }

        // MARK: - The per-sample half

        @Test("healthy bucket path: a bucket-day sample is handed over and a sweep is owed")
        func healthyPathDropsAndOwes() {
            let h = harness()
            #expect(h.rawGateDrops(Self.iso("2026-10-03T09:00:00.000Z")))
            #expect(h.ledger.owedSince == Self.now)
            #expect(h.ledger.rawDays.isEmpty)
        }

        @Test("last sweep failed: a sample on a day without buckets goes up raw and the day is raw from then on")
        func failedPathFallsBackToRaw() async {
            let h = harness(rows: [Self.row("2026-10-03T08:00:00.000Z")])
            h.api.failure = HLError.server(status: 422, code: "validation", message: "no")
            await h.coordinator.sync()
            #expect(h.ledger.lastEvent?.gate == .uploadFailed)

            let sample = Self.iso("2026-10-03T09:00:00.000Z")
            #expect(!h.rawGateDrops(sample))
            #expect(h.ledger.rawDays == [HRBucketSyncLedger.day(of: sample)])
            #expect(h.ledger.lastSuppression?.gate == .rawFallbackSweepFailed)
        }

        @Test("heart rate waiting over an hour for a sweep falls back to raw")
        func starvedPathFallsBackToRaw() {
            let h = harness()
            #expect(h.rawGateDrops(Self.iso("2026-10-03T09:00:00.000Z")))
            h.clock.now = Self.now.addingTimeInterval(HRBucketSyncLedger.starvationLimit + 60)
            #expect(!h.rawGateDrops(Self.iso("2026-10-03T12:30:00.000Z")))
            #expect(h.ledger.lastSuppression?.gate == .rawFallbackSweepStarved)
        }

        @Test("a day that already has accepted buckets is never sent raw, even after a failure")
        func bucketDayNeverMixes() async {
            let h = harness(rows: [Self.row("2026-10-03T08:00:00.000Z")])
            await h.coordinator.sync()
            #expect(h.ledger.bucketDays.contains(HRBucketSyncLedger.day(of: Self.now)))

            h.reader.add(Self.row("2026-10-03T08:10:00.000Z"))
            h.clock.now = Self.now.addingTimeInterval(600)
            h.api.failure = HLError.server(status: 422, code: "validation", message: "no")
            await h.coordinator.sync()
            #expect(h.rawGateDrops(Self.iso("2026-10-03T08:15:00.000Z")))
            #expect(h.ledger.rawDays.isEmpty)
        }

        @Test("a raw-fallback day is never bucketed, also after the path recovers")
        func rawDayIsNeverBucketed() async {
            let h = harness(rows: [Self.row("2026-10-02T08:00:00.000Z"), Self.row("2026-10-03T08:00:00.000Z")])
            h.api.failure = HLError.server(status: 422, code: "validation", message: "no")
            await h.coordinator.sync()
            #expect(!h.rawGateDrops(Self.iso("2026-10-03T09:00:00.000Z")))

            h.api.failure = nil
            h.clock.now = Self.now.addingTimeInterval(600)
            await h.coordinator.sync()
            #expect(!h.api.postedIds.contains("stats:HKQuantityTypeIdentifierHeartRate:2026-10-03T08:00:00.000Z"))
            #expect(h.api.postedIds.contains("stats:HKQuantityTypeIdentifierHeartRate:2026-10-02T08:00:00.000Z"))
            // The recovered path does not re-open the raw day for buckets.
            #expect(!h.rawGateDrops(Self.iso("2026-10-03T13:00:00.000Z")))
        }

        @Test("a day before the cutover is plain raw, not a fallback")
        func preCutoverIsPlainRaw() {
            let h = harness()
            #expect(!h.rawGateDrops(Self.iso("2026-09-06T20:00:00.000Z")))
            #expect(h.ledger.rawDays.isEmpty)
            #expect(h.ledger.lastSuppression == nil)
        }

        // MARK: - The sweep half

        @Test("backfill: every bucket day since the cutover that has no buckets is uploaded once")
        func backfillsEveryMissingDayOnce() async {
            let rows = Self.oneBucketPerDay
            let h = harness(rows: rows)
            let accepted = await h.coordinator.sync()
            #expect(accepted == rows.count)
            #expect(Set(h.api.postedIds) == Set(rows.map(\.externalId)))
            #expect(h.ledger.lastEvent?.gate == .uploaded)

            let before = h.api.posted.count
            h.clock.now = Self.now.addingTimeInterval(60)
            #expect(await h.coordinator.sync() == 0)
            #expect(h.api.posted.count == before)
            #expect(h.ledger.lastEvent?.gate == .upToDate)
        }

        @Test("backfill reach is bounded and never crosses the cutover")
        func sweepDaysAreBounded() {
            let ledger = HRBucketSyncLedger()
            let today = HRBucketSyncLedger.day(of: Self.now)
            let sinceCutover = HealthKitHRBucketSyncCoordinator.sweepDays(
                cutover: Self.cutover, now: Self.now, ledger: ledger, isBucketDay: { _ in true }
            )
            #expect(sinceCutover.first == HRBucketSyncLedger.day(of: Self.cutover))
            #expect(sinceCutover.last == today)

            let longAgo = HealthKitHRBucketSyncCoordinator.sweepDays(
                cutover: Self.iso("2025-01-01T00:00:00.000Z"), now: Self.now, ledger: ledger, isBucketDay: { _ in true }
            )
            #expect(longAgo.first == today - HealthKitHRBucketSyncCoordinator.backfillDays)
        }

        @Test("a late sample for a settled day is read again and uploaded on the next sweep")
        func lateSampleReopensSettledDay() async {
            let h = harness(rows: [Self.row("2026-09-27T14:10:00.000Z")])
            await h.coordinator.sync()
            let day = HRBucketSyncLedger.day(of: Self.iso("2026-09-27T00:00:00.000Z"))
            #expect(h.ledger.settledDays.contains(day))

            // A reading HealthKit received hours after the sweep, dated 12:29Z.
            h.reader.add(Self.row("2026-09-27T12:20:00.000Z", bpm: 82))
            h.clock.now = Self.now.addingTimeInterval(3600)
            #expect(h.rawGateDrops(Self.iso("2026-09-27T12:29:58.000Z")))
            #expect(h.ledger.dirtyDays.contains(day))

            await h.coordinator.sync()
            #expect(h.api.postedIds.contains("stats:HKQuantityTypeIdentifierHeartRate:2026-09-27T12:20:00.000Z"))
            #expect(!h.ledger.dirtyDays.contains(day))
        }

        @Test("an open day posts only new or changed buckets")
        func openDayPostsOnlyChanges() async {
            let h = harness(rows: [Self.row("2026-10-03T08:00:00.000Z"), Self.row("2026-10-03T08:10:00.000Z")])
            await h.coordinator.sync()
            #expect(h.api.postedIds.count == 2)

            h.reader.add(Self.row("2026-10-03T11:40:00.000Z"))
            h.clock.now = Self.now.addingTimeInterval(600)
            await h.coordinator.sync()
            #expect(h.api.posted.last?.map(\.externalId) == ["stats:HKQuantityTypeIdentifierHeartRate:2026-10-03T11:40:00.000Z"])
        }

        @Test("a sweep the server refuses keeps its days open and the next sweep retries them")
        func failedUploadIsRetried() async {
            let h = harness(rows: [Self.row("2026-09-20T08:00:00.000Z")])
            h.api.failure = HLError.server(status: 422, code: "validation", message: "no")
            #expect(await h.coordinator.sync() == 0)
            #expect(h.ledger.lastFailureAt == Self.now)
            #expect(!h.ledger.settledDays.contains(HRBucketSyncLedger.day(of: Self.iso("2026-09-20T00:00:00.000Z"))))

            h.api.failure = nil
            h.clock.now = Self.now.addingTimeInterval(600)
            #expect(await h.coordinator.sync() == 1)
            #expect(h.ledger.isBucketPathHealthy(now: h.clock.now))
        }

        @Test("an offline upload defers without marking the path failed")
        func offlineDefers() async {
            let h = harness(rows: [Self.row("2026-10-03T08:00:00.000Z")])
            h.api.failure = HLError.offline
            await h.coordinator.sync()
            #expect(h.ledger.lastEvent?.gate == .uploadDeferred)
            #expect(h.ledger.lastFailureAt == nil)
        }

        @Test("a gate that suppresses the sweep is recorded by name")
        func gatesAreRecorded() async {
            let h = harness(rows: [Self.row("2026-10-03T08:00:00.000Z")], flags: Flags(hrBuckets: false))
            await h.coordinator.sync()
            #expect(h.ledger.lastSuppression?.gate == .flagOff)
            #expect(h.api.posted.isEmpty)
        }

        // MARK: - The trigger

        @Test("a sweep request survives the cancellation of the task that made it")
        func requestedSweepOutlivesCancelledCaller() async throws {
            let h = harness(rows: [Self.row("2026-10-03T08:00:00.000Z")])
            let coordinator = h.coordinator
            let caller = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                coordinator.requestHRBucketSweep()
            }
            await caller.value
            for _ in 0 ..< 200 where h.api.posted.isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(h.api.postedIds == ["stats:HKQuantityTypeIdentifierHeartRate:2026-10-03T08:00:00.000Z"])
        }
    }
#endif
