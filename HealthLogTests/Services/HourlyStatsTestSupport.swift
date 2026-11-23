import Foundation
@testable import HealthLog
import Testing

#if canImport(HealthKit)

    /// Fixtures for the hourly `stats:` suites.
    ///
    /// The API records every batch POST (its `syncTrigger`, the external ids
    /// and the entry instants) and answers each entry `inserted`, or throws
    /// while `failing` is set.
    final class HourlyRecordingAPI: APIClientProtocol, @unchecked Sendable {
        struct Post: Equatable {
            let trigger: String?
            let externalIds: [String]
            let startDates: [String]
            let endDates: [String]
            let units: [String]
        }

        private let lock = NSLock()
        private var recorded: [Post] = []
        private var failingValue = false

        var posts: [Post] {
            lock.withLock { recorded }
        }

        var failing: Bool {
            get { lock.withLock { failingValue } }
            set { lock.withLock { failingValue = newValue } }
        }

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            guard request.path == "/api/measurements/batch", let body = request.body else {
                throw HLError.unknown("test stub: unexpected request")
            }
            if failing { throw HLError.network(.timeout) }
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let entries = object?["entries"] as? [[String: Any]] ?? []
            lock.withLock {
                recorded.append(Post(
                    trigger: object?["syncTrigger"] as? String,
                    externalIds: entries.compactMap { $0["externalId"] as? String },
                    startDates: entries.compactMap { $0["startDate"] as? String },
                    endDates: entries.compactMap { $0["endDate"] as? String },
                    units: entries.compactMap { $0["unit"] as? String }
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

    /// `GET /api/auth/me` answering `json`, or failing while it is `nil`.
    final class HourlyMeAPI: APIClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var body: String?

        var json: String? {
            get { lock.withLock { body } }
            set { lock.withLock { body = newValue } }
        }

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            guard request.path == "/api/auth/me", let json else { throw HLError.network(.timeout) }
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.unknown("test stub: download not implemented")
        }
    }

    /// A statistics read without a health store. Day totals as V1's fake; for
    /// the hours, every type has `base + generation` from 08:00 to 20:59 local
    /// and nothing otherwise, cut exactly as the production reader cuts them
    /// (``HealthKitHourlyStatRow/rows(identifier:wireUnit:buckets:calendar:)``).
    final class HourlyFakeReader: HealthKitDailyStatsReading, @unchecked Sendable {
        private let lock = NSLock()
        private var generation = 0
        private var hourlyCalls: [(from: Date, through: Date)] = []
        private var zoneValue: TimeZone
        private var failHourly = false
        private let days: StatsFakeReader

        init(zone: TimeZone) {
            zoneValue = zone
            days = StatsFakeReader(calendar: Self.calendar(zone))
        }

        static func calendar(_ zone: TimeZone) -> Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return calendar
        }

        var hourlyReadCount: Int {
            lock.withLock { hourlyCalls.count }
        }

        var zone: TimeZone {
            get { lock.withLock { zoneValue } }
            set { lock.withLock { zoneValue = newValue } }
        }

        var failingHourly: Bool {
            get { lock.withLock { failHourly } }
            set { lock.withLock { failHourly = newValue } }
        }

        func bumpHours() {
            lock.withLock { generation += 1 }
        }

        func dailyRowsForAllDefaults(from: Date, to: Date) async -> HealthKitDailyStatsRead {
            await days.dailyRowsForAllDefaults(from: from, to: to)
        }

        func dailyRows(for config: HealthKitCumulativeTypeConfig, from: Date, to: Date) async throws -> [HealthKitDailyStatRow] {
            try await days.dailyRows(for: config, from: from, to: to)
        }

        func hourlyTimeZone() async -> TimeZone? {
            zone
        }

        func hourlyRows(from: Date, through: Date) async -> HealthKitHourlyStatsRead {
            lock.withLock { hourlyCalls.append((from, through)) }
            let generation = lock.withLock { self.generation }
            let readZone = zone
            let failing = failingHourly
            let calendar = Self.calendar(readZone)
            if failing {
                return HealthKitHourlyStatsRead(rows: [], failedTypes: 4, timeZoneIdentifier: readZone.identifier)
            }
            let anchor = calendar.startOfDay(for: from)
            let end = calendar.dateInterval(of: .hour, for: through)?.end ?? through
            var buckets: [(start: Date, value: Double?)] = []
            var cursor = anchor
            while cursor < end {
                let hour = calendar.component(.hour, from: cursor)
                buckets.append((cursor, (8 ... 20).contains(hour) ? Double(100 + generation) : nil))
                cursor = cursor.addingTimeInterval(HealthKitHourlyStatRow.hourSeconds)
            }
            let rows = HealthKitHourlyStatRow.configs.flatMap { config in
                HealthKitHourlyStatRow.rows(
                    identifier: config.identifier,
                    wireUnit: config.wireUnit,
                    buckets: buckets,
                    calendar: calendar
                )
            }
            return HealthKitHourlyStatsRead(rows: rows, failedTypes: 0, timeZoneIdentifier: readZone.identifier)
        }
    }

    /// One coordinator over the hourly fakes, under one admitted account, with
    /// its own defaults suite (the server record and the ledger live there) and
    /// a trigger context that reads the same suite.
    struct HourlySweepHarness {
        static let owner = "account-x4"
        /// 2026-10-09 14:00 UTC, as V1's harness.
        static let now = Date(timeIntervalSince1970: 1_791_554_400)

        let coordinator: HealthKitStatisticsSyncCoordinator
        let api: HourlyRecordingAPI
        let reader: HourlyFakeReader
        let defaults: UserDefaults
        let context: SyncTriggerContext
        let registry: AuthenticatedSessionLeaseRegistry

        static var utc: Calendar {
            HourlyFakeReader.calendar(TimeZone(identifier: "UTC") ?? .gmt)
        }

        init(zone: TimeZone = TimeZone(identifier: "UTC") ?? .gmt) throws {
            let suite = "test.x4.hourly.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.owner)
            let lease = try HealthSyncAuthenticatedLease.admit(
                from: registry,
                ownerID: Self.owner,
                source: .dailyStatistics,
                bearerProvider: { "bearer-x4" }
            )
            let api = HourlyRecordingAPI()
            let reader = HourlyFakeReader(zone: zone)
            let context = SyncTriggerContext(defaults: defaults)
            let cache = try HealthKitDailyStatsCache(modelContainer: HealthKitDailyStatsCache.makeInMemory())
            let uploader = MeasurementBatchUploader(
                api: api,
                throttle: BatchSyncThrottle(maxPerWindow: 600, window: 60.0, jitter: 0 ... 0),
                syncTrigger: context,
                authenticationSnapshot: {
                    MeasurementUploadAuthenticationSnapshot(ownerUserID: Self.owner, bearerToken: "bearer-x4")
                }
            )
            nonisolated(unsafe) let unsafeDefaults = defaults
            coordinator = HealthKitStatisticsSyncCoordinator(
                statisticsService: reader,
                cache: cache,
                uploader: uploader,
                calendar: HourlyFakeReader.calendar(zone),
                clock: { Self.now },
                admission: { lease },
                defaultsProvider: { unsafeDefaults }
            )
            self.api = api
            self.reader = reader
            self.defaults = defaults
            self.context = context
            self.registry = registry
        }

        /// What `GET /api/version` and `/api/auth/me` `features` said.
        func serverSays(version: String, features: Set<KnownServerVersion.Feature>) {
            KnownServerVersion.record(ServerVersionInfo(version: version), defaults: defaults)
            KnownServerVersion.recordFeatures(features, defaults: defaults)
        }

        func serverIsV143() {
            serverSays(version: "1.43.0", features: Set(KnownServerVersion.Feature.allCases))
        }

        var hourlyPosts: [HourlyRecordingAPI.Post] {
            api.posts.filter { $0.externalIds.contains(where: Self.isHourId) }
        }

        var dayPosts: [HourlyRecordingAPI.Post] {
            api.posts.filter { !$0.externalIds.contains(where: Self.isHourId) }
        }

        static func isHourId(_ id: String) -> Bool {
            id.range(of: #"^stats:[A-Za-z]+:\d{4}-\d{2}-\d{2}T\d{2}$"#, options: .regularExpression) != nil
        }

        var ledger: HourlyStatsLedger {
            HourlyStatsLedgerStore.load(ownerID: Self.owner, defaults: defaults)
        }

        /// The `yyyy-MM-dd` key `offset` days before `now` in `calendar`.
        static func dayKey(_ offset: Int, calendar: Calendar = utc) -> String {
            let today = calendar.startOfDay(for: now)
            let day = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            return HealthKitStatisticsService.dayKey(for: day, calendar: calendar)
        }

        static func allowance(days: Int, expired: Bool = false) -> HourlyStatsBackfillAllowance {
            HourlyStatsBackfillAllowance(maxDays: days, timeBudget: 60, isExpired: { expired })
        }
    }

#endif
