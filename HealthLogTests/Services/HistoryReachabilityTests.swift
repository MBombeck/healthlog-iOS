#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Synchronization
    import Testing

    /// A2 (1.4, R3 S6) — without a server, the history walk holds instead of
    /// filling the outbox.
    ///
    /// Up to 1.3.0 an offline phone, or an uploader in its backoff, parked
    /// every history page it read as a 500-row outbox row and moved the date
    /// cursor on: 16 pages per type in a BGProcessing wake, 40 per round of
    /// "Sync everything now", which never noticed it was getting nowhere
    /// because an empty live page counted as progress.
    @Suite("History walk: only while the server answers (A2, S6)", .serialized)
    struct HistoryReachabilityTests {
        private static let heartRate = HistoryWalkA2Fixture.heartRate
        private static let sleep = SplitFixture.sleepType

        private struct Setup {
            /// Held so the admitted session stays current for the whole test.
            let registry: AuthenticatedSessionLeaseRegistry
            let lease: HealthSyncAuthenticatedLease
            let backing: CollectorCursorBacking
            let cursors: DurableHealthCursorStore
            let stores: SimulatedHealthStores
            let consumer: FoldingServerConsumer
        }

        private static func setUp() async throws -> Setup {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let backing = CollectorCursorBacking()
            let cursors = SplitFixture.cursors(backing)
            for type in [heartRate, sleep] {
                _ = try await SplitFixture.replayingKey(cursors, type: type, lease: lease)
            }
            let stores = SimulatedHealthStores([
                heartRate: SimulatedHealthStore(typeIdentifier: heartRate, rows: SplitFixture.rows(historyDays: 3000)),
                sleep: SimulatedHealthStore(typeIdentifier: sleep, rows: SplitFixture.rows(historyDays: 3000))
            ])
            return Setup(
                registry: registry,
                lease: lease,
                backing: backing,
                cursors: cursors,
                stores: stores,
                consumer: FoldingServerConsumer { _, _ in 0 }
            )
        }

        private static func pass(
            _ collector: AnchoredHealthSampleCollector,
            _ setup: Setup
        ) async -> [String: AnchoredHealthSampleCollector.TypeResult] {
            let results = await collector.collect(
                typeIdentifiers: [heartRate, sleep],
                trigger: .processing,
                notBefore: .distantPast,
                requiring: setup.lease
            )
            return Dictionary(uniqueKeysWithValues: results.map { ($0.typeIdentifier, $0) })
        }

        private static func historyReads(_ setup: Setup) -> [String: Int] {
            setup.stores.stores.mapValues(\.historyQueries.count)
        }

        @Test("offline, seen by a live page: the live leg holds and no history is read")
        func offlineLivePageSkipsHistory() async throws {
            let setup = try await Self.setUp()
            let collector = HistoryWalkA2Fixture.collector(setup.cursors, query: setup.stores, consumer: setup.consumer)
            _ = await Self.pass(collector, setup)

            setup.consumer.offline = true
            setup.stores.stores[Self.heartRate]?.insert(start: SplitFixture.now.addingTimeInterval(-60))
            let readsBefore = Self.historyReads(setup)
            let results = await Self.pass(collector, setup)

            #expect(results[Self.heartRate]?.holdReason == .serverUnreachable)
            #expect(Self.historyReads(setup) == readsBefore, "no history page is read while the server is out of reach")
            for type in [Self.heartRate, Self.sleep] {
                #expect(results[type]?.history?.disposition == .deferred)
                #expect(results[type]?.history?.holdReason == .serverUnreachable)
            }
        }

        @Test("offline, seen by a history page: that page holds and the other types are not read")
        func offlineHistoryPageStopsTheRun() async throws {
            let setup = try await Self.setUp()
            let collector = HistoryWalkA2Fixture.collector(setup.cursors, query: setup.stores, consumer: setup.consumer)
            _ = await Self.pass(collector, setup)
            let heartKey = try #require(setup.lease.cursorKey(typeIdentifier: Self.heartRate))
            let before = try #require(await setup.cursors.splitState(for: heartKey))

            setup.consumer.offline = true
            let sleepReadsBefore = setup.stores.stores[Self.sleep]?.historyQueries.count
            let results = await Self.pass(collector, setup)

            #expect(results[Self.heartRate]?.history?.holdReason == .serverUnreachable)
            #expect(results[Self.heartRate]?.history?.acceptedPages == 0)
            #expect(results[Self.sleep]?.history?.disposition == .deferred)
            #expect(results[Self.sleep]?.history?.holdReason == .serverUnreachable)
            #expect(setup.stores.stores[Self.sleep]?.historyQueries.count == sleepReadsBefore)
            let after = try #require(await setup.cursors.splitState(for: heartKey))
            #expect(after.historyEnd == before.historyEnd, "the held page is read again, nothing is skipped")
            #expect(after.historyEndInclusive == before.historyEndInclusive)
        }

        @Test("Sync everything now pauses after three rounds that moved nothing, when the server is out of reach")
        func catchUpStallsOffline() async throws {
            let setup = try await Self.setUp()
            setup.consumer.offline = true
            let collector = HistoryWalkA2Fixture.collector(setup.cursors, query: setup.stores, consumer: setup.consumer)
            let lease = setup.lease
            let defaults = SplitFixture.scratchDefaults()
            // A scratch suite owned by this test alone.
            nonisolated(unsafe) let scratch = defaults
            let coordinator = AppOwnedHealthCollectionCoordinator(
                collector: collector,
                cursors: setup.cursors,
                admission: { lease },
                cutoff: { .distantPast },
                defaultsProvider: { scratch }
            )
            let rounds = Mutex<Int>(0)

            // Bounded: a catch-up that never notices it is stuck is cancelled
            // after six rounds instead of spinning for ever.
            let outcome = await Task {
                await coordinator.runFullCatchUp { _ in
                    let round = rounds.withLock { value -> Int in
                        value += 1
                        return value
                    }
                    if round >= 6 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }.value

            #expect(outcome == .stalled)
            #expect(rounds.withLock { $0 } == AppOwnedHealthCollectionCoordinator.stalledRoundLimit)
        }
    }
#endif
