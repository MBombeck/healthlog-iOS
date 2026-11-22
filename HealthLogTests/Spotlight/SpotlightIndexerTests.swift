import CoreSpotlight
import Foundation
@testable import HealthLog
import Testing

/// Coverage for the off-main-actor index writer.
///
/// Uses a stub ``SpotlightIndexWriting`` so the indexer's
/// delete-then-index batching + sub-domain scoping is verifiable without
/// the live system index.
@Suite("Spotlight indexer")
struct SpotlightIndexerTests {
    @Test("replace deletes the sub-domain then indexes the built items")
    func replaceDeletesThenIndexes() async {
        let stub = StubIndex()
        let indexer = SpotlightIndexer(index: stub)
        await indexer.replace(
            [
                SpotlightIndexer.Entry(kind: .medication(id: "med_a"), title: "Lisinopril"),
                SpotlightIndexer.Entry(kind: .medication(id: "med_b"), title: "Trulicity")
            ],
            in: .medications
        )
        // The sub-domain was cleared first...
        #expect(stub.deletedDomains == [[SpotlightItemBuilder.Domain.medications.rawValue]])
        // ...then the two valid items were indexed.
        #expect(stub.indexedIDs == ["healthlog://medications/med_a", "healthlog://medications/med_b"])
    }

    @Test("Entries that fail the builder are dropped, not indexed")
    func dropsInvalidEntries() async {
        let stub = StubIndex()
        let indexer = SpotlightIndexer(index: stub)
        await indexer.replace(
            [
                SpotlightIndexer.Entry(kind: .medication(id: "med_a"), title: "Lisinopril"),
                // Bad id → no deep-link → dropped.
                SpotlightIndexer.Entry(kind: .medication(id: "../bad"), title: "Tampered"),
                // PHI-shaped title → dropped.
                SpotlightIndexer.Entry(kind: .medication(id: "med_c"), title: "120/80")
            ],
            in: .medications
        )
        #expect(stub.indexedIDs == ["healthlog://medications/med_a"])
    }

    @Test("An empty set clears the sub-domain and indexes nothing")
    func emptySetClearsOnly() async {
        let stub = StubIndex()
        let indexer = SpotlightIndexer(index: stub)
        await indexer.replace([], in: .measurements)
        #expect(stub.deletedDomains == [[SpotlightItemBuilder.Domain.measurements.rawValue]])
        #expect(stub.indexedIDs.isEmpty)
    }

    @Test("deleteAll clears both sub-domains")
    func deleteAllClearsBoth() async {
        let stub = StubIndex()
        let indexer = SpotlightIndexer(index: stub)
        await indexer.deleteAll()
        #expect(
            stub.deletedDomains == [[
                SpotlightItemBuilder.Domain.medications.rawValue,
                SpotlightItemBuilder.Domain.measurements.rawValue
            ]]
        )
    }

    @Test("a reindex planned before sign-out indexes nothing after the teardown")
    func staleReindexAfterSignOutIsDropped() async {
        let stub = StubIndex()
        let indexer = SpotlightIndexer(index: stub)
        await indexer.deleteAll(generation: 1)
        await indexer.replace(
            [SpotlightIndexer.Entry(kind: .medication(id: "med_a"), title: "Lisinopril")],
            in: .medications,
            generation: 0
        )
        #expect(stub.indexedIDs.isEmpty)
        // The next account's reindex runs under the new generation.
        await indexer.replace(
            [SpotlightIndexer.Entry(kind: .medication(id: "med_b"), title: "Trulicity")],
            in: .medications,
            generation: 1
        )
        #expect(stub.indexedIDs == ["healthlog://medications/med_b"])
    }

    @Test("a sign-out that lands while a reindex awaits the index wins")
    func signOutDuringReindexWins() async {
        let gate = GatedIndex()
        let indexer = SpotlightIndexer(index: gate)
        gate.onFirstDelete = { await indexer.deleteAll(generation: 1) }
        await indexer.replace(
            [SpotlightIndexer.Entry(kind: .medication(id: "med_a"), title: "Lisinopril")],
            in: .medications,
            generation: 0
        )
        #expect(gate.indexedCount == 0)
        #expect(gate.deleteCount == 2)
    }
}

/// An index whose first delete runs a hook while the indexer awaits it: the
/// window in which a sign-out can land.
private final class GatedIndex: SpotlightIndexWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var _indexed = 0
    private var _deletes = 0
    private var _onFirstDelete: (@Sendable () async -> Void)?

    var onFirstDelete: (@Sendable () async -> Void)? {
        get { lock.withLock { _onFirstDelete } }
        set { lock.withLock { _onFirstDelete = newValue } }
    }

    var indexedCount: Int {
        lock.withLock { _indexed }
    }

    var deleteCount: Int {
        lock.withLock { _deletes }
    }

    func hlIndexItems(_ items: [CSSearchableItem]) async throws {
        lock.withLock { _indexed += items.count }
    }

    func hlDeleteItems(inDomains _: [String]) async throws {
        let hook: (@Sendable () async -> Void)? = lock.withLock {
            _deletes += 1
            defer { _onFirstDelete = nil }
            return _onFirstDelete
        }
        await hook?()
    }
}

/// Thread-safe stub index. Modeled as a lock-guarded `final class` (not an
/// `actor`) because the seam method takes `[CSSearchableItem]`, which is not
/// `Sendable` and so cannot cross an actor boundary — the real
/// `CSSearchableIndex` conforms as a non-isolated class for the same reason.
private final class StubIndex: SpotlightIndexWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var _indexedIDs: [String] = []
    private var _deletedDomains: [[String]] = []

    var indexedIDs: [String] {
        lock.withLock { _indexedIDs }
    }

    var deletedDomains: [[String]] {
        lock.withLock { _deletedDomains }
    }

    func hlIndexItems(_ items: [CSSearchableItem]) async throws {
        let ids = items.map(\.uniqueIdentifier)
        lock.withLock { _indexedIDs.append(contentsOf: ids) }
    }

    func hlDeleteItems(inDomains identifiers: [String]) async throws {
        lock.withLock { _deletedDomains.append(identifiers) }
    }
}
