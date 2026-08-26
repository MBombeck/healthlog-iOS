#if canImport(HealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Synchronization
    import Testing

    /// Phase 07 Wave 2 — the app-owned collector's transaction.
    ///
    /// The properties under test are the ones that only become expressible once the
    /// app issues the query itself: the committed anchor is read *before* the query,
    /// a page that is not terminally accepted leaves the partition where it was, a
    /// budget genuinely bounds the walk, cancellation and a lost lease hold, and an
    /// observer burst produces one coalesced pass rather than one pass per callback.
    @Suite("Anchored health sample collector")
    struct AnchoredHealthSampleCollectorTests {
        // MARK: - The transaction

        @Test("the committed anchor is read before the query and the commit is what advances it")
        func committedAnchorIsReadBeforeQuery() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let backing = CollectorCursorBacking()
            let (store, key) = try await CollectorFixture.makeReplayingStore(backing: backing, lease: lease)

            let source = ScriptedPageSource(pages: [CollectorFixture.page(11), CollectorFixture.page(12)])
            let consumer = ScriptedConsumer(outcomes: [])
            let collector = AnchoredHealthSampleCollector(
                cursors: store,
                query: source,
                consumer: consumer,
                observer: nil
            )
            let cutoff = Date(timeIntervalSince1970: 1_000_000)

            _ = await collector.collect(
                typeIdentifiers: [CollectorFixture.stepType],
                trigger: .manual,
                notBefore: cutoff,
                requiring: lease
            )

            // The first query resumes from nothing, because a replaying partition
            // has no committed cursor yet — the chosen cutoff is what bounds it.
            #expect(source.resumedAnchors.count == 1)
            #expect(source.resumedAnchors.first.flatMap { $0 } == nil)
            #expect(source.observedCutoffs.allSatisfy { $0 == cutoff })
            #expect(await store.queryAnchor(for: key) == HKQueryAnchor(fromValue: 11))
        }

        @Test("a page that is not terminally accepted leaves the partition exactly where it was")
        func nonterminalPageDoesNotAdvanceTheCursor() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let backing = CollectorCursorBacking()
            let (store, key) = try await CollectorFixture.makeReplayingStore(backing: backing, lease: lease)

            let source = ScriptedPageSource(pages: [CollectorFixture.page(11, mayHaveMore: true), CollectorFixture.page(12)])
            let consumer = ScriptedConsumer(outcomes: [CollectorFixture.nonterminalOutcome()])
            let collector = AnchoredHealthSampleCollector(
                cursors: store,
                query: source,
                consumer: consumer
            )

            let results = await collector.collect(
                typeIdentifiers: [CollectorFixture.stepType],
                trigger: .manual,
                notBefore: .distantPast,
                requiring: lease
            )

            #expect(await store.anchor(for: key) == nil)
            #expect(results.first?.holdReason == .nonterminalEntry)
            #expect(results.first?.disposition == .failed)
            // The walk stops at the hold rather than reading past the page it
            // could not account for.
            #expect(source.queryCount == 1)
        }

        @Test("a durable retry lets the same page commit")
        func durableRetryCommitsThePage() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let backing = CollectorCursorBacking()
            let (store, key) = try await CollectorFixture.makeReplayingStore(backing: backing, lease: lease)

            let retried = HealthSyncPageOutcome(
                postedCount: 1,
                entries: [
                    HealthSyncEntryOutcome(index: 0, stableIdentity: "sample-0", classification: .nonterminal)
                ],
                transportThrew: false,
                durableRetryPersisted: true,
                durableRetryFailed: false,
                leaseIsCurrent: true,
                wasCancelled: false
            )
            let collector = AnchoredHealthSampleCollector(
                cursors: store,
                query: ScriptedPageSource(pages: [CollectorFixture.page(21)]),
                consumer: ScriptedConsumer(outcomes: [retried])
            )

            let results = await collector.collect(
                typeIdentifiers: [CollectorFixture.stepType],
                trigger: .manual,
                notBefore: .distantPast,
                requiring: lease
            )

            #expect(await store.queryAnchor(for: key) == HKQueryAnchor(fromValue: 21))
            #expect(results.first?.disposition == .retryPersisted)
            #expect(results.first?.holdReason == nil)
        }

        @Test("a lost durable retry write holds the cursor")
        func lostRetryWriteHoldsTheCursor() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let backing = CollectorCursorBacking()
            let (store, key) = try await CollectorFixture.makeReplayingStore(backing: backing, lease: lease)

            let lost = HealthSyncPageOutcome(
                postedCount: 1,
                entries: [
                    HealthSyncEntryOutcome(index: 0, stableIdentity: "sample-0", classification: .nonterminal)
                ],
                transportThrew: false,
                durableRetryPersisted: false,
                durableRetryFailed: true,
                leaseIsCurrent: true,
                wasCancelled: false
            )
            let collector = AnchoredHealthSampleCollector(
                cursors: store,
                query: ScriptedPageSource(pages: [CollectorFixture.page(31)]),
                consumer: ScriptedConsumer(outcomes: [lost])
            )

            let results = await collector.collect(
                typeIdentifiers: [CollectorFixture.stepType],
                trigger: .manual,
                notBefore: .distantPast,
                requiring: lease
            )

            #expect(await store.anchor(for: key) == nil)
            #expect(results.first?.holdReason == .retryPersistenceFailed)
        }

        @Test("a session replaced mid page holds the cursor")
        func replacedSessionHoldsTheCursor() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let backing = CollectorCursorBacking()
            let (store, key) = try await CollectorFixture.makeReplayingStore(backing: backing, lease: lease)

            // A same-owner re-login advances the Phase-06 generation, which is the
            // only signal that the admitted session was replaced.
            _ = registry.activate(ownerID: "account-a")

            let collector = AnchoredHealthSampleCollector(
                cursors: store,
                query: ScriptedPageSource(pages: [CollectorFixture.page(41)]),
                consumer: ScriptedConsumer(outcomes: [])
            )

            let results = await collector.collect(
                typeIdentifiers: [CollectorFixture.stepType],
                trigger: .manual,
                notBefore: .distantPast,
                requiring: lease
            )

            #expect(await store.anchor(for: key) == nil)
            #expect(results.first?.holdReason == .leaseLost)
        }

        @Test("a failed read holds the cursor and stops the walk")
        func failedReadHoldsTheCursor() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let backing = CollectorCursorBacking()
            let (store, key) = try await CollectorFixture.makeReplayingStore(backing: backing, lease: lease)

            let source = ScriptedPageSource(pages: [CollectorFixture.page(51)])
            source.failNextQuery()
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

            #expect(await store.anchor(for: key) == nil)
            #expect(results.first?.holdReason == .nonterminalEntry)
            #expect(results.first?.pagesCollected == 0)
        }
    }
#endif
