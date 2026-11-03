#if canImport(HealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Synchronization
    import Testing

    // A2 (1.4) — doubles for the history suites: a server that answers like
    // v1.42+ (folded windows come back as `folded_window` duplicates), a
    // server that cannot be reached, and a store with more than one type.

    /// Which consumption a page went through.
    enum HistoryPageRoute: Equatable, Sendable {
        case live
        case history
    }

    /// Answers every page the way the batch route does: every row stored,
    /// the rows whose window the server has folded as `folded_window`
    /// duplicates. Offline while ``offline`` is set: every page that has
    /// something to post comes back unreachable, nothing stored.
    final class FoldingServerConsumer: HealthSamplePageConsuming, Sendable {
        /// How many rows of a page the server reports folded. `call` counts
        /// every page this consumer was handed, live and history, from 1.
        typealias Folding = @Sendable (_ call: Int, _ samples: [HKSample]) -> Int

        private let folding: Folding
        private let calls = Mutex<Int>(0)
        private let consumed = Mutex<[Int]>([])
        private let routes = Mutex<[HistoryPageRoute]>([])
        private let unreachable = Mutex<Bool>(false)

        init(folding: @escaping Folding) {
            self.folding = folding
        }

        /// Rows that start before `cutoff` are folded on the server.
        convenience init(foldedBefore cutoff: Date) {
            self.init { _, samples in samples.count(where: { $0.startDate < cutoff }) }
        }

        var rows: [Int] {
            consumed.withLock { $0 }
        }

        var pageRoutes: [HistoryPageRoute] {
            routes.withLock { $0 }
        }

        var offline: Bool {
            get { unreachable.withLock { $0 } }
            set { unreachable.withLock { $0 = newValue } }
        }

        func consume(
            _ samples: [HKSample],
            ofType _: String,
            requiring _: HealthSyncAuthenticatedLease
        ) async -> HealthSyncPageOutcome {
            answer(samples, route: .live)
        }

        func consumeHistory(
            _ samples: [HKSample],
            ofType _: String,
            requiring _: HealthSyncAuthenticatedLease
        ) async -> HealthSyncPageOutcome {
            answer(samples, route: .history)
        }

        private func answer(_ samples: [HKSample], route: HistoryPageRoute) -> HealthSyncPageOutcome {
            let call = calls.withLock { value -> Int in
                value += 1
                return value
            }
            routes.withLock { $0.append(route) }
            if offline, !samples.isEmpty {
                return Self.unreachableOutcome(postedCount: samples.count)
            }
            consumed.withLock { $0.append(contentsOf: samples.map(SimulatedHealthStore.anchor)) }
            var outcome = HealthSyncPageOutcome(
                postedCount: samples.count,
                entries: samples.indices.map {
                    HealthSyncEntryOutcome(index: $0, stableIdentity: "row-\($0)", classification: .terminalAccepted)
                },
                transportThrew: false,
                durableRetryPersisted: false,
                durableRetryFailed: false,
                leaseIsCurrent: true,
                wasCancelled: false
            )
            outcome.foldedWindowDuplicates = samples.isEmpty ? 0 : folding(call, samples)
            return outcome
        }

        /// What `HealthSampleConsumption` reports for a page that never
        /// reached the server.
        static func unreachableOutcome(postedCount: Int) -> HealthSyncPageOutcome {
            var outcome = HealthSyncPageOutcome(
                postedCount: postedCount,
                entries: [],
                transportThrew: true,
                durableRetryPersisted: false,
                durableRetryFailed: false,
                leaseIsCurrent: true,
                wasCancelled: false
            )
            outcome.serverUnreachable = true
            return outcome
        }
    }

    /// Several simulated types behind one query and one history seam.
    final class SimulatedHealthStores: AnchoredHealthSampleQuerying, HealthSampleHistoryQuerying, Sendable {
        let stores: [String: SimulatedHealthStore]

        init(_ stores: [String: SimulatedHealthStore]) {
            self.stores = stores
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
            guard let store = stores[typeIdentifier] else {
                return AnchoredHealthSamplePage(
                    samples: [],
                    deletedObjectCount: 0,
                    newAnchor: HKQueryAnchor(fromValue: 0),
                    mayHaveMore: false
                )
            }
            return try await store.page(typeIdentifier: typeIdentifier, resumingFrom: anchor, within: window, limit: limit)
        }

        func historyPage(
            typeIdentifier: String,
            within window: HealthSampleDateWindow,
            limit: Int?
        ) async throws -> [HKSample] {
            guard let store = stores[typeIdentifier] else { return [] }
            return try await store.historyPage(typeIdentifier: typeIdentifier, within: window, limit: limit)
        }
    }

    enum HistoryWalkA2Fixture {
        static let heartRate = HKQuantityTypeIdentifier.heartRate.rawValue
        static let steps = HKQuantityTypeIdentifier.stepCount.rawValue

        /// The start of the `day`-th history row of ``SplitFixture/rows``.
        static func historyDay(_ day: Int) -> Date {
            SplitFixture.now
                .addingTimeInterval(-HealthSampleSplitPolicy.liveLookback)
                .addingTimeInterval(-Double(day) * 86400)
        }

        static func collector(
            _ cursors: DurableHealthCursorStore,
            query: any AnchoredHealthSampleQuerying & HealthSampleHistoryQuerying,
            consumer: any HealthSamplePageConsuming,
            pageLimit: Int = 100,
            historyOwnedElsewhere: @escaping @Sendable (String) -> Bool = { _ in false }
        ) -> AnchoredHealthSampleCollector {
            AnchoredHealthSampleCollector(
                cursors: cursors,
                query: query,
                consumer: consumer,
                history: query,
                pageLimit: pageLimit,
                clock: SplitFixture.clock(),
                historyOwnedElsewhere: historyOwnedElsewhere
            )
        }
    }
#endif
