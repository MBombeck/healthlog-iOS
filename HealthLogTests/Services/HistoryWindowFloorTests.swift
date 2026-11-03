#if canImport(HealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Synchronization
    import Testing

    /// 1.4 (S1) — the chosen window keeps its oldest days.
    ///
    /// 1.3.0 recomputed the window's lower bound from "now" on every pass.
    /// With 7, 30 or 90 days or a year chosen, the bound moved forward a day
    /// a day while the history walk moved back, the two met early, and the
    /// oldest part of the window was never read. The bound is now pinned per
    /// partition. The update path starts from the exact split state a 1.3.0
    /// build leaves behind.
    @Suite("S1 — the chosen window's lower bound is pinned")
    struct HistoryWindowFloorTests {
        private static let type = CollectorFixture.stepType
        private static let day: TimeInterval = 86400
        private static let start = SplitFixture.now

        /// A wall clock the test moves, for the cursors and the collector.
        final class WallClock: Sendable {
            private let value: Mutex<Date>

            init(_ start: Date) {
                value = Mutex(start)
            }

            var now: Date {
                value.withLock { $0 }
            }

            func advance(days: Double) {
                value.withLock { $0 = $0.addingTimeInterval(days * 86400) }
            }
        }

        /// The split record as 1.3.0 wrote it, plus the 1.4 pin, read and
        /// written through the store's own coder. With `windowFloor == nil`
        /// it encodes to exactly the bytes a 1.3.0 build left on disk.
        struct StoredSplit: Codable, Equatable {
            var version = 1
            var origin: String
            var liveStart: Date
            var liveCaughtUp = true
            var historyEnd: Date
            var historyEndInclusive = false
            var replayFloor: Date?
            var replayFloorResolved = true
            var legacyLegActive = false
            var fullCatchUp = false
            var updatedAt: Date
            var windowFloor: Date?
        }

        private struct Setup {
            /// Held so the admitted session stays current for the whole test.
            let registry: AuthenticatedSessionLeaseRegistry
            let lease: HealthSyncAuthenticatedLease
            let cursors: DurableHealthCursorStore
            let key: HealthSyncCursorKey
            let store: SimulatedHealthStore
            let consumer: RowRecordingConsumer
            let collector: AnchoredHealthSampleCollector
        }

        private static func setUp(
            rows: [SimulatedHealthStore.Row],
            wall: WallClock,
            pageLimit: Int = 100
        ) async throws -> Setup {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let cursors = DurableHealthCursorStore(storage: CollectorCursorBacking().storage, clock: { wall.now })
            let key = try await SplitFixture.replayingKey(cursors, type: type, lease: lease)
            let store = SimulatedHealthStore(typeIdentifier: type, rows: rows)
            let consumer = RowRecordingConsumer()
            let uptime = SteppingUptime()
            let collector = AnchoredHealthSampleCollector(
                cursors: cursors,
                query: store,
                consumer: consumer,
                history: store,
                pageLimit: pageLimit,
                clock: HealthSampleSplitClock(now: { wall.now }, uptime: { uptime.now })
            )
            return Setup(
                registry: registry,
                lease: lease,
                cursors: cursors,
                key: key,
                store: store,
                consumer: consumer,
                collector: collector
            )
        }

        /// Four rows a day from `days` days before the start to an hour
        /// before it, inserted oldest first.
        private static func dailyRows(days: Int) -> [SimulatedHealthStore.Row] {
            (0 ..< days * 4).map { index in
                SimulatedHealthStore.Row(
                    anchor: index + 1,
                    start: start.addingTimeInterval(-Double(days) * day + Double(index) * 6 * 3600 + 1800)
                )
            }
        }

        /// The 30-day window's bound as the person's calendar computes it.
        private static func thirtyDays(at date: Date) -> Date {
            HealthKitBackfillWindow.thirtyDays.lowerBound(now: date)
        }

        /// Passes under `cutoff` until the history leg reports it finished.
        private static func walkToTheEnd(_ setup: Setup, cutoff: @escaping () -> Date) async -> Bool {
            for _ in 0 ..< 20 {
                let result = await setup.collector.collect(
                    typeIdentifiers: [type],
                    trigger: .processing,
                    notBefore: cutoff(),
                    requiring: setup.lease
                ).first
                if result?.history?.isFinished == true { return true }
            }
            return false
        }

        private static func storedSplit(_ setup: Setup) async -> StoredSplit? {
            await setup.cursors.readSibling(StoredSplit.self, suffix: DurableHealthCursorStore.splitSuffix, for: setup.key)
        }

        /// A partition 1.3.0 left behind, `establishedDaysAgo` days ago, with
        /// its live cursor at the end of the store.
        private static func install130(
            _ setup: Setup,
            rows: [SimulatedHealthStore.Row],
            split: StoredSplit
        ) async throws {
            let last = try #require(rows.map(\.anchor).max())
            try await setup.cursors.save(HKQueryAnchor(fromValue: last), for: setup.key, requiring: setup.lease)
            #expect(await setup.cursors.writeSiblingVerified(split, suffix: DurableHealthCursorStore.splitSuffix, for: setup.key))
            // 1.4 reads the 1.3.0 record: no pin yet, nothing lost in decoding.
            let decoded = try #require(await setup.cursors.splitState(for: setup.key))
            #expect(decoded.liveStart == split.liveStart)
            #expect(decoded.historyEnd == split.historyEnd)
        }

        // MARK: - The walk takes days

        @Test("a walk that takes days still reaches the window's oldest day, and no further")
        func slowWalkReachesTheChosenWindow() async throws {
            let wall = WallClock(Self.start)
            let rows = Self.dailyRows(days: 60)
            let setup = try await Self.setUp(rows: rows, wall: wall, pageLimit: 10)
            let chosenFloor = Self.thirtyDays(at: Self.start)
            let liveStart = Self.start.addingTimeInterval(-HealthSampleSplitPolicy.liveLookback)

            // The first pass establishes the split and walks two pages.
            await setup.collector.collect(
                typeIdentifiers: [Self.type],
                trigger: .processing,
                notBefore: chosenFloor,
                requiring: setup.lease,
                historyBudget: HealthSampleHistoryBudget(pagesPerType: 2, timeBudget: 60)
            )
            #expect(await setup.cursors.splitState(for: setup.key)?.historyEnd ?? .distantPast > chosenFloor)

            // Twenty days on, the bound recomputed from "now" has moved past
            // two thirds of the window.
            wall.advance(days: 20)
            #expect(await Self.walkToTheEnd(setup) { Self.thirtyDays(at: wall.now) })

            let consumed = Set(setup.consumer.rows)
            let owed = rows.filter { $0.start >= chosenFloor && $0.start < liveStart }
            #expect(!owed.isEmpty)
            #expect(owed.allSatisfy { consumed.contains($0.anchor) }, "every day of the window chosen on day one")
            #expect(rows.filter { $0.start < chosenFloor }.allSatisfy { !consumed.contains($0.anchor) }, "nothing older")
            #expect(await Self.storedSplit(setup)?.windowFloor == chosenFloor)
        }

        // MARK: - Update path from 1.3.0

        @Test("update path: a 1.3.0 partition whose walk stopped at the moved bound reads the days it skipped")
        func updatePathFreshPartition() async throws {
            let wall = WallClock(Self.start)
            let rows = Self.dailyRows(days: 70)
            let setup = try await Self.setUp(rows: rows, wall: wall)
            // Established twenty days ago; the walk finished five days later
            // at the bound of that day.
            let established = Self.start.addingTimeInterval(-20 * Self.day)
            let floorThen = Self.thirtyDays(at: established)
            let stoppedAt = Self.thirtyDays(at: established.addingTimeInterval(5 * Self.day))
            try await Self.install130(setup, rows: rows, split: StoredSplit(
                origin: "fresh",
                liveStart: established.addingTimeInterval(-HealthSampleSplitPolicy.liveLookback),
                historyEnd: stoppedAt,
                updatedAt: established.addingTimeInterval(5 * Self.day)
            ))

            #expect(await Self.walkToTheEnd(setup) { Self.thirtyDays(at: wall.now) })

            let consumed = Set(setup.consumer.rows)
            let skipped = rows.filter { $0.start >= floorThen && $0.start < stoppedAt }
            #expect(!skipped.isEmpty)
            #expect(skipped.allSatisfy { consumed.contains($0.anchor) }, "the days the moving bound skipped")
            #expect(rows.filter { $0.start >= stoppedAt }.allSatisfy { !consumed.contains($0.anchor) }, "nothing sent twice")
            // Pinned once, at the bound of the day the partition was made,
            // with no more than the margin towards overlap.
            let pin = try #require(await Self.storedSplit(setup)?.windowFloor)
            #expect(pin <= floorThen)
            #expect(pin >= floorThen.addingTimeInterval(-2 * Self.day))
            #expect(rows.filter { $0.start < pin }.allSatisfy { !consumed.contains($0.anchor) })
        }

        @Test("update path: an upgraded 1.3.0 partition resumes the legacy leg the moving bound retired")
        func updatePathUpgradedPartition() async throws {
            let wall = WallClock(Self.start)
            var rows = Self.dailyRows(days: 70)
            let established = Self.start.addingTimeInterval(-20 * Self.day)
            let floorThen = Self.thirtyDays(at: established)
            // The server held the type up to 18 days before the upgrade, so
            // the replay floor sat 25 days back; the legacy leg owed the dates
            // below it and was retired once the moving bound passed it.
            let replayFloor = established.addingTimeInterval(-25 * Self.day)
            let legacyPosition = try #require(rows.map(\.anchor).max())
            // Old nights a ring app wrote into Health after that.
            let late = (1 ... 6).map { index in
                SimulatedHealthStore.Row(
                    anchor: legacyPosition + index,
                    start: floorThen.addingTimeInterval(Double(index) * 12 * 3600)
                )
            }
            rows += late
            let setup = try await Self.setUp(rows: rows, wall: wall)
            let anchor = try #require(HealthKitAnchorArchive.encodeAnchor(
                HKQueryAnchor(fromValue: legacyPosition),
                label: setup.key.source.rawValue
            ))
            let legacy = DurableHealthCursorStore.CursorRecord(
                version: DurableHealthCursorStore.formatVersion,
                anchor: anchor,
                updatedAt: established
            )
            #expect(await setup.cursors.writeSiblingVerified(legacy, suffix: DurableHealthCursorStore.legacySuffix, for: setup.key))
            let stoppedAt = Self.thirtyDays(at: established.addingTimeInterval(10 * Self.day))
            try await Self.install130(setup, rows: rows, split: StoredSplit(
                origin: "upgrade",
                liveStart: established.addingTimeInterval(-HealthSampleSplitPolicy.liveLookback),
                historyEnd: stoppedAt,
                replayFloor: replayFloor,
                updatedAt: established.addingTimeInterval(10 * Self.day)
            ))
            #expect(late.allSatisfy { $0.start >= floorThen && $0.start < replayFloor })

            #expect(await Self.walkToTheEnd(setup) { Self.thirtyDays(at: wall.now) })

            let consumed = Set(setup.consumer.rows)
            #expect(late.allSatisfy { consumed.contains($0.anchor) }, "the rows the retired legacy leg still owed")
            let stored = try #require(await Self.storedSplit(setup))
            #expect(!stored.legacyLegActive, "retired again once it came back short")
            #expect(stored.windowFloor != nil)
        }

        // MARK: - "Alle" and the order of choice and split

        @Test("Alle stays unbounded, and a window chosen after the split was made is pinned on the next pass")
        func allTimeAndLateChoice() async throws {
            let wall = WallClock(Self.start)
            let rows = Self.dailyRows(days: 60)
            let setup = try await Self.setUp(rows: rows, wall: wall)

            // No window yet ("Alle", or the choice not made): everything.
            let unbounded = try await setup.cursors.establishSplit(for: setup.key, cutoff: .distantPast, requiring: setup.lease)
            #expect(unbounded.historyFloor(cutoff: .distantPast) == .distantPast)
            #expect(await Self.storedSplit(setup)?.windowFloor == nil)

            // The person picks 30 days; from then on the walk ends there.
            let chosen = Self.thirtyDays(at: Self.start)
            #expect(await Self.walkToTheEnd(setup) { chosen })
            let consumed = Set(setup.consumer.rows)
            #expect(rows.filter { $0.start >= chosen }.allSatisfy { consumed.contains($0.anchor) })
            #expect(rows.filter { $0.start < chosen.addingTimeInterval(-2 * Self.day) }.allSatisfy { !consumed.contains($0.anchor) })
            let pin = try #require(await Self.storedSplit(setup)?.windowFloor)
            #expect(pin <= chosen)

            // A pinned partition under "Alle" again (a new choice after the
            // next sign-in) is unbounded again.
            let pinned = try #require(await setup.cursors.splitState(for: setup.key))
            #expect(pinned.historyFloor(cutoff: .distantPast) == .distantPast)
        }
    }
#endif
