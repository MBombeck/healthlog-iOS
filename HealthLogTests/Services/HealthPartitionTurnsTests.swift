// One live leg per account and type.
//
// Since the observers are registered at launch, an observer delivery and the
// first pass from the window can reach the same collector together. These
// tests hold the first leg inside its upload and check that the second one
// neither reads the same anchor nor writes an older one over a newer one.

#if canImport(HealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Synchronization
    import Testing

    /// Holds the first page inside its upload until the test lets it go.
    private final class HeldConsumer: HealthSamplePageConsuming, Sendable {
        private let entered = Mutex(0)
        private let release = AsyncStream<Void>.makeStream()

        var consumedPages: Int {
            entered.withLock { $0 }
        }

        func letGo() {
            release.continuation.yield()
        }

        func consume(
            _: [HKSample],
            ofType _: String,
            requiring _: HealthSyncAuthenticatedLease
        ) async -> HealthSyncPageOutcome {
            let first = entered.withLock { count -> Bool in
                count += 1
                return count == 1
            }
            if first {
                for await _ in release.stream {
                    break
                }
            }
            return ScriptedConsumer.accepted
        }

        func consumeHistory(
            _ samples: [HKSample],
            ofType typeIdentifier: String,
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HealthSyncPageOutcome {
            await consume(samples, ofType: typeIdentifier, requiring: lease)
        }
    }

    @Suite("Health partition turns", .serialized)
    struct HealthPartitionTurnsTests {
        @Test("a delivery and a pass of one type run one after the other, the second from the first one's cursor")
        func concurrentLegsAreSerialised() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let backing = CollectorCursorBacking()
            let (store, _) = try await CollectorFixture.makeReplayingStore(backing: backing, lease: lease)
            let source = ScriptedPageSource(pages: [CollectorFixture.page(1), CollectorFixture.page(2)])
            let consumer = HeldConsumer()
            let collector = AnchoredHealthSampleCollector(cursors: store, query: source, consumer: consumer)
            let type = CollectorFixture.stepType

            let delivery = Task {
                await collector.collect(typeIdentifiers: [type], trigger: .observer, notBefore: .distantPast, requiring: lease)
            }
            while consumer.consumedPages == 0 {
                await Task.yield()
            }
            let pass = Task {
                await collector.collect(typeIdentifiers: [type], trigger: .manual, notBefore: .distantPast, requiring: lease)
            }
            let turn = HealthPartitionTurns.key(ownerID: lease.ownerID, typeIdentifier: type)
            // The pass waits for its turn: it has not read anything yet.
            for _ in 0 ..< 50 {
                await Task.yield()
            }
            #expect(await collector.liveTurns.isHeld(turn))
            #expect(source.queryCount == 1)

            consumer.letGo()
            let first = await delivery.value
            let second = await pass.value

            #expect(first.first?.disposition == .succeeded)
            #expect(second.first?.disposition == .succeeded)
            // The second leg resumed after the first one's commit, so the
            // page was read and sent once.
            #expect(source.resumedAnchors == [nil, HKQueryAnchor(fromValue: 1)])
            #expect(await !collector.liveTurns.isHeld(turn))
        }

        @Test("a commit that finds a cursor moved by someone else holds and keeps the later cursor")
        func olderCommitNeverOverwritesALaterCursor() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let backing = CollectorCursorBacking()
            let (store, key) = try await CollectorFixture.makeReplayingStore(backing: backing, lease: lease)
            let older = try #require(HealthKitAnchorArchive.encodeAnchor(HKQueryAnchor(fromValue: 1), label: "test"))
            let later = try #require(HealthKitAnchorArchive.encodeAnchor(HKQueryAnchor(fromValue: 2), label: "test"))

            // Run A read "no cursor"; run B committed `later` meanwhile.
            let readByA = await store.anchor(for: key)
            #expect(await store.commit(page: ScriptedConsumer.accepted, anchor: later, for: key, requiring: lease) == .commit)

            let decision = await store.commit(
                page: ScriptedConsumer.accepted,
                anchor: older,
                for: key,
                requiring: lease,
                replacing: readByA
            )

            #expect(decision == .hold(reason: .superseded))
            #expect(await store.anchor(for: key) == later)
            // The expected predecessor commits as before.
            let next = try #require(HealthKitAnchorArchive.encodeAnchor(HKQueryAnchor(fromValue: 3), label: "test"))
            #expect(await store.commit(
                page: ScriptedConsumer.accepted,
                anchor: next,
                for: key,
                requiring: lease,
                replacing: later
            ) == .commit)
        }

        @Test("turns of different types or accounts do not wait for each other")
        func turnsAreKeyedByAccountAndType() async {
            let turns = HealthPartitionTurns()
            let stepsA = HealthPartitionTurns.key(ownerID: "a", typeIdentifier: "steps")
            let pulseA = HealthPartitionTurns.key(ownerID: "a", typeIdentifier: "pulse")
            let stepsB = HealthPartitionTurns.key(ownerID: "b", typeIdentifier: "steps")

            await turns.acquire(stepsA)
            await turns.acquire(pulseA)
            await turns.acquire(stepsB)

            #expect(await turns.isHeld(stepsA))
            #expect(await turns.isHeld(pulseA))
            #expect(await turns.isHeld(stepsB))
            await turns.release(stepsA)
            #expect(await !turns.isHeld(stepsA))
        }
    }
#endif
