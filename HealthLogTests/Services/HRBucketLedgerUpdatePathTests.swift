import Foundation
@testable import HealthLog
import Testing

/// A heart-rate bucket ledger written by 1.5.1 must still be read after the
/// update, including one whose last suppression names the removed `flagOff`
/// gate. The fixtures are the shape 1.5.1 persisted: the synthesised
/// `Codable` of `HRBucketSyncLedger` through a plain `JSONEncoder`, so dates
/// are seconds since the reference date and gates their raw string.
@Suite("HR bucket ledger — update path from 1.5.1")
struct HRBucketLedgerUpdatePathTests {
    private static let user = "user-ledger-update"

    private func defaults(storing json: String) throws -> UserDefaults {
        let suite = "test.hrbucket.ledger-update.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(Data(json.utf8), forKey: HRBucketSyncLedgerStore.key(for: Self.user))
        return defaults
    }

    private static func ledgerJSON(lastEvent: String, lastSuppression: String) -> String {
        """
        {"bucketDays":[20730,20731],"rawDays":[20728],"settledDays":[20729],"dirtyDays":[],\
        "accepted":{"20731":{"815900400":"72|70|74"}},\
        "lastAcceptedBucket":815900400,"lastSuccessAt":815900500,\
        "lastEvent":{"gate":"\(lastEvent)","at":815900500,"count":3},\
        "lastSuppression":{"gate":"\(lastSuppression)","at":815800000,"count":0}}
        """
    }

    @Test("A ledger whose suppression names the removed flagOff gate keeps its days")
    func removedGateKeepsTheDays() throws {
        let defaults = try defaults(storing: Self.ledgerJSON(lastEvent: "uploaded", lastSuppression: "flagOff"))
        let ledger = HRBucketSyncLedgerStore.load(userId: Self.user, defaults: defaults)
        #expect(ledger.bucketDays == [20730, 20731])
        #expect(ledger.rawDays == [20728])
        #expect(ledger.settledDays == [20729])
        #expect(ledger.accepted[20731]?[815_900_400] == "72|70|74")
        #expect(ledger.lastEvent?.gate == .uploaded)
        #expect(ledger.lastSuppression == nil, "an event with an unknown gate is dropped, not guessed")
    }

    @Test("Every gate that still exists reads back from the 1.5.1 shape", arguments: HRBucketGate.allCases)
    func everyKnownGateReads(_ gate: HRBucketGate) throws {
        let defaults = try defaults(storing: Self.ledgerJSON(lastEvent: gate.rawValue, lastSuppression: gate.rawValue))
        let ledger = HRBucketSyncLedgerStore.load(userId: Self.user, defaults: defaults)
        #expect(ledger.bucketDays == [20730, 20731])
        #expect(ledger.lastEvent?.gate == gate)
        #expect(ledger.lastSuppression?.gate == gate)
    }
}
