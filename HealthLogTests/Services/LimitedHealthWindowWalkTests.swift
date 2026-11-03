#if canImport(HealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Synchronization
    import Testing

    /// **B5 (1.4, R4 2.1 third point, follow-up to A3) — the history walk,
    /// the statistics backfill and Sync Diagnostics with iOS 27 limited
    /// history.**
    ///
    /// Apple: "Treat all data before that date as unknown, not an absence of
    /// data." Up to A3 the walk read the hidden range, found it empty, and
    /// recorded the whole window as read; widened access later never brought
    /// the older readings. The walk now stops at the readable boundary, counts
    /// as done there, and resumes below it once access widens. An unknown
    /// window walks nothing. The day and hour totals skip the bucket the
    /// boundary cuts, which would otherwise overwrite a full server total with
    /// a part.
    @Suite("B5 — limited Health window: walk, totals, diagnostics")
    struct LimitedHealthWindowWalkTests {
        private static let type = CollectorFixture.stepType
        private static let day: TimeInterval = 86400
        private static let liveStart = SplitFixture.now.addingTimeInterval(-HealthSampleSplitPolicy.liveLookback)
        /// Ten and a half days before the live start: days 1 to 10 readable.
        private static let boundary = liveStart.addingTimeInterval(-10.5 * day)

        /// `SimulatedHealthStore` behind HealthKit's limited-history rule:
        /// a sample that ends before the boundary is not returned.
        final class LimitedWindowStore: AnchoredHealthSampleQuerying, HealthSampleHistoryQuerying, Sendable {
            let base: SimulatedHealthStore
            private let window: Mutex<HealthReadWindow>

            init(base: SimulatedHealthStore, window: HealthReadWindow) {
                self.base = base
                self.window = Mutex(window)
            }

            func set(_ newWindow: HealthReadWindow) {
                window.withLock { $0 = newWindow }
            }

            private func visible(_ samples: [HKSample]) -> [HKSample] {
                let current = window.withLock { $0 }
                guard case .limited = current else { return samples }
                return samples.filter { !current.hidesAbsence(endingAt: $0.endDate) }
            }

            func page(
                typeIdentifier: String,
                resumingFrom anchor: HKQueryAnchor?,
                notBefore cutoff: Date,
                limit: Int
            ) async throws -> AnchoredHealthSamplePage {
                try await page(
                    typeIdentifier: typeIdentifier,
                    resumingFrom: anchor,
                    within: anchor == nil ? HealthSampleDateWindow(start: cutoff) : nil,
                    limit: limit
                )
            }

            func page(
                typeIdentifier: String,
                resumingFrom anchor: HKQueryAnchor?,
                within window: HealthSampleDateWindow?,
                limit: Int
            ) async throws -> AnchoredHealthSamplePage {
                let page = try await base.page(typeIdentifier: typeIdentifier, resumingFrom: anchor, within: window, limit: limit)
                return AnchoredHealthSamplePage(
                    samples: visible(page.samples),
                    deletedObjectCount: page.deletedObjectCount,
                    newAnchor: page.newAnchor,
                    mayHaveMore: page.mayHaveMore
                )
            }

            func historyPage(
                typeIdentifier: String,
                within window: HealthSampleDateWindow,
                limit: Int?
            ) async throws -> [HKSample] {
                try await visible(base.historyPage(typeIdentifier: typeIdentifier, within: window, limit: limit))
            }

            func readWindows(typeIdentifiers: [String]) async -> [String: HealthReadWindow] {
                let current = window.withLock { $0 }
                return Dictionary(uniqueKeysWithValues: typeIdentifiers.map { ($0, current) })
            }
        }

        private struct Setup {
            let registry: AuthenticatedSessionLeaseRegistry
            let lease: HealthSyncAuthenticatedLease
            let cursors: DurableHealthCursorStore
            let key: HealthSyncCursorKey
            let store: LimitedWindowStore
            let consumer: RowRecordingConsumer
            let collector: AnchoredHealthSampleCollector
            let rows: [SimulatedHealthStore.Row]
        }

        private static func setUp(_ window: HealthReadWindow) async throws -> Setup {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let cursors = SplitFixture.cursors(CollectorCursorBacking())
            let key = try await SplitFixture.replayingKey(cursors, type: type, lease: lease)
            let rows = SplitFixture.rows(historyDays: 30, recent: 3)
            let store = LimitedWindowStore(base: SimulatedHealthStore(typeIdentifier: type, rows: rows), window: window)
            let consumer = RowRecordingConsumer()
            let collector = AnchoredHealthSampleCollector(
                cursors: cursors,
                query: store,
                consumer: consumer,
                history: store,
                pageLimit: 4,
                clock: SplitFixture.clock()
            )
            return Setup(
                registry: registry, lease: lease, cursors: cursors, key: key,
                store: store, consumer: consumer, collector: collector, rows: rows
            )
        }

        /// Passes with "Alle" chosen until the history leg reports it finished.
        private static func walkToTheEnd(_ setup: Setup) async -> Bool {
            for _ in 0 ..< 30 {
                let result = await setup.collector.collect(
                    typeIdentifiers: [type],
                    trigger: .processing,
                    notBefore: .distantPast,
                    requiring: setup.lease
                ).first
                if result?.history?.isFinished == true { return true }
            }
            return false
        }

        private static func anchors(before date: Date, in rows: [SimulatedHealthStore.Row]) -> Set<Int> {
            Set(rows.filter { $0.start.addingTimeInterval(60) < date }.map(\.anchor))
        }

        // MARK: - The walk

        @Test("a limited window: the walk ends at the boundary, counts as done, and resumes when access widens")
        func walkStopsAtTheBoundaryAndResumes() async throws {
            let setup = try await Self.setUp(.limited(from: Self.boundary))
            #expect(await Self.walkToTheEnd(setup))

            let hidden = Self.anchors(before: Self.boundary, in: setup.rows)
            #expect(!hidden.isEmpty)
            #expect(Set(setup.consumer.rows).isDisjoint(with: hidden))
            let split = try #require(await setup.cursors.splitState(for: setup.key))
            #expect(split.historyEnd == Self.boundary, "the hidden range is not recorded as read")

            // The person grants the full history: the walk goes on from there.
            setup.store.set(.unlimited)
            #expect(await Self.walkToTheEnd(setup))
            #expect(hidden.isSubset(of: Set(setup.consumer.rows)))
        }

        @Test("an unknown window walks nothing and records nothing")
        func unknownWindowDefers() async throws {
            let setup = try await Self.setUp(.unknown)
            let result = await setup.collector.collect(
                typeIdentifiers: [Self.type],
                trigger: .processing,
                notBefore: .distantPast,
                requiring: setup.lease
            ).first
            #expect(result?.history?.isFinished != true)
            let split = try #require(await setup.cursors.splitState(for: setup.key))
            #expect(split.historyEnd == split.liveStart)
            #expect(Set(setup.consumer.rows).isDisjoint(with: Self.anchors(before: Self.liveStart, in: setup.rows)))
        }

        // MARK: - Diagnostics

        @Test("Sync Diagnostics reads the walk as done at the boundary and names the window")
        func diagnosticsReadTheBoundary() async throws {
            let setup = try await Self.setUp(.limited(from: Self.boundary))
            #expect(await Self.walkToTheEnd(setup))
            let readable: [String: HealthReadWindow] = [Self.type: .limited(from: Self.boundary)]
            let statuses = await setup.cursors.historyStatus(for: [setup.key], cutoff: .distantPast, readable: readable)
            let overview = HealthHistoryOverview(types: statuses, readable: readable)
            #expect(overview.isFinished)
            #expect(overview.limitedFrom == Self.boundary)

            let full = HealthHistoryOverview(types: statuses, readable: [Self.type: .unlimited])
            #expect(full.limitedFrom == nil)
            #expect(HealthHistoryOverview(types: statuses, readable: [:]).limitedFrom == nil)
        }

        @Test("completion against the readable floor, on the state itself")
        func stateCompletion() {
            let state = HealthSampleSplitState(
                version: HealthSampleSplitState.formatVersion,
                origin: .fresh,
                liveStart: Self.liveStart,
                liveCaughtUp: true,
                historyEnd: Self.boundary,
                historyEndInclusive: false,
                replayFloor: nil,
                replayFloorResolved: true,
                legacyLegActive: false,
                fullCatchUp: false,
                updatedAt: Self.liveStart
            )
            #expect(!state.isHistoryComplete(cutoff: .distantPast))
            #expect(state.isHistoryComplete(cutoff: .distantPast, readable: .limited(from: Self.boundary)))
            #expect(!state.isHistoryComplete(cutoff: .distantPast, readable: .limited(from: Self.boundary.addingTimeInterval(-60))))
            #expect(state.readableHistoryFloor(cutoff: .distantPast, readable: .limited(from: Self.boundary)) == Self.boundary)
            // A window below the chosen one changes nothing.
            let cutoff = Self.boundary.addingTimeInterval(Self.day)
            #expect(state.readableHistoryFloor(cutoff: cutoff, readable: .limited(from: Self.boundary)) == cutoff)
            // Never above the live start.
            let later = Self.liveStart.addingTimeInterval(Self.day)
            #expect(state.readableHistoryFloor(cutoff: .distantPast, readable: .limited(from: later)) == Self.liveStart)
        }

        // MARK: - Day and hour totals

        @Test("totals start at the first whole day or hour inside the window")
        func totalsSkipTheCutBucket() throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
            let anchor = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))
            let cut = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 13, minute: 30)))
            let midnight = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 10)))
            let nextDay = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 11)))
            let nextHour = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 14)))

            #expect(HealthReadWindow.limited(from: cut).wholeBucketStart(anchor, bucket: .day, calendar: calendar) == nextDay)
            #expect(HealthReadWindow.limited(from: cut).wholeBucketStart(anchor, bucket: .hour, calendar: calendar) == nextHour)
            #expect(HealthReadWindow.limited(from: midnight).wholeBucketStart(anchor, bucket: .day, calendar: calendar) == midnight)
            // A read that already starts inside the window, full access and an
            // unknown window all keep their start.
            #expect(HealthReadWindow.limited(from: cut).wholeBucketStart(nextDay, bucket: .day, calendar: calendar) == nextDay)
            #expect(HealthReadWindow.unlimited.wholeBucketStart(anchor, bucket: .day, calendar: calendar) == anchor)
            #expect(HealthReadWindow.unknown.wholeBucketStart(anchor, bucket: .day, calendar: calendar) == anchor)
        }
    }
#endif
