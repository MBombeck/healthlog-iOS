import Foundation
@testable import HealthLog
import Synchronization
import Testing

#if canImport(HealthKit)

    /// #3 and #8 — day totals are summed again, never replayed old.
    ///
    /// #3: a day total that did not land used to wait in the outbox. A later
    /// direct send of a newer total landed first, the outbox then replayed the
    /// older value over it, and the cache (which held the newer one) never let
    /// the day be corrected. Now a day total is not queued, queued ones from an
    /// older build go (their days are summed again), and a confirmed send
    /// removes anything still waiting under the same ids.
    ///
    /// #8: a late sample outside the sweep window marks its day, and the next
    /// sweep reaches back to it. A day whose samples were all deleted is sent
    /// once as 0.
    @Suite("HK-STATS — no stale day totals (#3, #8)", .serialized)
    struct HealthKitStatsDurabilityTests {
        static let owner = "account-d"
        /// 2026-10-09 14:00 UTC.
        static let now = Date(timeIntervalSince1970: 1_791_554_400)
        static let steps = "HKQuantityTypeIdentifierStepCount"

        static var utc: Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
            return calendar
        }

        static func day(_ offset: Int) -> Date {
            utc.date(byAdding: .day, value: -offset, to: utc.startOfDay(for: now)) ?? now
        }

        static func dayKey(_ offset: Int) -> String {
            HealthKitStatisticsService.dayKey(for: day(offset), calendar: utc)
        }

        static func row(_ offset: Int, value: Double, type: String = steps) -> HealthKitDailyStatRow {
            HealthKitDailyStatRow(
                hkIdentifier: type,
                dayStart: day(offset),
                dayKey: dayKey(offset),
                value: value,
                unit: "steps",
                timeZoneIdentifier: "UTC"
            )
        }

        static func entry(_ externalId: String, start: Date = day(3)) -> HealthKitBatchEntryDTO {
            HealthKitBatchEntryDTO(
                hkIdentifier: steps,
                value: 3000,
                unit: "steps",
                startDate: start,
                endDate: start,
                externalId: externalId
            )
        }

        /// A read with a fixed answer, which records the window it was asked.
        final class Reader: HealthKitDailyStatsReading, Sendable {
            private let rows: Mutex<[HealthKitDailyStatRow]>
            private let windows = Mutex<[Date]>([])

            init(rows: [HealthKitDailyStatRow]) {
                self.rows = Mutex(rows)
            }

            var froms: [Date] {
                windows.withLock { $0 }
            }

            func dailyRowsForAllDefaults(from: Date, to _: Date) async -> HealthKitDailyStatsRead {
                windows.withLock { $0.append(from) }
                return HealthKitDailyStatsRead(rows: rows.withLock { $0 }, failedTypes: 0)
            }

            func dailyRows(for _: HealthKitCumulativeTypeConfig, from _: Date, to _: Date) async throws -> [HealthKitDailyStatRow] {
                []
            }
        }

        struct Harness {
            let coordinator: HealthKitStatisticsSyncCoordinator
            let cache: HealthKitDailyStatsCache
            let outbox: OutboxQueue
            let api: StatsRecordingAPI
            let reader: Reader
            let lease: HealthSyncAuthenticatedLease
            let defaults: UserDefaults
            /// Retained: the lease holds the registry weakly.
            let registry: AuthenticatedSessionLeaseRegistry
        }

        static func harness(rows: [HealthKitDailyStatRow] = []) throws -> Harness {
            let defaults = try #require(UserDefaults(suiteName: "test.hk.stats.durability.\(UUID().uuidString)"))
            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: owner)
            let lease = try HealthSyncAuthenticatedLease.admit(
                from: registry,
                ownerID: owner,
                source: .dailyStatistics,
                bearerProvider: { "bearer-d" }
            )
            let api = StatsRecordingAPI()
            let reader = Reader(rows: rows)
            let cache = try HealthKitDailyStatsCache(modelContainer: HealthKitDailyStatsCache.makeInMemory())
            let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { owner })
            let uploader = MeasurementBatchUploader(
                api: api,
                throttle: BatchSyncThrottle(maxPerWindow: 600, window: 60.0, jitter: 0 ... 0),
                authenticationSnapshot: {
                    MeasurementUploadAuthenticationSnapshot(ownerUserID: owner, bearerToken: "bearer-d")
                }
            )
            nonisolated(unsafe) let unsafeDefaults = defaults
            let coordinator = HealthKitStatisticsSyncCoordinator(
                statisticsService: reader,
                cache: cache,
                uploader: uploader,
                calendar: utc,
                clock: { now },
                admission: { lease },
                retry: outbox,
                defaultsProvider: { unsafeDefaults }
            )
            return Harness(
                coordinator: coordinator,
                cache: cache,
                outbox: outbox,
                api: api,
                reader: reader,
                lease: lease,
                defaults: defaults,
                registry: registry
            )
        }

        static func queuedExternalIds(_ outbox: OutboxQueue) async -> [String] {
            await outbox.snapshot.filter { $0.kind == .syncHealthKitSample }.flatMap { op in
                (try? JSONDecoder.hlDefault.decode(HealthKitBatchPayload.self, from: op.payload))?.entries.map(\.externalId) ?? []
            }
        }

        // MARK: - #3

        @Test("a day total the server did not take is not queued, and the sweep stays incomplete")
        func heldDayTotalIsNotQueued() async throws {
            let harness = try Self.harness()
            let failing = MeasurementBatchUploader(
                api: FailingBatchAPI(),
                throttle: BatchSyncThrottle(maxPerWindow: 600, window: 60.0, jitter: 0 ... 0),
                authenticationSnapshot: {
                    MeasurementUploadAuthenticationSnapshot(ownerUserID: Self.owner, bearerToken: "bearer-d")
                }
            )
            let coordinator = HealthKitStatisticsSyncCoordinator(
                statisticsService: harness.reader,
                cache: harness.cache,
                uploader: failing,
                calendar: Self.utc,
                clock: { Self.now },
                admission: { [lease = harness.lease] in lease },
                retry: harness.outbox
            )

            let summary = await coordinator.process([Self.row(1, value: 3000)], requiring: harness.lease)

            #expect(!summary.isComplete, "the window is read again by the next sweep")
            #expect(summary.retryQueued == 0)
            #expect(await harness.outbox.snapshot.isEmpty, "a day total never waits in the outbox")
        }

        @Test("a confirmed send removes a waiting row with the same day total")
        func confirmedSendDropsTheWaitingRow() async throws {
            let harness = try Self.harness()
            let id = "stats:\(Self.steps):\(Self.dayKey(1))"
            // An older build queued 3000 for the day; a raw reading shares the page.
            try await harness.outbox.enqueueHealthKitBatch(
                [Self.entry(id), Self.entry("raw-uuid-1")],
                encoder: .hlBatch,
                idempotencyKey: "old-page",
                requiringCurrentOwner: Self.owner
            )

            let summary = await harness.coordinator.process([Self.row(1, value: 8000)], requiring: harness.lease)

            #expect(summary.isComplete)
            #expect(await Self.queuedExternalIds(harness.outbox) == ["raw-uuid-1"], "only the raw reading still waits")
        }

        @Test("a sweep drops day totals an older build queued and sums their days again, however old")
        func queuedDayTotalsAreSummedAgain() async throws {
            let harness = try Self.harness(rows: [Self.row(0, value: 500)])
            let old = "stats:\(Self.steps):\(Self.dayKey(45))"
            try await harness.outbox.enqueueHealthKitBatch(
                [Self.entry(old, start: Self.day(45))],
                encoder: .hlBatch,
                idempotencyKey: "older-build",
                requiringCurrentOwner: Self.owner
            )

            _ = await harness.coordinator.sync(lookbackDays: 1)

            #expect(await harness.outbox.snapshot.isEmpty)
            let from = try #require(harness.reader.froms.first)
            #expect(from <= Self.day(45), "the dropped day is read again from HealthKit")
        }

        // MARK: - #8

        @Test("a late sample's day outside the window is read by the next sweep, and the mark goes after it")
        func dirtyDayWidensTheSweep() async throws {
            let harness = try Self.harness(rows: [Self.row(0, value: 500)])
            HealthKitStatsDirtyDays.mark(Self.day(21).addingTimeInterval(3600), ownerID: Self.owner, defaults: harness.defaults)

            _ = await harness.coordinator.sync(lookbackDays: 1)

            let from = try #require(harness.reader.froms.first)
            #expect(from <= Self.day(21))
            #expect(HealthKitStatsDirtyDays.read(ownerID: Self.owner, defaults: harness.defaults) == nil)

            _ = await harness.coordinator.sync(lookbackDays: 1)
            #expect((harness.reader.froms.last ?? .distantPast) > Self.day(21), "once read, the day is not read again")
        }

        @Test("a mark that arrives during a sweep survives it")
        func newerMarkSurvives() throws {
            let defaults = try #require(UserDefaults(suiteName: "test.hk.dirty.\(UUID().uuidString)"))
            HealthKitStatsDirtyDays.mark(Self.day(10), ownerID: Self.owner, defaults: defaults)
            let read = try #require(HealthKitStatsDirtyDays.read(ownerID: Self.owner, defaults: defaults))
            HealthKitStatsDirtyDays.mark(Self.day(2), ownerID: Self.owner, defaults: defaults)

            HealthKitStatsDirtyDays.clear(read, ownerID: Self.owner, defaults: defaults)

            #expect(HealthKitStatsDirtyDays.read(ownerID: Self.owner, defaults: defaults)?.from == Self.day(10))
        }

        @Test("a day whose samples were deleted is sent once as 0")
        func emptiedDayIsSentAsZero() async throws {
            let harness = try Self.harness(rows: [Self.row(0, value: 500)])
            try await harness.cache.write(ownerUserID: Self.owner, hkIdentifier: Self.steps, dayKey: Self.dayKey(2), lastPostedValue: 4200)

            _ = await harness.coordinator.sync(lookbackDays: 7)

            let emptied = "stats:\(Self.steps):\(Self.dayKey(2))"
            #expect(harness.api.posts.flatMap(\.externalIds).contains(emptied))
            let cached = await harness.cache.read(ownerUserID: Self.owner, hkIdentifier: Self.steps, dayKey: Self.dayKey(2))
            #expect(cached?.lastPostedValue == 0)

            let postsBefore = harness.api.posts.count
            _ = await harness.coordinator.sync(lookbackDays: 7)
            #expect(!harness.api.posts.dropFirst(postsBefore).flatMap(\.externalIds).contains(emptied), "sent once")
        }

        @Test("a type that reads empty in the whole window is left alone (read access may be gone)")
        func wholeWindowEmptyIsNotZeroed() async throws {
            let harness = try Self.harness(rows: [])
            try await harness.cache.write(ownerUserID: Self.owner, hkIdentifier: Self.steps, dayKey: Self.dayKey(2), lastPostedValue: 4200)

            _ = await harness.coordinator.sync(lookbackDays: 7)

            #expect(harness.api.posts.isEmpty)
        }
    }

    /// Answers every batch entry `failed`: not terminal, nothing written.
    final class FailingBatchAPI: APIClientProtocol, @unchecked Sendable {
        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            let object = try request.body.flatMap { try JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let count = (object?["entries"] as? [Any])?.count ?? 0
            let response = HealthKitBatchResponseDTO(
                processed: count,
                inserted: 0,
                duplicates: 0,
                skipped: [],
                entries: (0 ..< count)
                    .map { HealthKitBatchResponseDTO.EntryResult(index: $0, status: .failed, reason: "persistence_error") }
            )
            guard let typed = response as? T else { throw HLError.unknown("test stub: T mismatch") }
            return typed
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.unknown("test stub: download not implemented")
        }
    }

#endif
