#if canImport(HealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Synchronization
    import Testing

    // Phase 07 Wave 2 — doubles for the app-owned collector's suite.
    //
    // They live beside the suite rather than inside it so the suite itself stays a
    // readable list of properties. Each one exists to make a fault observable that
    // real HealthKit cannot be asked to produce on demand: an exact page sequence,
    // an exact server verdict, and a change signal fired by hand.

    /// Scripted page source that records the anchor each query resumed from, so
    /// "read the committed anchor before querying" is observable rather than
    /// assumed.
    final class ScriptedPageSource: AnchoredHealthSampleQuerying, Sendable {
        private let pages: Mutex<[AnchoredHealthSamplePage]>
        private let resumed = Mutex<[HKQueryAnchor?]>([])
        private let cutoffs = Mutex<[Date]>([])
        private let failNext = Mutex<Bool>(false)

        init(pages: [AnchoredHealthSamplePage]) {
            self.pages = Mutex(pages)
        }

        var resumedAnchors: [HKQueryAnchor?] {
            resumed.withLock { $0 }
        }

        var observedCutoffs: [Date] {
            cutoffs.withLock { $0 }
        }

        var queryCount: Int {
            resumed.withLock { $0.count }
        }

        func failNextQuery() {
            failNext.withLock { $0 = true }
        }

        func page(
            typeIdentifier _: String,
            resumingFrom anchor: HKQueryAnchor?,
            notBefore cutoff: Date,
            limit _: Int
        ) async throws -> AnchoredHealthSamplePage {
            resumed.withLock { $0.append(anchor) }
            cutoffs.withLock { $0.append(cutoff) }
            let shouldFail = failNext.withLock { value -> Bool in
                defer { value = false }
                return value
            }
            if shouldFail {
                throw AnchoredHealthCollectionError.unknownSampleType
            }
            let next = pages.withLock { queue -> AnchoredHealthSamplePage? in
                queue.isEmpty ? nil : queue.removeFirst()
            }
            return next ?? AnchoredHealthSamplePage(
                samples: [],
                deletedObjectCount: 0,
                newAnchor: HKQueryAnchor(fromValue: 0),
                mayHaveMore: false
            )
        }
    }

    /// Scripted consumption. Returns the outcome the fault matrix needs and
    /// records how many pages it was handed.
    final class ScriptedConsumer: HealthSamplePageConsuming, Sendable {
        private let outcomes: Mutex<[HealthSyncPageOutcome]>
        private let consumed = Mutex<Int>(0)

        init(outcomes: [HealthSyncPageOutcome]) {
            self.outcomes = Mutex(outcomes)
        }

        var consumedPages: Int {
            consumed.withLock { $0 }
        }

        func consume(
            _: [HKSample],
            ofType _: String,
            requiring _: HealthSyncAuthenticatedLease
        ) async -> HealthSyncPageOutcome {
            consumed.withLock { $0 += 1 }
            let next = outcomes.withLock { queue -> HealthSyncPageOutcome? in
                queue.isEmpty ? nil : queue.removeFirst()
            }
            return next ?? Self.accepted
        }

        static var accepted: HealthSyncPageOutcome {
            HealthSyncPageOutcome(
                postedCount: 0,
                entries: [],
                transportThrew: false,
                durableRetryPersisted: false,
                durableRetryFailed: false,
                leaseIsCurrent: true,
                wasCancelled: false
            )
        }
    }

    /// Records the change subscription and lets a test fire the signal by hand.
    final class RecordingObserver: HealthSampleChangeObserving, Sendable {
        private let handler = Mutex<(@Sendable (String) -> Void)?>(nil)
        private let started = Mutex<[String]>([])
        private let stopped = Mutex<Bool>(false)

        var observedTypes: [String] {
            started.withLock { $0 }
        }

        var didStop: Bool {
            stopped.withLock { $0 }
        }

        func startObserving(
            _ typeIdentifiers: [String],
            onChange: @escaping @Sendable (String) -> Void
        ) async {
            started.withLock { $0 = typeIdentifiers }
            handler.withLock { $0 = onChange }
        }

        func stopObserving() async {
            stopped.withLock { $0 = true }
            handler.withLock { $0 = nil }
        }

        func signal(_ typeIdentifier: String) {
            handler.withLock { $0 }?(typeIdentifier)
        }
    }

    final class CollectorCursorBacking: Sendable {
        private let entries = Mutex<[String: Data]>([:])

        var storage: HealthSyncCursorStorage {
            HealthSyncCursorStorage(
                read: { [self] key in entries.withLock { $0[key] } },
                write: { [self] key, value in entries.withLock { $0[key] = value } }
            )
        }
    }

    /// Shared fixtures for the two collector suites.
    enum CollectorFixture {
        static let stepType = HKQuantityTypeIdentifier.stepCount.rawValue

        static func makeLease(
            owner: String = "account-a",
            registry: AuthenticatedSessionLeaseRegistry,
            bearer: @escaping @Sendable () -> String? = { "token-account-a" }
        ) throws -> HealthSyncAuthenticatedLease {
            _ = registry.activate(ownerID: owner)
            return try HealthSyncAuthenticatedLease.admit(
                from: registry,
                ownerID: owner,
                source: .speziSamples,
                bearerProvider: bearer
            )
        }

        /// Establishes the production migration state: the installation-global
        /// Spezi anchor is quarantined and the partition replays from the chosen
        /// cutoff, which is the only state in which collection is permitted at all.
        static func makeReplayingStore(
            backing: CollectorCursorBacking,
            lease: HealthSyncAuthenticatedLease
        ) async throws -> (DurableHealthCursorStore, HealthSyncCursorKey) {
            let store = DurableHealthCursorStore(storage: backing.storage)
            let key = try #require(
                HealthSyncCursorKey(
                    ownerID: lease.ownerID,
                    source: .speziSamples,
                    typeIdentifier: stepType
                )
            )
            let state = try await store.migrate(
                key,
                legacyKey: "edu.stanford.Spezi.SpeziHealthKit.queryAnchors.\(stepType)",
                ownership: .unownedGlobal,
                requiring: lease
            )
            #expect(state == .replayingLegacy(
                quarantineReference: "edu.stanford.Spezi.SpeziHealthKit.queryAnchors.\(stepType)"
            ))
            return (store, key)
        }

        static func page(_ anchorValue: Int, mayHaveMore: Bool = false) -> AnchoredHealthSamplePage {
            AnchoredHealthSamplePage(
                samples: [],
                deletedObjectCount: 0,
                newAnchor: HKQueryAnchor(fromValue: anchorValue),
                mayHaveMore: mayHaveMore
            )
        }

        static func nonterminalOutcome() -> HealthSyncPageOutcome {
            HealthSyncPageOutcome(
                postedCount: 1,
                entries: [
                    HealthSyncEntryOutcome(index: 0, stableIdentity: "sample-0", classification: .nonterminal)
                ],
                transportThrew: false,
                durableRetryPersisted: false,
                durableRetryFailed: false,
                leaseIsCurrent: true,
                wasCancelled: false
            )
        }
    }
#endif
