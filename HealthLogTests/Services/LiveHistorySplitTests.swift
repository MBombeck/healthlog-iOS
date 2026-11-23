#if canImport(HealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Synchronization
    import Testing

    /// The history leg: newest first, persisted, bounded, and
    /// never in the way of the live stream.
    @Suite("Live and history split (#127)")
    struct LiveHistorySplitTests {
        private static let type = CollectorFixture.stepType

        private struct Setup {
            /// Held so the admitted session stays current for the whole test.
            let registry: AuthenticatedSessionLeaseRegistry
            let lease: HealthSyncAuthenticatedLease
            let cursors: DurableHealthCursorStore
            let key: HealthSyncCursorKey
            let store: SimulatedHealthStore
        }

        private static func setUp(rows: [SimulatedHealthStore.Row]) async throws -> Setup {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let cursors = SplitFixture.cursors(CollectorCursorBacking())
            let key = try await SplitFixture.replayingKey(cursors, type: type, lease: lease)
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
            _ trigger: HealthSyncTrigger,
            lease: HealthSyncAuthenticatedLease,
            cutoff: Date = .distantPast
        ) async -> AnchoredHealthSampleCollector.TypeResult? {
            await collector.collect(
                typeIdentifiers: [type],
                trigger: trigger,
                notBefore: cutoff,
                requiring: lease
            ).first
        }

        @Test("the first pass sends the live window first, then history newest first, and remembers how far back it got")
        func historyWalksNewestFirst() async throws {
            let rows = SplitFixture.rows(historyDays: 1200, recent: 5)
            let setup = try await Self.setUp(rows: rows)
            let lease = setup.lease
            let cursors = setup.cursors
            let key = setup.key
            let store = setup.store
            let consumer = RowRecordingConsumer()
            let collector = SplitFixture.collector(cursors, store: store, consumer: consumer)

            let result = await Self.pass(collector, .manual, lease: lease)

            // Live: the five recent rows, before anything else.
            let recent = Set(rows.suffix(5).map(\.anchor))
            #expect(Set(consumer.rows.prefix(5)) == recent)
            // History: four pages of 100, newest start first.
            let history = Array(consumer.rows.dropFirst(5))
            let starts = history.compactMap { anchor in rows.first { $0.anchor == anchor }?.start }
            #expect(history.count >= 400)
            #expect(starts == starts.sorted(by: >))
            #expect(result?.history?.pagesCollected == 4)
            #expect(result?.history?.isFinished == false)

            let state = try #require(await cursors.splitState(for: key))
            #expect(state.liveCaughtUp)
            #expect(state.historyEnd == starts.last)
            #expect(state.historyEndInclusive)
            #expect(store.anchoredQueries.first == HealthSampleDateWindow(start: state.liveStart))
        }

        @Test("passes repeated until done deliver every row, and a finished walk reads nothing more")
        func walkCompletesAndStaysQuiet() async throws {
            let rows = SplitFixture.rows(historyDays: 900, recent: 3)
            let setup = try await Self.setUp(rows: rows)
            let lease = setup.lease
            let cursors = setup.cursors
            let key = setup.key
            let store = setup.store
            let consumer = RowRecordingConsumer()
            let collector = SplitFixture.collector(cursors, store: store, consumer: consumer)

            var finished = false
            for _ in 0 ..< 10 where !finished {
                finished = await Self.pass(collector, .processing, lease: lease)?.history?.isFinished ?? false
            }

            #expect(finished)
            #expect(Set(consumer.rows) == Set(rows.map(\.anchor)))
            let state = try #require(await cursors.splitState(for: key))
            #expect(state.isHistoryComplete(cutoff: .distantPast))

            let historyReads = store.historyQueries.count
            let before = consumer.rows.count
            await Self.pass(collector, .manual, lease: lease)
            #expect(store.historyQueries.count == historyReads)
            #expect(consumer.rows.count == before)
        }

        @Test("short wakes and the observer never walk history")
        func shortWakesNeverWalkHistory() async throws {
            let setup = try await Self.setUp(rows: SplitFixture.rows(historyDays: 50))
            let lease = setup.lease
            let cursors = setup.cursors
            let store = setup.store
            let consumer = RowRecordingConsumer()
            let collector = SplitFixture.collector(cursors, store: store, consumer: consumer)

            for trigger in [HealthSyncTrigger.appRefresh, .silentPush, .observer] {
                let result = await Self.pass(collector, trigger, lease: lease)
                #expect(result?.history == nil)
            }
            #expect(store.historyQueries.isEmpty)
            #expect(Set(consumer.rows).count == 5)
        }

        @Test("history waits until the live stream has reached the present")
        func historyWaitsForLive() async throws {
            // 750 rows in the live window: more than four live pages of 100.
            var rows = SplitFixture.rows(historyDays: 30, recent: 0)
            let start = SplitFixture.now.addingTimeInterval(-3600)
            rows += (1 ... 750).map { SimulatedHealthStore.Row(anchor: 1000 + $0, start: start.addingTimeInterval(-Double($0))) }
            let setup = try await Self.setUp(rows: rows)
            let lease = setup.lease
            let cursors = setup.cursors
            let key = setup.key
            let store = setup.store
            let collector = SplitFixture.collector(cursors, store: store, consumer: RowRecordingConsumer())

            let first = await Self.pass(collector, .manual, lease: lease)
            #expect(first?.history?.disposition == .deferred)
            #expect(store.historyQueries.isEmpty)
            #expect(await cursors.splitState(for: key)?.liveCaughtUp == false)

            let second = await Self.pass(collector, .manual, lease: lease)
            #expect(await cursors.splitState(for: key)?.liveCaughtUp == true)
            #expect((second?.history?.pagesCollected ?? 0) > 0)
        }

        @Test("a history page the server did not accept leaves the cursor where it was")
        func refusedHistoryPageHolds() async throws {
            let setup = try await Self.setUp(rows: SplitFixture.rows(historyDays: 400))
            let lease = setup.lease
            let cursors = setup.cursors
            let key = setup.key
            let store = setup.store
            // Call 1 is the live page; call 2 is the first history page.
            let consumer = RowRecordingConsumer(refusing: { $0 == 2 })
            let collector = SplitFixture.collector(cursors, store: store, consumer: consumer)

            let result = await Self.pass(collector, .manual, lease: lease)

            #expect(result?.history?.disposition == .failed)
            #expect(result?.history?.holdReason == .nonterminalEntry)
            let state = try #require(await cursors.splitState(for: key))
            #expect(state.historyEnd == state.liveStart)
            #expect(!state.historyEndInclusive)
        }

        @Test("cancelled in the middle: the next run resumes at the last accepted page and nothing is skipped")
        func cancellationResumesWithoutGap() async throws {
            let rows = SplitFixture.rows(historyDays: 600, recent: 2)
            let setup = try await Self.setUp(rows: rows)
            let lease = setup.lease
            let cursors = setup.cursors
            let store = setup.store
            let task = Mutex<Task<AnchoredHealthSampleCollector.TypeResult?, Never>?>(nil)
            let consumer = RowRecordingConsumer(onPage: { call in
                if call == 3 { task.withLock { $0?.cancel() } }
            })
            let collector = SplitFixture.collector(cursors, store: store, consumer: consumer)

            // Created under the lock, so the third page cannot ask for the task
            // before it is stored.
            let running = task.withLock { slot in
                let created = Task { await Self.pass(collector, .processing, lease: lease) }
                slot = created
                return created
            }
            let cancelled = await running.value
            #expect(cancelled?.history?.disposition == .expired)
            #expect(cancelled?.history?.isFinished == false)

            var finished = false
            for _ in 0 ..< 10 where !finished {
                finished = await Self.pass(collector, .processing, lease: lease)?.history?.isFinished ?? false
            }
            #expect(finished)
            #expect(Set(consumer.rows) == Set(rows.map(\.anchor)))
        }

        @Test("a full page that is one single instant is read whole and stepped past")
        func singleInstantPageIsSteppedPast() async throws {
            let instant = SplitFixture.now.addingTimeInterval(-10 * 86400)
            var rows = (1 ... 150).map { SimulatedHealthStore.Row(anchor: $0, start: instant) }
            rows.append(.init(anchor: 151, start: instant.addingTimeInterval(-86400)))
            let setup = try await Self.setUp(rows: rows)
            let lease = setup.lease
            let cursors = setup.cursors
            let key = setup.key
            let store = setup.store
            let consumer = RowRecordingConsumer()
            let collector = SplitFixture.collector(cursors, store: store, consumer: consumer)

            await Self.pass(collector, .processing, lease: lease)

            #expect(Set(consumer.rows) == Set(rows.map(\.anchor)))
            #expect(try #require(await cursors.splitState(for: key)).isHistoryComplete(cutoff: .distantPast))
        }

        @Test("a sample written later with an old date still arrives, through the live stream")
        func lateOldSampleArrivesThroughLive() async throws {
            let setup = try await Self.setUp(rows: SplitFixture.rows(historyDays: 20))
            let lease = setup.lease
            let cursors = setup.cursors
            let store = setup.store
            let consumer = RowRecordingConsumer()
            let collector = SplitFixture.collector(cursors, store: store, consumer: consumer)
            await Self.pass(collector, .processing, lease: lease)

            // A ring app writes three-year-old nights into Health after the
            // walk has passed them.
            let late = store.insert(start: SplitFixture.now.addingTimeInterval(-3 * 365 * 86400))
            await Self.pass(collector, .observer, lease: lease)

            #expect(consumer.rows.contains(late.anchor))
        }

        @Test("history stops at the chosen window")
        func historyStopsAtTheWindow() async throws {
            let rows = SplitFixture.rows(historyDays: 400)
            let setup = try await Self.setUp(rows: rows)
            let lease = setup.lease
            let cursors = setup.cursors
            let key = setup.key
            let store = setup.store
            let consumer = RowRecordingConsumer()
            let collector = SplitFixture.collector(cursors, store: store, consumer: consumer)
            let cutoff = SplitFixture.now.addingTimeInterval(-90 * 86400)

            for _ in 0 ..< 3 {
                await Self.pass(collector, .processing, lease: lease, cutoff: cutoff)
            }

            let expected = Set(rows.filter { $0.start >= cutoff }.map(\.anchor))
            #expect(Set(consumer.rows) == expected)
            #expect(try #require(await cursors.splitState(for: key)).isHistoryComplete(cutoff: cutoff))
        }

        @Test("the history time budget stops a run between pages")
        func timeBudgetStopsTheRun() async throws {
            let uptime = SteppingUptime()
            let setup = try await Self.setUp(rows: SplitFixture.rows(historyDays: 3000))
            let lease = setup.lease
            let cursors = setup.cursors
            let store = setup.store
            // Every page costs 8 s of the foreground's 20 s.
            let consumer = RowRecordingConsumer(onPage: { _ in uptime.advance(8) })
            let collector = SplitFixture.collector(cursors, store: store, consumer: consumer, uptime: uptime)

            let result = await Self.pass(collector, .foreground, lease: lease)

            #expect(result?.history?.disposition == .expired)
            #expect(result?.history?.pagesCollected == 3)
        }

        @Test("budgets: live on every trigger, history only where a walk is allowed")
        func budgets() {
            for trigger in HealthSyncTrigger.allCases {
                let budget = HealthSyncBudget.required(for: trigger)
                if budget.allowsFirstHistoryImport {
                    #expect(budget.historyPagesPerType > 0 && budget.historyTimeBudget > 0)
                } else {
                    #expect(budget.historyPagesPerType == 0)
                }
            }
            #expect(HealthSyncBudget.required(for: .observer).maxPagesPerType == 1)
        }
    }
#endif
