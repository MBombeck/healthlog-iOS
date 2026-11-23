#if canImport(HealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Synchronization
    import Testing

    /// The history walk stops sending what the
    /// server already holds.
    ///
    /// Production, 1.3.0 on the operator's phone: 92 600 rows in 62 hours, 78
    /// of them new, 92 000 `folded_window` duplicates. The walk resent years of
    /// heart rate whose hours the server had long folded into `stats:` rows,
    /// and it read the raw history of the summed types only to drop every row
    /// at the per-sample gate.
    @Suite("History walk: folded windows and summed types (A2)")
    struct HistoryFoldedWindowTests {
        private static let type = HistoryWalkA2Fixture.heartRate

        private struct Setup {
            /// Held so the admitted session stays current for the whole test.
            let registry: AuthenticatedSessionLeaseRegistry
            let lease: HealthSyncAuthenticatedLease
            let cursors: DurableHealthCursorStore
            let key: HealthSyncCursorKey
            let store: SimulatedHealthStore
        }

        /// `serverOldest`: the oldest reading the server says it holds (#10).
        /// `.some(nil)` leaves it unknown; the default is the oldest row.
        private static func setUp(
            type: String = Self.type,
            rows: [SimulatedHealthStore.Row],
            serverOldest: Date?? = .none
        ) async throws -> Setup {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let cursors = SplitFixture.cursors(CollectorCursorBacking())
            let key = try await SplitFixture.replayingKey(cursors, type: type, lease: lease)
            let oldest: Date? = serverOldest ?? rows.map(\.start).min()
            if let oldest {
                _ = try await cursors.establishSplit(for: key, cutoff: .distantPast, requiring: lease)
                _ = await cursors.updateSplit(for: key, requiring: lease) { $0.serverOldestReading = oldest }
            }
            return Setup(
                registry: registry,
                lease: lease,
                cursors: cursors,
                key: key,
                store: SimulatedHealthStore(typeIdentifier: type, rows: rows)
            )
        }

        @discardableResult
        private static func pass(
            _ collector: AnchoredHealthSampleCollector,
            _ setup: Setup,
            type: String = Self.type,
            trigger: HealthSyncTrigger = .processing
        ) async -> AnchoredHealthSampleCollector.TypeResult? {
            await collector.collect(
                typeIdentifiers: [type],
                trigger: trigger,
                notBefore: .distantPast,
                requiring: setup.lease
            ).first
        }

        // MARK: - Folded windows

        @Test("three history pages in a row that the server had folded end the walk, and the type reads complete")
        func foldedRunEndsTheWalk() async throws {
            let rows = SplitFixture.rows(historyDays: 1200)
            let setup = try await Self.setUp(rows: rows)
            // Everything older than 150 days is folded on the server.
            let consumer = FoldingServerConsumer(foldedBefore: HistoryWalkA2Fixture.historyDay(150).addingTimeInterval(-1800))
            let collector = HistoryWalkA2Fixture.collector(setup.cursors, query: setup.store, consumer: consumer)

            let result = await Self.pass(collector, setup)

            // Page 1 (days 1 to 100) is new, page 2 (101 to 200) straddles the
            // boundary, pages 3, 4 and 5 are folded through: the walk jumps to
            // the server's oldest reading (#10), finds nothing older there in
            // one more read, instead of spending the remaining pages of its
            // budget, and the ~1 000 older days are never read again.
            #expect(setup.store.historyQueries.count == 6)
            #expect(result?.history?.isFinished == true)
            let state = try #require(await setup.cursors.splitState(for: setup.key))
            #expect(state.isHistoryComplete(cutoff: .distantPast))

            let historyReadsBefore = setup.store.historyQueries.count
            await Self.pass(collector, setup)
            #expect(setup.store.historyQueries.count == historyReadsBefore, "a finished type reads no history again")
        }

        @Test("a page the server did not fold breaks the run, so a gap it never had still goes out")
        func unfoldedPageResetsTheRun() async throws {
            let rows = SplitFixture.rows(historyDays: 1200)
            let setup = try await Self.setUp(rows: rows)
            let boundary = HistoryWalkA2Fixture.historyDay(150).addingTimeInterval(-1800)
            // Days 351 to 360 are a hole on the server: not folded, inserted.
            let holeNewest = HistoryWalkA2Fixture.historyDay(351)
            let holeOldest = HistoryWalkA2Fixture.historyDay(360)
            let consumer = FoldingServerConsumer { _, samples in
                samples.count { $0.startDate < boundary && !($0.startDate >= holeOldest && $0.startDate <= holeNewest) }
            }
            let collector = HistoryWalkA2Fixture.collector(setup.cursors, query: setup.store, consumer: consumer)

            let result = await Self.pass(collector, setup)

            // 1 new, 2 straddles, 3 folded, 4 carries the hole, 5 to 7 folded,
            // 8 reads below the server's oldest reading and finds nothing.
            #expect(setup.store.historyQueries.count == 8)
            #expect(result?.history?.isFinished == true)
            let hole = rows.filter { $0.start >= holeOldest && $0.start <= holeNewest }.map(\.anchor)
            #expect(hole.count == 10)
            #expect(Set(hole).isSubset(of: Set(consumer.rows)))
        }

        @Test("without the server naming its oldest reading, a folded run does not end the walk (#10)")
        func unknownServerOldestKeepsWalking() async throws {
            let setup = try await Self.setUp(rows: SplitFixture.rows(historyDays: 3000), serverOldest: .some(nil))
            let consumer = FoldingServerConsumer(foldedBefore: HistoryWalkA2Fixture.historyDay(150).addingTimeInterval(-1800))
            let collector = HistoryWalkA2Fixture.collector(setup.cursors, query: setup.store, consumer: consumer)

            let result = await Self.pass(collector, setup)

            #expect(result?.history?.pagesCollected == HealthSyncBudget.required(for: .processing).historyPagesPerType)
            #expect(result?.history?.isFinished == false, "below the folded years the server may hold nothing")
        }

        @Test("a folded run jumps to the server's oldest reading and the years below it still go out (#10)")
        func foldedRunJumpsToTheServersOldest() async throws {
            let rows = SplitFixture.rows(historyDays: 1200)
            let oldest = HistoryWalkA2Fixture.historyDay(600)
            let setup = try await Self.setUp(rows: rows, serverOldest: .some(oldest))
            let boundary = HistoryWalkA2Fixture.historyDay(150).addingTimeInterval(-1800)
            // Folded from day 150 back to the server's oldest reading; nothing below.
            let consumer = FoldingServerConsumer { _, samples in
                samples.count { $0.startDate < boundary && $0.startDate >= oldest }
            }
            let collector = HistoryWalkA2Fixture.collector(setup.cursors, query: setup.store, consumer: consumer)

            await Self.pass(collector, setup)
            await Self.pass(collector, setup)

            let below = rows.filter { $0.start < oldest }.map(\.anchor)
            #expect(below.count == 600)
            #expect(Set(below).isSubset(of: Set(consumer.rows)), "every reading below the server's oldest is sent")
            let skipped = rows
                .filter { $0.start >= HistoryWalkA2Fixture.historyDay(599) && $0.start < HistoryWalkA2Fixture.historyDay(501) }
            #expect(!skipped.isEmpty && Set(skipped.map(\.anchor)).isDisjoint(with: Set(consumer.rows)), "the folded years are not resent")
        }

        @Test("the jump target is never below the floor and never above the walk")
        func foldedJumpTargetBounds() {
            var state = HealthSampleSplitState(
                version: HealthSampleSplitState.formatVersion,
                origin: .fresh,
                liveStart: HistoryWalkA2Fixture.historyDay(0),
                liveCaughtUp: true,
                historyEnd: HistoryWalkA2Fixture.historyDay(300),
                historyEndInclusive: false,
                replayFloor: nil,
                replayFloorResolved: true,
                legacyLegActive: false,
                fullCatchUp: false,
                updatedAt: SplitFixture.now,
                windowFloor: nil
            )
            #expect(AnchoredHealthSampleCollector.foldedJumpTarget(state, cutoff: .distantPast) == nil, "unknown: no jump")
            state.serverOldestReading = HistoryWalkA2Fixture.historyDay(600)
            #expect(AnchoredHealthSampleCollector.foldedJumpTarget(state, cutoff: .distantPast) == HistoryWalkA2Fixture.historyDay(600))
            state.serverOldestReading = HistoryWalkA2Fixture.historyDay(100)
            #expect(AnchoredHealthSampleCollector.foldedJumpTarget(state, cutoff: .distantPast) == nil, "never forward")
            let cutoff = HistoryWalkA2Fixture.historyDay(400)
            state.serverOldestReading = HistoryWalkA2Fixture.historyDay(900)
            #expect(AnchoredHealthSampleCollector.foldedJumpTarget(state, cutoff: cutoff) == cutoff, "never below the floor")
        }

        @Test("plain duplicates prove nothing about older windows: the walk goes on")
        func plainDuplicatesKeepWalking() async throws {
            let setup = try await Self.setUp(rows: SplitFixture.rows(historyDays: 3000))
            // A server that already has every row, unfolded (`duplicate`
            // without a reason): no `folded_window` in any answer.
            let consumer = FoldingServerConsumer { _, _ in 0 }
            let collector = HistoryWalkA2Fixture.collector(setup.cursors, query: setup.store, consumer: consumer)

            let result = await Self.pass(collector, setup)

            #expect(result?.history?.pagesCollected == HealthSyncBudget.required(for: .processing).historyPagesPerType)
            #expect(result?.history?.isFinished == false)
        }

        @Test("a page that posts nothing (handed to the bucket path) neither counts nor breaks the run")
        func emptyPostNeitherCountsNorBreaks() async throws {
            let setup = try await Self.setUp(rows: SplitFixture.rows(historyDays: 3000))
            // Call 1 is the live page. History pages: folded, folded, nothing
            // posted (all handed off), folded, then unfolded for ever.
            let consumer = FoldingServerConsumer { call, samples in
                [2, 3, 5].contains(call) ? samples.count : 0
            }
            let gate = OnePageHandedOffConsumer(inner: consumer, handedOffCall: 4)
            let collector = HistoryWalkA2Fixture.collector(setup.cursors, query: setup.store, consumer: gate)

            let result = await Self.pass(collector, setup)

            #expect(setup.store.historyQueries.count == 5, "plus the read below the server's oldest reading")
            #expect(result?.history?.isFinished == true)
        }

        // MARK: - backfill

        @Test("history pages go through the history consumption, live pages through the live one")
        func historyPagesAreMarked() async throws {
            let setup = try await Self.setUp(rows: SplitFixture.rows(historyDays: 400))
            let consumer = FoldingServerConsumer { _, _ in 0 }
            let collector = HistoryWalkA2Fixture.collector(setup.cursors, query: setup.store, consumer: consumer)

            let result = await Self.pass(collector, setup, trigger: .foreground)

            let historyPages = try #require(result?.history?.pagesCollected)
            #expect(historyPages > 0)
            #expect(consumer.pageRoutes == [.live] + Array(repeating: .history, count: historyPages))
        }

        // MARK: - Summed types

        @Test("a summed type the statistics path owns never reads raw history, and reads complete")
        func summedTypeSkipsHistory() async throws {
            let steps = HistoryWalkA2Fixture.steps
            let setup = try await Self.setUp(type: steps, rows: SplitFixture.rows(historyDays: 400))
            let consumer = FoldingServerConsumer { _, _ in 0 }
            let collector = HistoryWalkA2Fixture.collector(
                setup.cursors,
                query: setup.store,
                consumer: consumer,
                historyOwnedElsewhere: { $0 == steps }
            )

            let result = await Self.pass(collector, setup, type: steps)

            #expect(setup.store.historyQueries.isEmpty)
            #expect(result?.history?.isFinished == true)
            #expect(consumer.pageRoutes == [.live], "the live stream still runs: it is what kicks the day totals")
            let state = try #require(await setup.cursors.splitState(for: setup.key))
            #expect(state.isHistoryComplete(cutoff: .distantPast))
            #expect(!state.legacyLegActive)
        }

        @Test("the statistics path owns exactly the five summed types, and only while it is switched on")
        func statisticsOwnsTheSummedTypes() {
            for identifier in HealthKitCumulativeTypeConfig.cumulativeIdentifiers {
                #expect(HealthSampleSplitPolicy.historyOwnedByStatistics(identifier, dailyStatsEnabled: true))
                #expect(!HealthSampleSplitPolicy.historyOwnedByStatistics(identifier, dailyStatsEnabled: false))
            }
            for identifier in [
                HKQuantityTypeIdentifier.heartRate.rawValue,
                HKQuantityTypeIdentifier.numberOfTimesFallen.rawValue,
                HKCategoryTypeIdentifier.sleepAnalysis.rawValue
            ] {
                #expect(!HealthSampleSplitPolicy.historyOwnedByStatistics(identifier, dailyStatsEnabled: true))
            }
        }
    }

    /// Hands page `handedOffCall` over without posting anything, the way the
    /// heart-rate bucket gate takes a bucket day off the per-sample path.
    final class OnePageHandedOffConsumer: HealthSamplePageConsuming, Sendable {
        private let inner: FoldingServerConsumer
        private let handedOffCall: Int
        private let calls = Mutex<Int>(0)

        init(inner: FoldingServerConsumer, handedOffCall: Int) {
            self.inner = inner
            self.handedOffCall = handedOffCall
        }

        func consume(
            _ samples: [HKSample],
            ofType typeIdentifier: String,
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HealthSyncPageOutcome {
            await route(samples, typeIdentifier, lease, history: false)
        }

        func consumeHistory(
            _ samples: [HKSample],
            ofType typeIdentifier: String,
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HealthSyncPageOutcome {
            await route(samples, typeIdentifier, lease, history: true)
        }

        private func route(
            _ samples: [HKSample],
            _ typeIdentifier: String,
            _ lease: HealthSyncAuthenticatedLease,
            history: Bool
        ) async -> HealthSyncPageOutcome {
            let call = calls.withLock { value -> Int in
                value += 1
                return value
            }
            if call == handedOffCall {
                _ = await inner.consume([], ofType: typeIdentifier, requiring: lease)
                return ScriptedConsumer.accepted
            }
            return history
                ? await inner.consumeHistory(samples, ofType: typeIdentifier, requiring: lease)
                : await inner.consume(samples, ofType: typeIdentifier, requiring: lease)
        }
    }
#endif
