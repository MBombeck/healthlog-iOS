import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

/// One 10-minute aggregated heart-rate bucket row. Mirrors ``HealthKitDailyStatRow``
/// but for the server `stats:` HR-bucket contract (GH #34, server v1.19.x /
/// valueMin+valueMax since v1.19.2).
///
/// **Why 10-minute buckets (superseded the never-adopted hourly attempt):**
/// per-sample heart-rate upload was huge volume; the server now wants
/// UTC-aligned 10-minute aggregates. ~144 rows/day fit a single batch. Re-posting
/// the same `externalId` overwrites the server row (`updated`), so the current +
/// recent buckets are re-uploaded each sweep (idempotent fill).
///
/// **externalId format (locked v1.19.x):**
/// `stats:HKQuantityTypeIdentifierHeartRate:<bucket-START ISO-8601 UTC, minutes ∈
/// {00,10,20,30,40,50}, seconds/millis zeroed, trailing Z>` — e.g.
/// `stats:HKQuantityTypeIdentifierHeartRate:2026-07-18T14:30:00.000Z`. The bucket
/// key is UTC so it is TZ-stable. A malformed suffix → server `skipped` /
/// `malformed_hr_bucket_id`, so the key is built exactly.
///
/// **value/unit/measuredAt:** `value` is the bucket's **average** bpm (stored
/// server-side as `PULSE`, `unit` `count/min`); `valueMin`/`valueMax` carry the
/// bucket's low/high (envelope + true daily high/low); `measuredAt` is the
/// bucket's **endDate** (``bucketEndUTC``).
public struct HealthKitHRBucketRow: Sendable, Equatable {
    /// Always `HKQuantityTypeIdentifierHeartRate` — kept explicit so the
    /// externalId construction reads symmetrically with ``HealthKitDailyStatRow``.
    public static let hkIdentifier = "HKQuantityTypeIdentifierHeartRate"

    /// Wire-unit the server's PULSE mapping expects for an aggregated HR bucket.
    public static let wireUnit = "count/min"

    /// Bucket width — 10 minutes in seconds. The UTC 10-minute grid is anchored
    /// to `timeIntervalSinceReferenceDate == 0` (2001-01-01T00:00:00Z), which is
    /// itself a 10-minute boundary, so flooring an epoch to a multiple of 600
    /// always lands on a wall-clock UTC minute ∈ {00,10,20,30,40,50}.
    public static let bucketSeconds: TimeInterval = 600

    /// UTC start-of-bucket (10-minute-floored: minutes ∈ {00,10,20,30,40,50},
    /// seconds/millis zeroed). Drives the `externalId` bucket key.
    public let bucketStartUTC: Date

    /// Bucket average bpm → wire `value`.
    public let averageBpm: Double

    /// Bucket minimum bpm → wire `valueMin` (envelope low / true daily low).
    public let minBpm: Double

    /// Bucket maximum bpm → wire `valueMax` (envelope high / true daily high).
    public let maxBpm: Double

    public init(bucketStartUTC: Date, averageBpm: Double, minBpm: Double, maxBpm: Double) {
        self.bucketStartUTC = bucketStartUTC
        self.averageBpm = averageBpm
        self.minBpm = minBpm
        self.maxBpm = maxBpm
    }

    /// The bucket's END instant (start + 10 min). Sent to the server as the
    /// entry's `endDate`, which the server records as `measuredAt` per the
    /// contract.
    public var bucketEndUTC: Date {
        bucketStartUTC.addingTimeInterval(Self.bucketSeconds)
    }

    /// ISO-8601 UTC, millis-zeroed, trailing `Z` of the bucket START —
    /// `2026-07-18T14:30:00.000Z`.
    public var bucketKey: String {
        Self.bucketKey(for: bucketStartUTC)
    }

    /// Locked externalId. `stats:HKQuantityTypeIdentifierHeartRate:<bucketKey>`.
    public var externalId: String {
        "stats:\(Self.hkIdentifier):\(bucketKey)"
    }

    /// Formats a bucket-start instant into the locked bucket-key string.
    ///
    /// The instant is first floored to its UTC 10-minute bucket
    /// (minutes/seconds/millis snapped) so a caller that passes an arbitrary
    /// instant inside the bucket still produces the contract-stable key. Uses
    /// `ISO8601DateFormatter` with fractional seconds — UTC is the formatter's
    /// default TZ, so the output carries the trailing `Z` and `.000` millis.
    public static func bucketKey(for date: Date) -> String {
        let floored = flooredToUTCTenMinutes(date)
        return ISO8601DateFormatter.fractional.string(from: floored)
    }

