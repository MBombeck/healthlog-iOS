import Foundation
@testable import HealthLog
import Testing

/// Every sync trigger carries a bounded budget, and the short wakes stay
/// incremental.
@Suite("HealthKit sync trigger routing")
struct HealthSyncTriggerRoutingTests {
    @Test("every trigger carries an explicit, bounded budget")
    func everyTriggerHasABudget() {
        for trigger in HealthSyncTrigger.allCases {
            let budget = HealthSyncBudget.required(for: trigger)
            #expect(budget.maxPagesPerType >= 0)
        }

        #expect(HealthSyncBudget.required(for: .appRefresh).incrementalOnly)
        #expect(HealthSyncBudget.required(for: .silentPush).incrementalOnly)
        #expect(!HealthSyncBudget.required(for: .appRefresh).allowsFirstHistoryImport)
        #expect(!HealthSyncBudget.required(for: .silentPush).allowsFirstHistoryImport)

        let processing = HealthSyncBudget.required(for: .processing)
        #expect(!processing.incrementalOnly)
        #expect(processing.allowsFirstHistoryImport)
        #expect(processing.maxPagesPerType > HealthSyncBudget.required(for: .appRefresh).maxPagesPerType)

        #expect(HealthSyncBudget.required(for: .accountTeardown).maxPagesPerType == 0)
    }
}
