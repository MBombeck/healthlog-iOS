#if canImport(HealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Synchronization
    import Testing

    /// Phase 07 Wave 2 — the collector's bounds and its observer discipline.
    ///
    /// Split from `AnchoredHealthSampleCollectorTests` so neither suite grows past
    /// the project's type-body budget. This half asserts what the collector refuses
    /// to do: walk past its trigger's page budget, start a first history import in a
    /// short wake, collect on an unproven migration, do anything at all during an
    /// account teardown, or run one pass per callback in an observer burst.
    @Suite("Anchored health sample collector — bounds and observers")
    struct AnchoredHealthSampleCollectorBoundsTests {
        // MARK: - Bounds

        @Test("a trigger's page budget bounds the walk")
        func pageBudgetBoundsTheWalk() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let backing = CollectorCursorBacking()
            let (store, _) = try await CollectorFixture.makeReplayingStore(backing: backing, lease: lease)

            let source = ScriptedPageSource(pages: (1 ... 20).map { CollectorFixture.page($0, mayHaveMore: true) })
            let collector = AnchoredHealthSampleCollector(
                cursors: store,
                query: source,
                consumer: ScriptedConsumer(outcomes: [])
            )

            let results = await collector.collect(
                typeIdentifiers: [CollectorFixture.stepType],
                trigger: .processing,
                notBefore: .distantPast,
                requiring: lease
            )

            let budget = HealthSyncBudget.required(for: .processing)
            #expect(source.queryCount == budget.maxPagesPerType)
            #expect(results.first?.pagesCollected == budget.maxPagesPerType)
        }

        @Test("a short wake refuses to start the first history walk")
        func shortWakeRefusesFirstHistoryImport() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let backing = CollectorCursorBacking()
            let (store, _) = try await CollectorFixture.makeReplayingStore(backing: backing, lease: lease)

            let source = ScriptedPageSource(pages: [CollectorFixture.page(61)])
            let collector = AnchoredHealthSampleCollector(
                cursors: store,
                query: source,
                consumer: ScriptedConsumer(outcomes: [])
            )

            let results = await collector.collect(
                typeIdentifiers: [CollectorFixture.stepType],
                trigger: .appRefresh,
                notBefore: .distantPast,
                requiring: lease
            )

            #expect(source.queryCount == 0)
            #expect(results.first?.disposition == .deferred)
        }

        @Test("a partition whose migration is not proven collects nothing")
        func unprovenPartitionCollectsNothing() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let backing = CollectorCursorBacking()
            // Deliberately no migration: the partition is `notStarted`.
            let store = DurableHealthCursorStore(storage: backing.storage)

            let source = ScriptedPageSource(pages: [CollectorFixture.page(71)])
            let collector = AnchoredHealthSampleCollector(
                cursors: store,
                query: source,
                consumer: ScriptedConsumer(outcomes: [])
            )

            let results = await collector.collect(
                typeIdentifiers: [CollectorFixture.stepType],
                trigger: .manual,
                notBefore: .distantPast,
                requiring: lease
            )

            #expect(source.queryCount == 0)
            #expect(results.first?.disposition == .deferred)
        }

        @Test("account teardown collects nothing at all")
        func teardownCollectsNothing() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let backing = CollectorCursorBacking()
            let (store, _) = try await CollectorFixture.makeReplayingStore(backing: backing, lease: lease)

            let source = ScriptedPageSource(pages: [CollectorFixture.page(81)])
            let collector = AnchoredHealthSampleCollector(
                cursors: store,
                query: source,
                consumer: ScriptedConsumer(outcomes: [])
            )

            let results = await collector.collect(
                typeIdentifiers: [CollectorFixture.stepType],
                trigger: .accountTeardown,
                notBefore: .distantPast,
                requiring: lease
            )

            #expect(results.isEmpty)
            #expect(source.queryCount == 0)
        }

        // MARK: - Observers

        @Test("an observer burst produces one coalesced pass")
        func observerBurstIsCoalesced() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let backing = CollectorCursorBacking()
            let (store, key) = try await CollectorFixture.makeReplayingStore(backing: backing, lease: lease)

            // An observer wake is incremental by budget: it may not start the
            // first history walk, so the partition needs a committed cursor
            // before a signal can do any work at all.
            let seeded = try #require(
                HealthKitAnchorArchive.encodeAnchor(HKQueryAnchor(fromValue: 1), label: "test")
            )
            try await store.save(anchor: seeded, for: key, requiring: lease)

            let source = ScriptedPageSource(pages: [])
            let consumer = ScriptedConsumer(outcomes: [])
            let observer = RecordingObserver()
            let collector = AnchoredHealthSampleCollector(
                cursors: store,
                query: source,
                consumer: consumer,
                observer: observer
            )

            await collector.startObserving(
                [CollectorFixture.stepType],
                notBefore: .distantPast,
                admitting: {
                    try HealthSyncAuthenticatedLease.admit(
                        from: registry,
                        ownerID: "account-a",
                        source: .speziSamples,
                        bearerProvider: { "token-account-a" }
                    )
                }
            )
            #expect(observer.observedTypes == [CollectorFixture.stepType])

            for _ in 0 ..< 8 {
                await collector.handleObservedChange(typeIdentifier: CollectorFixture.stepType)
            }
            // Let the owned drain finish.
            try await Task.sleep(for: .milliseconds(120))

            // Eight signals, one bounded observer pass (the observer budget is a
            // single page per type).
            #expect(source.queryCount <= 2)
            #expect(source.queryCount >= 1)

            await collector.stopObserving()
            #expect(observer.didStop)
        }

        @Test("stopping cancels the owned drain and disarms the subscription")
        func stoppingCancelsOwnedWork() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let backing = CollectorCursorBacking()
            let (store, _) = try await CollectorFixture.makeReplayingStore(backing: backing, lease: lease)

            let observer = RecordingObserver()
            let collector = AnchoredHealthSampleCollector(
                cursors: store,
                query: ScriptedPageSource(pages: []),
                consumer: ScriptedConsumer(outcomes: []),
                observer: observer
            )

            await collector.startObserving(
                [CollectorFixture.stepType],
                notBefore: .distantPast,
                admitting: {
                    try HealthSyncAuthenticatedLease.admit(
                        from: registry,
                        ownerID: "account-a",
                        source: .speziSamples,
                        bearerProvider: { "token-account-a" }
                    )
                }
            )
            await collector.stopObserving()

            #expect(observer.didStop)
            // A signal after the stop cannot restart collection through a
            // subscription that no longer exists.
            observer.signal(CollectorFixture.stepType)
            try await Task.sleep(for: .milliseconds(60))
        }

        // MARK: - Type resolution

        @Test("the resolver names every registry identifier and refuses the rest")
        func resolverNamesTheRegistry() {
            for identifier in HealthLogSampleTypeRegistry.knownIdentifiers {
                #expect(
                    HealthKitSampleTypeResolver.sampleType(for: identifier) != nil,
                    "registry identifier does not resolve to a sample type: \(identifier)"
                )
            }
            #expect(HealthKitSampleTypeResolver.sampleType(for: "HKQuantityTypeIdentifierNotAThing") == nil)
        }
    }
#endif