    /// Floors an instant to the start of its UTC 10-minute bucket
    /// (minutes ∈ {00,10,20,30,40,50}, seconds/millis zeroed). Pure — used by
    /// both the key formatter and the bucket query.
    public static func flooredToUTCTenMinutes(_ date: Date) -> Date {
        let epoch = date.timeIntervalSinceReferenceDate
        let floored = (epoch / bucketSeconds).rounded(.down) * bucketSeconds
        return Date(timeIntervalSinceReferenceDate: floored)
    }
}

#if canImport(HealthKit)

    /// The two calls a bounded HealthKit query needs, behind a seam so a test
    /// can play a health store that never answers (SYNC-HR, #159).
    public protocol HealthKitQueryExecuting: Sendable {
        func execute(_ query: HKQuery)
        func stop(_ query: HKQuery)
    }

    extension HKHealthStore: HealthKitQueryExecuting {}

    /// The statistics query did not answer within its time limit. It was
    /// stopped; the next sweep asks again.
    public struct HealthKitQueryTimedOut: Error, Sendable, Equatable {}

    /// `HKStatisticsCollectionQuery` wrapper that produces 10-minute heart-rate
    /// aggregate buckets — `.discreteAverage | .discreteMin | .discreteMax` over
    /// 10-minute UTC-aligned intervals.
    ///
    /// Mirrors ``HealthKitStatisticsService``'s idiom (continuation-wrapped
    /// collection query + a pure `nonisolated` row extractor so the
    /// `enumerateStatistics` closure never touches actor state). The interval
    /// anchor is a UTC 10-minute boundary so each bucket aligns with the
    /// contract's UTC bucket key.
    ///
    /// **SYNC-HR (1.5, #159 / HealthLog#1326):** until 1.4.1 the query was
    /// awaited without a limit and without a way to stop it. A callback that
    /// never came (the suspect: iOS suspending the app mid-query in the
    /// background) held the sweep, and with it every later sweep, until the
    /// app was restarted. The query now answers exactly once: with its result,
    /// with ``HealthKitQueryTimedOut`` after ``defaultQueryTimeout``, or with
    /// `CancellationError` when the awaiting task is cancelled. The last two
    /// also `stop` the query, so HealthKit stops working on it.
    public actor HealthKitHRBucketService {
        /// Long enough for 90 days of 10-minute statistics on an old phone,
        /// short enough to sit well inside the sweep's own deadline.
        public static let defaultQueryTimeout: Duration = .seconds(60)

        private let store: any HealthKitQueryExecuting
        private let clock: @Sendable () -> Date
        private let queryTimeout: Duration

        public init(
            store: HKHealthStore = HKHealthStore(),
            clock: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.init(executor: store, queryTimeout: Self.defaultQueryTimeout, clock: clock)
        }

        init(
            executor: any HealthKitQueryExecuting,
            queryTimeout: Duration,
            clock: @escaping @Sendable () -> Date = { Date() }
        ) {
            store = executor
            self.queryTimeout = queryTimeout
            self.clock = clock
        }

        /// Collect 10-minute HR buckets in `[from, to)`, both floored to the UTC
        /// 10-minute grid. Returns empty when the device has no HR type symbol.
        ///
        /// Only buckets with a non-nil average (and min/max) are emitted — idle
        /// buckets have no HR samples. The caller layers the cutover +
        /// completed-bucket gating on top; this service is a pure HK→rows
        /// projection.
        public func bucketRows(from: Date, to: Date) async throws -> [HealthKitHRBucketRow] {
            guard let quantityType = HKObjectType.quantityType(forIdentifier: .heartRate) else {
                return []
            }
            let anchor = HealthKitHRBucketRow.flooredToUTCTenMinutes(from)
            let endExclusive = HealthKitHRBucketRow.flooredToUTCTenMinutes(to)
            guard endExclusive > anchor else { return [] }

            let predicate = HKQuery.predicateForSamples(withStart: anchor, end: endExclusive, options: [])
            let collection = try await runStatisticsCollection(
                quantityType: quantityType,
                predicate: predicate,
                anchor: anchor
            )
            return Self.rows(from: collection, anchor: anchor, endExclusive: endExclusive)
        }

        /// Pure-functional extractor — separated from the actor-isolated query so
        /// the `enumerateStatistics` closure stays Sendable-clean. A bucket is
        /// emitted only when average, minimum AND maximum are all present.
        nonisolated static func rows(
            from collection: HKStatisticsCollection,
            anchor: Date,
            endExclusive: Date
        ) -> [HealthKitHRBucketRow] {
            let bpmUnit = HKUnit.count().unitDivided(by: .minute())
            var out: [HealthKitHRBucketRow] = []
            collection.enumerateStatistics(from: anchor, to: endExclusive) { stats, _ in
                guard let avg = stats.averageQuantity(),
                      let low = stats.minimumQuantity(),
                      let high = stats.maximumQuantity() else { return }
                let value = avg.doubleValue(for: bpmUnit)
                guard value > 0 else { return }
                out.append(
                    HealthKitHRBucketRow(
                        bucketStartUTC: HealthKitHRBucketRow.flooredToUTCTenMinutes(stats.startDate),
                        averageBpm: value,
                        minBpm: low.doubleValue(for: bpmUnit),
                        maxBpm: high.doubleValue(for: bpmUnit)
                    )
                )
            }
            return out
        }

        private func runStatisticsCollection(
            quantityType: HKQuantityType,
            predicate: NSPredicate,
            anchor: Date
        ) async throws -> HKStatisticsCollection {
            let query = HKStatisticsCollectionQuery(
                quantityType: quantityType,
                quantitySamplePredicate: predicate,
                options: [.discreteAverage, .discreteMin, .discreteMax],
                anchorDate: anchor,
                intervalComponents: DateComponents(minute: 10)
            )
            let answer = BoundedHealthKitAnswer<HKStatisticsCollection>(query: query, executor: store)
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    answer.finish(.failure(error))
                } else if let collection {
                    answer.finish(.success(collection))
                } else {
                    answer.finish(.failure(HealthKitStatisticsError.noCollection))
                }
            }
            return try await answer.value(timeout: queryTimeout)
        }
    }

    /// One HealthKit query's answer, delivered exactly once (SYNC-HR).
    ///
    /// The first of four events wins: the query's callback, the time limit,
    /// the awaiting task's cancellation, or a cancellation that arrived before
    /// the query was even started. The last three stop the query when it was
    /// started; a callback that arrives afterwards is ignored.
    final class BoundedHealthKitAnswer<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private let query: HKQuery
        private let executor: any HealthKitQueryExecuting
        private var continuation: CheckedContinuation<Value, any Error>?
        private var outcome: Result<Value, any Error>?
        private var executed = false
        private var timer: Task<Void, Never>?

        init(query: HKQuery, executor: any HealthKitQueryExecuting) {
            self.query = query
            self.executor = executor
        }

        func value(timeout: Duration) async throws -> Value {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    if let outcome {
                        lock.unlock()
                        continuation.resume(with: outcome)
                        return
                    }
                    self.continuation = continuation
                    executed = true
                    // `execute` returns at once; the callback is asynchronous.
                    // Under the lock, so a cancellation cannot slip between
                    // registering and starting.
                    executor.execute(query)
                    timer = Task { [weak self] in
                        try? await Task.sleep(for: timeout)
                        guard !Task.isCancelled else { return }
                        self?.abandon(HealthKitQueryTimedOut())
                    }
                    lock.unlock()
                }
            } onCancel: {
                abandon(CancellationError())
            }
        }

        /// The query's own callback.
        func finish(_ result: Result<Value, any Error>) {
            resolve(result, stopQuery: false)
        }

        private func abandon(_ error: any Error) {
            resolve(.failure(error), stopQuery: true)
        }

        private func resolve(_ result: Result<Value, any Error>, stopQuery: Bool) {
            lock.lock()
            guard outcome == nil else {
                lock.unlock()
                return
            }
            outcome = result
            let waiting = continuation
            continuation = nil
            let pendingTimer = timer
            timer = nil
            let shouldStop = stopQuery && executed
            lock.unlock()
            pendingTimer?.cancel()
            if shouldStop { executor.stop(query) }
            waiting?.resume(with: result)
        }
    }

#endif
