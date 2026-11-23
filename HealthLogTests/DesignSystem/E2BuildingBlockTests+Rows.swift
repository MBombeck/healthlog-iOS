@testable import HealthLog
import SwiftUI
import Testing

extension E2BuildingBlockTests {
    @Test("the drill row says what is behind it: entries in the period, outside it, or none")
    func drillRowDetail() {
        #expect(HLDrillRow.Detail.of(count: 30) == .inPeriod(30))
        #expect(HLDrillRow.Detail.of(count: 0) == .empty)
        #expect(HLDrillRow.Detail.of(count: 0, hasEntriesOutsidePeriod: true) == .outsidePeriod)
        #expect(HLDrillRow.Detail.of(count: nil) == .unknown)
        #expect(HLDrillRow("Show all measurements", count: 0, hasEntriesOutsidePeriod: true).detail == .outsidePeriod)
    }
}
