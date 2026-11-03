#if canImport(HealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// A2 (1.4) — the update path from 1.3.0, on the exact bytes a 1.3.0 phone
    /// keeps for a partition halfway through its history walk.
    ///
    /// The operator's phone is the case: "Sync everything now" pressed once
    /// (`fullCatchUp` stays set), the walk somewhere in years of heart rate the
    /// server folded long ago. 1.4 must carry on from that point (no reset to
    /// the live start, nothing newer sent again, nothing older skipped that the
    /// server lacks) and stop where the server answers with folded windows.
    @Suite("History walk: update from 1.3.0 mid-walk (A2)")
    struct HistoryUpdatePathA2Tests {
        private struct Install {
            /// Held so the admitted session stays current for the whole test.
            let registry: AuthenticatedSessionLeaseRegistry
            let lease: HealthSyncAuthenticatedLease
            let cursors: DurableHealthCursorStore
            let key: HealthSyncCursorKey
            let store: SimulatedHealthStore
        }

        /// The storage of a 1.3.0 phone: the live cursor at the end of the
        /// store, and the split record exactly as 1.3.0 encodes it, the walk
        /// having reached `reachedDay` (inclusive).
        private static func install(type: String, reachedDay: Int) async throws -> Install {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let backing = CollectorCursorBacking()
            let cursors = SplitFixture.cursors(backing)
            let key = try await SplitFixture.replayingKey(cursors, type: type, lease: lease)
            let rows = SplitFixture.rows(historyDays: 1200)
            try await cursors.save(HKQueryAnchor(fromValue: rows.count), for: key, requiring: lease)
            let liveStart = SplitFixture.now.addingTimeInterval(-HealthSampleSplitPolicy.liveLookback)
            let reached = HistoryWalkA2Fixture.historyDay(reachedDay)
            // JSONEncoder's default date form: seconds since 2001-01-01.
            let json = """
            {"version":1,"origin":"fresh","liveStart":\(liveStart.timeIntervalSinceReferenceDate),\
            "liveCaughtUp":true,"historyEnd":\(reached.timeIntervalSinceReferenceDate),"historyEndInclusive":true,\
            "replayFloorResolved":true,"legacyLegActive":false,"fullCatchUp":true,\
            "updatedAt":\(SplitFixture.now.timeIntervalSinceReferenceDate)}
            """
            backing.storage.write(key.storageKey + DurableHealthCursorStore.splitSuffix, Data(json.utf8))
            let state = try #require(await cursors.splitState(for: key), "1.4 reads the 1.3.0 record")
            #expect(state.historyEnd == reached)
            #expect(state.fullCatchUp)
            return Install(
                registry: registry,
                lease: lease,
                cursors: cursors,
                key: key,
                store: SimulatedHealthStore(typeIdentifier: type, rows: rows)
            )
        }

        @Test("update path: a heart-rate walk halfway through carries on from its date and ends at the folded windows")
        func midWalkCarriesOnAndStops() async throws {
            let type = HistoryWalkA2Fixture.heartRate
            let install = try await Self.install(type: type, reachedDay: 400)
            let reached = HistoryWalkA2Fixture.historyDay(400)
            let consumer = FoldingServerConsumer(foldedBefore: HistoryWalkA2Fixture.historyDay(150))
            let collector = HistoryWalkA2Fixture.collector(install.cursors, query: install.store, consumer: consumer)

            let result = await collector.collect(
                typeIdentifiers: [type],
                trigger: .processing,
                notBefore: .distantPast,
                requiring: install.lease
            ).first

            let first = try #require(install.store.historyQueries.first)
            #expect(first.end == reached && first.endInclusive, "the walk resumes at its own date, not at the live start")
            let starts = consumer.rows.compactMap { anchor in install.store.allRows.first { $0.anchor == anchor }?.start }
            #expect(!starts.isEmpty)
            #expect(starts.allSatisfy { $0 <= reached }, "nothing newer than the walk's date goes out again")
            #expect(install.store.historyQueries.count == HealthSampleSplitPolicy.foldedPagesBeforeStop)
            #expect(result?.history?.isFinished == true)
            let state = try #require(await install.cursors.splitState(for: install.key))
            #expect(state.isHistoryComplete(cutoff: .distantPast))
        }

        @Test("update path: a steps walk halfway through is retired without another raw read")
        func midWalkSummedTypeRetires() async throws {
            let type = HistoryWalkA2Fixture.steps
            let install = try await Self.install(type: type, reachedDay: 400)
            let consumer = FoldingServerConsumer { _, _ in 0 }
            let collector = HistoryWalkA2Fixture.collector(
                install.cursors,
                query: install.store,
                consumer: consumer,
                historyOwnedElsewhere: { $0 == type }
            )

            let result = await collector.collect(
                typeIdentifiers: [type],
                trigger: .processing,
                notBefore: .distantPast,
                requiring: install.lease
            ).first

            #expect(install.store.historyQueries.isEmpty)
            #expect(result?.history?.isFinished == true)
            #expect(try #require(await install.cursors.splitState(for: install.key)).isHistoryComplete(cutoff: .distantPast))
        }
    }
#endif
