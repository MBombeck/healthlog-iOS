#if canImport(HealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Synchronization
    import Testing

    // Doubles for the live/history split suites.
    //
    // `SimulatedHealthStore` keeps the two properties of HealthKit the split
    // depends on: every row has an insertion position (what an anchor
    // resumes after) and a start date (what a history window selects), and
    // the two orders differ. Rows can be inserted while a test runs, the way
    // a watch or a ring writes into Health between two wakes.

    final class SimulatedHealthStore: AnchoredHealthSampleQuerying, HealthSampleHistoryQuerying, Sendable {
        struct Row: Sendable, Hashable {
            let anchor: Int
            let start: Date
        }

        private let rows: Mutex<[Row]>
        private let typeIdentifier: String
        private let anchoredWindows = Mutex<[HealthSampleDateWindow?]>([])
        private let historyWindows = Mutex<[HealthSampleDateWindow]>([])

        init(typeIdentifier: String, rows: [Row]) {
            self.typeIdentifier = typeIdentifier
            self.rows = Mutex(rows.sorted { $0.anchor < $1.anchor })
        }

        var allRows: [Row] {
            rows.withLock { $0 }
        }

        var anchoredQueries: [HealthSampleDateWindow?] {
            anchoredWindows.withLock { $0 }
        }

        var historyQueries: [HealthSampleDateWindow] {
            historyWindows.withLock { $0 }
        }

        /// Appends a row at the next insertion position.
        @discardableResult
        func insert(start: Date) -> Row {
            rows.withLock { current in
                let row = Row(anchor: (current.last?.anchor ?? 0) + 1, start: start)
                current.append(row)
                return row
            }
        }

        // MARK: Anchored

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
            anchoredWindows.withLock { $0.append(window) }
            let snapshot = typeIdentifier == self.typeIdentifier ? allRows : []
            let after = anchor.flatMap { Self.position($0, in: snapshot) } ?? 0
            let matching = snapshot.filter { $0.anchor > after && (window?.contains($0.start) ?? true) }
            let page = Array(matching.prefix(limit))
            let full = page.count >= limit
            // A short read has looked at everything: its anchor is the end of
            // the store, like HealthKit's.
            let newAnchor = full ? (page.last?.anchor ?? after) : max(after, allRows.last?.anchor ?? 0)
            return AnchoredHealthSamplePage(
                samples: page.map(Self.sample),
                deletedObjectCount: 0,
                newAnchor: HKQueryAnchor(fromValue: newAnchor),
                mayHaveMore: full
            )
        }

        // MARK: History

        func historyPage(
            typeIdentifier: String,
            within window: HealthSampleDateWindow,
            limit: Int?
        ) async throws -> [HKSample] {
            historyWindows.withLock { $0.append(window) }
            guard typeIdentifier == self.typeIdentifier else { return [] }
            let matching = allRows
                .filter { window.contains($0.start) }
                .sorted { ($0.start, $0.anchor) > ($1.start, $1.anchor) }
            let page = limit.map { Array(matching.prefix($0)) } ?? matching
            return page.map(Self.sample)
        }

        // MARK: Helpers

        static func position(_ anchor: HKQueryAnchor, in rows: [Row]) -> Int? {
            if anchor == HKQueryAnchor(fromValue: 0) { return 0 }
            let candidates = rows.map(\.anchor) + [(rows.last?.anchor ?? 0) + 1]
            return candidates.first { HKQueryAnchor(fromValue: $0) == anchor }
        }

        /// The anchor rides in the quantity, so a consumer can name the row.
        static func sample(_ row: Row) -> HKSample {
            HKQuantitySample(
                type: HKQuantityType(.stepCount),
                quantity: HKQuantity(unit: .count(), doubleValue: Double(row.anchor)),
                start: row.start,
                end: row.start.addingTimeInterval(60)
            )
        }

        static func anchor(of sample: HKSample) -> Int {
            Int((sample as? HKQuantitySample)?.quantity.doubleValue(for: .count()) ?? -1)
        }
    }

    /// Accepts pages (or refuses the ones a test names) and remembers every
    /// row it was handed, in order.
    final class RowRecordingConsumer: HealthSamplePageConsuming, Sendable {
        private let consumed = Mutex<[Int]>([])
        private let calls = Mutex<Int>(0)
        private let refuse: @Sendable (Int) -> Bool
        private let onPage: @Sendable (Int) -> Void

        init(
            refusing refuse: @escaping @Sendable (Int) -> Bool = { _ in false },
            onPage: @escaping @Sendable (Int) -> Void = { _ in }
        ) {
            self.refuse = refuse
            self.onPage = onPage
        }

        var rows: [Int] {
            consumed.withLock { $0 }
        }

        func consume(
            _ samples: [HKSample],
            ofType _: String,
            requiring _: HealthSyncAuthenticatedLease
        ) async -> HealthSyncPageOutcome {
            let call = calls.withLock { value -> Int in
                value += 1
                return value
            }
            onPage(call)
            if refuse(call) {
                return HealthSyncPageOutcome(
                    postedCount: samples.count,
                    entries: samples.indices.map {
                        HealthSyncEntryOutcome(index: $0, stableIdentity: "row-\($0)", classification: .nonterminal)
                    },
                    transportThrew: false,
                    durableRetryPersisted: false,
                    durableRetryFailed: false,
                    leaseIsCurrent: true,
                    wasCancelled: false
                )
            }
            consumed.withLock { $0.append(contentsOf: samples.map(SimulatedHealthStore.anchor)) }
            return ScriptedConsumer.accepted
        }
    }

    /// A settable monotonic clock.
    final class SteppingUptime: Sendable {
        private let value = Mutex<TimeInterval>(1000)

        var now: TimeInterval {
            value.withLock { $0 }
        }

        func advance(_ seconds: TimeInterval) {
            value.withLock { $0 += seconds }
        }
    }

    enum SplitFixture {
        static let sleepType = HKCategoryTypeIdentifier.sleepAnalysis.rawValue
        /// A fixed "now" for every split suite.
        static let now = Date(timeIntervalSince1970: 1_790_000_000)

        static func clock(_ uptime: SteppingUptime = SteppingUptime()) -> HealthSampleSplitClock {
            HealthSampleSplitClock(now: { now }, uptime: { uptime.now })
        }

        /// `historyDays` days of history before the live window, `perDay`
        /// rows a day, inserted oldest first, then `recent` rows of the last
        /// hours inserted last.
        static func rows(historyDays: Int, perDay: Int = 1, recent: Int = 5) -> [SimulatedHealthStore.Row] {
            var rows: [SimulatedHealthStore.Row] = []
            var anchor = 0
            let liveStart = now.addingTimeInterval(-HealthSampleSplitPolicy.liveLookback)
            for day in stride(from: historyDays, through: 1, by: -1) {
                for slot in 0 ..< perDay {
                    anchor += 1
                    let start = liveStart.addingTimeInterval(-Double(day) * 86400 + Double(slot) * 3600)
                    rows.append(.init(anchor: anchor, start: start))
                }
            }
            for index in 0 ..< recent {
                anchor += 1
                rows.append(.init(anchor: anchor, start: now.addingTimeInterval(-Double(index + 1) * 3600)))
            }
            return rows
        }

        static func cursors(_ backing: CollectorCursorBacking) -> DurableHealthCursorStore {
            DurableHealthCursorStore(storage: backing.storage, clock: { now })
        }

        /// A replaying partition, the state every 1.2.0 partition is in.
        static func replayingKey(
            _ cursors: DurableHealthCursorStore,
            type: String,
            lease: HealthSyncAuthenticatedLease
        ) async throws -> HealthSyncCursorKey {
            let key = try #require(lease.cursorKey(typeIdentifier: type))
            _ = try await cursors.migrate(
                key,
                legacyKey: SpeziAnchorMigratorKey.legacyKey(type),
                ownership: .unownedGlobal,
                requiring: lease
            )
            return key
        }

        static func collector(
            _ cursors: DurableHealthCursorStore,
            store: SimulatedHealthStore,
            consumer: RowRecordingConsumer,
            pageLimit: Int = 100,
            uptime: SteppingUptime = SteppingUptime()
        ) -> AnchoredHealthSampleCollector {
            AnchoredHealthSampleCollector(
                cursors: cursors,
                query: store,
                consumer: consumer,
                history: store,
                pageLimit: pageLimit,
                clock: clock(uptime)
            )
        }

        static func scratchDefaults() -> UserDefaults {
            let suite = "hl.test.split.\(UUID().uuidString)"
            return UserDefaults(suiteName: suite) ?? .standard
        }
    }

    /// The Spezi slot name a replaying partition quarantines; only a label here.
    enum SpeziAnchorMigratorKey {
        static func legacyKey(_ type: String) -> String {
            "edu.stanford.Spezi.SpeziHealthKit.queryAnchors.\(type)"
        }
    }
#endif
