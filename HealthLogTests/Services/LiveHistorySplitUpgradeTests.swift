#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Synchronization
    import Testing

    /// The update path from an existing 1.2.0 installation.
    ///
    /// A fresh install proves little here. The cases that matter are the
    /// phones already in the field: a partition whose one shared cursor is
    /// halfway through years of history, one that is fully current,
    /// and one whose server cannot be asked right now. Each starts from the
    /// exact storage a 1.2.0 build leaves behind and runs the production
    /// coordinator over it.
    @Suite("Live and history split: update from 1.2.0 (#127, #128)")
    struct LiveHistorySplitUpgradeTests {
        private static let sleep = SplitFixture.sleepType

        /// What #1204's sleep looked like: 2 000 old rows inserted oldest
        /// first, five from last night, and 50 old nights a ring app wrote into
        /// Health later, after the 1.2.0 cursor had passed their dates.
        private static func fieldRows() -> [SimulatedHealthStore.Row] {
            var rows = SplitFixture.rows(historyDays: 1000, perDay: 2, recent: 5)
            let oldest = rows[0].start
            rows += (1 ... 50).map { index in
                SimulatedHealthStore.Row(anchor: 2005 + index, start: oldest.addingTimeInterval(Double(index) * 86400 + 1800))
            }
            return rows
        }

        final class FreshnessAnswers: Sendable {
            private let answers: Mutex<[[MetricFreshness]?]>
            private let asked = Mutex<Int>(0)

            init(_ answers: [[MetricFreshness]?]) {
                self.answers = Mutex(answers)
            }

            var count: Int {
                asked.withLock { $0 }
            }

            func next() -> [MetricFreshness]? {
                asked.withLock { $0 += 1 }
                return answers.withLock { queue in
                    queue.count > 1 ? queue.removeFirst() : queue.first.flatMap(\.self)
                }
            }
        }

        private struct Install {
            /// Held so the admitted session stays current for the whole test.
            let registry: AuthenticatedSessionLeaseRegistry
            let lease: HealthSyncAuthenticatedLease
            let backing: CollectorCursorBacking
            let key: HealthSyncCursorKey
            let store: SimulatedHealthStore
            let consumer: RowRecordingConsumer
            let defaults: UserDefaults
        }

        /// The storage of a 1.2.0 phone: every partition migrated and
        /// replaying, the sleep partition's shared cursor after `cursorAt`.
        private static func install(
            rows: [SimulatedHealthStore.Row],
            cursorAt: Int
        ) async throws -> Install {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let backing = CollectorCursorBacking()
            let cursors = SplitFixture.cursors(backing)
            _ = await SpeziAnchorMigrator.migrateAccountCursors(store: cursors, requiring: lease)
            let key = try #require(lease.cursorKey(typeIdentifier: sleep))
            try await cursors.save(HKQueryAnchor(fromValue: cursorAt), for: key, requiring: lease)
            #expect(await cursors.splitState(for: key) == nil)
            return Install(
                registry: registry,
                lease: lease,
                backing: backing,
                key: key,
                store: SimulatedHealthStore(typeIdentifier: sleep, rows: rows),
                consumer: RowRecordingConsumer(),
                defaults: SplitFixture.scratchDefaults()
            )
        }

        /// The fixed build on that storage. A new coordinator is a relaunch.
        private static func coordinator(
            _ install: Install,
            freshness: FreshnessAnswers?
        ) -> AppOwnedHealthCollectionCoordinator {
            let cursors = SplitFixture.cursors(install.backing)
            let lease = install.lease
            // A scratch suite owned by this test alone.
            nonisolated(unsafe) let defaults = install.defaults
            return AppOwnedHealthCollectionCoordinator(
                collector: SplitFixture.collector(cursors, store: install.store, consumer: install.consumer, pageLimit: 200),
                cursors: cursors,
                admission: { lease },
                cutoff: { .distantPast },
                defaultsProvider: { defaults },
                serverFreshness: freshness.map { answers in { @Sendable in answers.next() } }
            )
        }

        private static func sleepFreshness(lastSeenAt: Date) -> [MetricFreshness] {
            [
                MetricFreshness(type: "SLEEP_DURATION", lastSeenAt: lastSeenAt),
                MetricFreshness(type: "PULSE", lastSeenAt: SplitFixture.now)
            ]
        }

        private static func runUntilFinished(_ coordinator: AppOwnedHealthCollectionCoordinator) async -> Bool {
            for _ in 0 ..< 30 {
                await coordinator.run(.processing)
                if await coordinator.historyOverview()?.isFinished == true { return true }
            }
            return false
        }

        @Test("update path: a half-walked 1.2.0 partition sends last night first and loses nothing")
        func halfWalkedUpgrade() async throws {
            let rows = Self.fieldRows()
            let install = try await Self.install(rows: rows, cursorAt: 600)
            let lastSeen = try #require(rows.first { $0.anchor == 600 }).start
            let coordinator = Self.coordinator(install, freshness: FreshnessAnswers([Self.sleepFreshness(lastSeenAt: lastSeen)]))

            await coordinator.run(.manual)

            // Live first: last night before any old row.
            let recent = Set(rows.filter { (2001 ... 2005).contains($0.anchor) }.map(\.anchor))
            #expect(Set(install.consumer.rows.prefix(5)) == recent)
            let cursors = SplitFixture.cursors(install.backing)
            let state = try #require(await cursors.splitState(for: install.key))
            #expect(state.origin == .upgrade)
            #expect(state.replayFloor == lastSeen.addingTimeInterval(-HealthSampleSplitPolicy.replayMargin))
            #expect(await cursors.legacyAnchor(for: install.key) != nil)

            #expect(await Self.runUntilFinished(coordinator))

            let consumed = Set(install.consumer.rows)
            // Nothing the 1.2.0 cursor had not delivered is missing, including
            // the old nights written after it passed their dates.
            #expect(rows.filter { $0.anchor > 600 }.allSatisfy { consumed.contains($0.anchor) })
            // And the years it had delivered are not sent again: only the
            // seven-day margin below the server's newest row.
            let floor = try #require(state.replayFloor)
            let resent = rows.filter { $0.anchor <= 600 && consumed.contains($0.anchor) }
            #expect(resent.allSatisfy { $0.start >= floor })
            #expect(resent.count <= 16)
            #expect(await cursors.splitState(for: install.key)?.legacyLegActive == false)
        }

        @Test("update path: a fully current 1.2.0 partition re-sends only the last days")
        func currentUpgrade() async throws {
            let rows = SplitFixture.rows(historyDays: 1000, perDay: 2, recent: 5)
            let install = try await Self.install(rows: rows, cursorAt: 2005)
            let coordinator = Self.coordinator(
                install,
                freshness: FreshnessAnswers([Self.sleepFreshness(lastSeenAt: SplitFixture.now.addingTimeInterval(-3600))])
            )

            await coordinator.run(.manual)

            #expect(await coordinator.historyOverview()?.isFinished == true)
            #expect(install.consumer.rows.count <= 20)
        }

        @Test("update path: without an answer from the server, live runs and history waits for the next pass")
        func unansweredServerDefersHistory() async throws {
            let rows = Self.fieldRows()
            let install = try await Self.install(rows: rows, cursorAt: 600)
            let lastSeen = try #require(rows.first { $0.anchor == 600 }).start
            let answers = FreshnessAnswers([nil, Self.sleepFreshness(lastSeenAt: lastSeen)])
            let coordinator = Self.coordinator(install, freshness: answers)
            let cursors = SplitFixture.cursors(install.backing)

            await coordinator.run(.manual)
            let waiting = try #require(await cursors.splitState(for: install.key))
            #expect(!waiting.replayFloorResolved)
            #expect(waiting.historyEnd == waiting.liveStart)
            #expect(Set(install.consumer.rows) == Set(2001 ... 2005))

            await coordinator.run(.manual)
            let resolved = try #require(await cursors.splitState(for: install.key))
            #expect(resolved.replayFloorResolved)
            #expect(resolved.historyEnd < resolved.liveStart)
            #expect(answers.count == 2)
        }

        @Test("update path: a short wake never asks the server and never walks history")
        func shortWakeDoesNotResolve() async throws {
            let install = try await Self.install(rows: Self.fieldRows(), cursorAt: 600)
            let answers = FreshnessAnswers([[]])
            let coordinator = Self.coordinator(install, freshness: answers)

            await coordinator.run(.appRefresh)

            #expect(answers.count < 1)
            #expect(Set(install.consumer.rows) == Set(2001 ... 2005))
        }

        @Test("update path: a server without rows for the type walks the whole window and retires the old cursor")
        func noServerRowsWalksEverything() async throws {
            let rows = Self.fieldRows()
            let install = try await Self.install(rows: rows, cursorAt: 600)
            let coordinator = Self.coordinator(install, freshness: FreshnessAnswers([[]]))

            #expect(await Self.runUntilFinished(coordinator))

            #expect(Set(install.consumer.rows) == Set(rows.map(\.anchor)))
            let state = try #require(await SplitFixture.cursors(install.backing).splitState(for: install.key))
            #expect(state.replayFloor == nil)
            #expect(!state.legacyLegActive)
        }

        @Test("Sync everything now walks the whole window, past the #128 shortcut, and reports progress")
        func fullCatchUpWalksEverything() async throws {
            let rows = Self.fieldRows()
            let install = try await Self.install(rows: rows, cursorAt: 600)
            let lastSeen = try #require(rows.first { $0.anchor == 600 }).start
            let coordinator = Self.coordinator(install, freshness: FreshnessAnswers([Self.sleepFreshness(lastSeenAt: lastSeen)]))
            await coordinator.run(.manual)

            let rounds = Mutex<[HealthHistoryOverview]>([])
            let outcome = await coordinator.runFullCatchUp { overview in
                rounds.withLock { $0.append(overview) }
            }

            #expect(outcome == .finished)
            #expect(rounds.withLock { $0.last?.isFinished } == true)
            #expect(Set(install.consumer.rows) == Set(rows.map(\.anchor)))
            let state = try #require(await SplitFixture.cursors(install.backing).splitState(for: install.key))
            #expect(state.fullCatchUp)
            #expect(!state.legacyLegActive)
        }

        @Test("Sync everything now stops when cancelled and the next run carries on")
        func fullCatchUpCancels() async throws {
            let rows = SplitFixture.rows(historyDays: 3000, perDay: 4, recent: 2)
            let install = try await Self.install(rows: rows, cursorAt: 0)
            let coordinator = Self.coordinator(install, freshness: FreshnessAnswers([[]]))

            let task = Task {
                await coordinator.runFullCatchUp { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            #expect(await task.value == .cancelled)
            let afterCancel = Set(install.consumer.rows)
            #expect(afterCancel.count < rows.count)

            #expect(await coordinator.runFullCatchUp { _ in } == .finished)
            #expect(Set(install.consumer.rows) == Set(rows.map(\.anchor)))
        }
    }

    /// 1.3 — the split records in the cursor store.
    @Suite("Live and history split: cursor store records")
    struct LiveHistorySplitStoreTests {
        private static let type = SplitFixture.sleepType

        @Test("establishing the split moves a 1.2.0 cursor aside exactly once")
        func establishMovesCursorOnce() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let cursors = SplitFixture.cursors(CollectorCursorBacking())
            let key = try await SplitFixture.replayingKey(cursors, type: Self.type, lease: lease)
            try await cursors.save(HKQueryAnchor(fromValue: 42), for: key, requiring: lease)

            let first = try await cursors.establishSplit(for: key, cutoff: .distantPast, requiring: lease)
            #expect(first.origin == .upgrade)
            #expect(first.liveStart == SplitFixture.now.addingTimeInterval(-HealthSampleSplitPolicy.liveLookback))
            #expect(await cursors.anchor(for: key) == nil)
            let legacy = try #require(await cursors.legacyAnchor(for: key))

            // The live stream commits; establishing again changes nothing.
            try await cursors.save(HKQueryAnchor(fromValue: 77), for: key, requiring: lease)
            let second = try await cursors.establishSplit(for: key, cutoff: .distantPast, requiring: lease)
            #expect(second == first)
            #expect(await cursors.legacyAnchor(for: key) == legacy)
            #expect(await cursors.queryAnchor(for: key) == HKQueryAnchor(fromValue: 77))
        }

        @Test("a crash between moving the cursor and writing the state still counts as an upgrade")
        func crashAfterMoveIsStillUpgrade() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let cursors = SplitFixture.cursors(CollectorCursorBacking())
            let key = try await SplitFixture.replayingKey(cursors, type: Self.type, lease: lease)
            let record = DurableHealthCursorStore.CursorRecord(
                version: DurableHealthCursorStore.formatVersion,
                anchor: Data([1, 2, 3]),
                updatedAt: SplitFixture.now
            )
            #expect(await cursors.writeSiblingVerified(record, suffix: DurableHealthCursorStore.legacySuffix, for: key))

            let state = try await cursors.establishSplit(for: key, cutoff: .distantPast, requiring: lease)
            #expect(state.origin == .upgrade)
            #expect(state.legacyLegActive)
            #expect(!state.replayFloorResolved)
        }

        @Test("a fresh partition starts its live stream inside the chosen window")
        func freshPartitionHonoursTheWindow() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let cursors = SplitFixture.cursors(CollectorCursorBacking())
            let key = try await SplitFixture.replayingKey(cursors, type: Self.type, lease: lease)
            let cutoff = SplitFixture.now.addingTimeInterval(-3600)

            let state = try await cursors.establishSplit(for: key, cutoff: cutoff, requiring: lease)
            #expect(state.origin == .fresh)
            #expect(state.liveStart == cutoff)
            #expect(state.replayFloorResolved)
            #expect(!state.legacyLegActive)
            #expect(state.isHistoryComplete(cutoff: cutoff))
        }

        @Test("the #113 reset clears the split and the legacy cursor with the live one")
        func resetClearsEverything() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let cursors = SplitFixture.cursors(CollectorCursorBacking())
            let key = try await SplitFixture.replayingKey(cursors, type: Self.type, lease: lease)
            try await cursors.save(HKQueryAnchor(fromValue: 42), for: key, requiring: lease)
            _ = try await cursors.establishSplit(for: key, cutoff: .distantPast, requiring: lease)

            #expect(try await cursors.resetCursorOnce("w2-test", for: key, requiring: lease))
            #expect(await cursors.splitState(for: key) == nil)
            #expect(await cursors.legacyAnchor(for: key) == nil)
            #expect(await cursors.anchor(for: key) == nil)
            let again = try await cursors.establishSplit(for: key, cutoff: .distantPast, requiring: lease)
            #expect(again.origin == .fresh)
        }

        @Test("another account cannot establish or move a partition")
        func ownerBound() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let cursors = SplitFixture.cursors(CollectorCursorBacking())
            let foreign = try #require(HealthSyncCursorKey(ownerID: "account-z", source: .speziSamples, typeIdentifier: Self.type))
            await #expect(throws: HealthSyncCursorStoreError.partitionOwnerMismatch) {
                _ = try await cursors.establishSplit(for: foreign, cutoff: .distantPast, requiring: lease)
            }
            #expect(await !cursors.updateSplit(for: foreign, requiring: lease) { $0.fullCatchUp = true })
        }

        @Test("the replay floor follows the server's newest row per type, and only answers it gave")
        func replayFloorFromFreshness() async {
            let seen = SplitFixture.now.addingTimeInterval(-100 * 86400)
            let freshness = [MetricFreshness(type: "SLEEP_DURATION", lastSeenAt: seen)]
            #expect(HealthSampleReplayFloor.floor(for: Self.type, freshness: freshness)
                == seen.addingTimeInterval(-7 * 86400))
            #expect(HealthSampleReplayFloor.floor(for: HKQuantityTypeIdentifier.walkingSpeed.rawValue, freshness: freshness) == nil)
            #expect(HealthSampleReplayFloor.floor(for: "HKQuantityTypeIdentifierUnknown", freshness: freshness) == nil)

            #expect(await HealthSampleReplayFloor.freshnessAnswer { freshness } == freshness)
            #expect(await HealthSampleReplayFloor.freshnessAnswer { nil } == [])
            #expect(await HealthSampleReplayFloor.freshnessAnswer { throw HLError.offline } == nil)
            #expect(await HealthSampleReplayFloor.freshnessAnswer { throw HLError.server(status: 503, code: nil, message: "") } == nil)
            #expect(await HealthSampleReplayFloor.freshnessAnswer { throw HLError.server(status: 404, code: nil, message: "") } == [])
            #expect(await HealthSampleReplayFloor.freshnessAnswer { throw HLError.serverNotConfigured } == [])
        }

        @Test("every registry type has a server type for the shortcut")
        func everyRegistryTypeIsMapped() {
            let unmapped = HealthLogSampleTypeRegistry.knownIdentifiers.filter { HealthSampleReplayFloor.serverType[$0] == nil }
            #expect(unmapped.isEmpty)
        }
    }
#endif
