import CoreSpotlight
import Foundation
@testable import HealthLog
import Testing

/// **W-B187 QOL-2** — coverage for the off-main-actor index writer.
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
