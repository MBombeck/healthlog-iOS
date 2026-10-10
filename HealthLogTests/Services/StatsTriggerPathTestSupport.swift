import Foundation
@testable import HealthLog
import Testing

#if canImport(HealthKit)

    /// **V1 (1.2)** — fixtures for the `stats:` trigger-path suites.
    ///
    /// The batch API records every POST (its `syncTrigger` word and the
    /// `externalId`s it carried) and answers each entry `inserted`, so the
    /// coordinator writes its cache exactly as against a real server. An
    /// optional gate parks the first POST, which is how the coalescing tests
    /// hold a sweep in flight.
    final class StatsRecordingAPI: APIClientProtocol, @unchecked Sendable {
        struct Post: Equatable {
            let trigger: String?
            let externalIds: [String]
        }

        private let lock = NSLock()
        private var recorded: [Post] = []
        private let parkFirstPost: Phase09Gate?
        private var parkedOnce = false

        init(parkFirstPost: Phase09Gate? = nil) {
            self.parkFirstPost = parkFirstPost
        }

        var posts: [Post] {
            lock.withLock { recorded }
        }

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            guard request.path == "/api/measurements/batch", let body = request.body else {
                throw HLError.unknown("test stub: unexpected request")
            }
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let entries = object?["entries"] as? [[String: Any]] ?? []
            let shouldPark = lock.withLock { () -> Bool in
                defer { parkedOnce = true }
                return !parkedOnce && parkFirstPost != nil
            }
            if shouldPark { await parkFirstPost?.wait() }
            lock.withLock {
                recorded.append(Post(
                    trigger: object?["syncTrigger"] as? String,
                    externalIds: entries.compactMap { $0["externalId"] as? String }
                ))
            }
            let response = HealthKitBatchResponseDTO(
                processed: entries.count,
                inserted: entries.count,
                duplicates: 0,
                skipped: [],
                entries: entries.indices.map { HealthKitBatchResponseDTO.EntryResult(index: $0, status: .inserted) }
            )
            guard let typed = response as? T else { throw HLError.unknown("test stub: T mismatch") }
            return typed
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.unknown("test stub: download not implemented")
        }
    }

    /// A HealthKit statistics read without a health store: every cumulative type
    /// has a value on every day of the requested window. `bump()` changes the
    /// values, so the next sweep has something new to post.
    final class StatsFakeReader: HealthKitDailyStatsReading, @unchecked Sendable {
        private let lock = NSLock()
        private var generation = 0
        private var windows: [(from: Date, to: Date)] = []
        let calendar: Calendar

        init(calendar: Calendar) {
            self.calendar = calendar
        }

        var readCount: Int {
            lock.withLock { windows.count }
        }

        func bump() {
            lock.withLock { generation += 1 }
        }

        func dailyRowsForAllDefaults(from: Date, to: Date) async -> HealthKitDailyStatsRead {
            let value = lock.withLock { () -> Double in
                windows.append((from, to))
                return Double(1000 + generation)
            }
            var rows: [HealthKitDailyStatRow] = []
            var day = calendar.startOfDay(for: from)
            while day <= to {
                for config in HealthKitCumulativeTypeConfig.defaults {
                    rows.append(HealthKitDailyStatRow(
                        hkIdentifier: config.identifier,
                        dayStart: day,
                        dayKey: HealthKitStatisticsService.dayKey(for: day, calendar: calendar),
                        value: value,
                        unit: config.wireUnit
                    ))
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            return HealthKitDailyStatsRead(rows: rows, failedTypes: 0)
        }

        func dailyRows(
            for _: HealthKitCumulativeTypeConfig,
            from _: Date,
            to _: Date
        ) async throws -> [HealthKitDailyStatRow] {
            []
        }
    }

    /// Waits in real time, not in scheduler yields: a sweep hops through the
    /// SwiftData cache and the uploader, which a yield loop can outrun.
    func v1Settle(
        timeout: Duration = .seconds(10),
        until condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    /// One coordinator over the fakes, under one admitted account.
    struct StatsSweepHarness {
        static let owner = "account-v1"
        /// 2026-10-09 14:00 UTC.
        static let now = Date(timeIntervalSince1970: 1_791_554_400)

        let coordinator: HealthKitStatisticsSyncCoordinator
        let api: StatsRecordingAPI
        let reader: StatsFakeReader
        let defaults: UserDefaults
        /// Retained: the lease holds the registry weakly.
        let registry: AuthenticatedSessionLeaseRegistry

        static var utc: Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
            return calendar
        }

        /// The ten `stats:` ids of today and yesterday (five types, two days).
        static var todayAndYesterdayIds: Set<String> {
            let calendar = utc
            let today = calendar.startOfDay(for: now)
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            return Set([yesterday, today].flatMap { day in
                HealthKitCumulativeTypeConfig.defaults.map {
                    "stats:\($0.identifier):\(HealthKitStatisticsService.dayKey(for: day, calendar: calendar))"
                }
            })
        }

        init(parkFirstPost: Phase09Gate? = nil) throws {
            let calendar = Self.utc
            let suite = "test.v1.stats.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.owner)
            let lease = try HealthSyncAuthenticatedLease.admit(
                from: registry,
                ownerID: Self.owner,
                source: .dailyStatistics,
                bearerProvider: { "bearer-v1" }
            )
            let api = StatsRecordingAPI(parkFirstPost: parkFirstPost)
            let reader = StatsFakeReader(calendar: calendar)
            let cache = try HealthKitDailyStatsCache(modelContainer: HealthKitDailyStatsCache.makeInMemory())
            let uploader = MeasurementBatchUploader(
                api: api,
                throttle: BatchSyncThrottle(maxPerWindow: 600, window: 60.0, jitter: 0 ... 0),
                authenticationSnapshot: {
                    MeasurementUploadAuthenticationSnapshot(ownerUserID: Self.owner, bearerToken: "bearer-v1")
                }
            )
            nonisolated(unsafe) let unsafeDefaults = defaults
            coordinator = HealthKitStatisticsSyncCoordinator(
                statisticsService: reader,
                cache: cache,
                uploader: uploader,
                featureFlags: AlwaysOnFeatureFlags(),
                calendar: calendar,
                clock: { Self.now },
                admission: { lease },
                defaultsProvider: { unsafeDefaults }
            )
            self.api = api
            self.reader = reader
            self.defaults = defaults
            self.registry = registry
        }

        var postedIds: [String] {
            api.posts.flatMap(\.externalIds)
        }
    }

#endif
