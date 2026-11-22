@testable import HealthLog
import SwiftUI
import Testing

/// Every tab root carries its page actions in the system bar, so the large
/// titles of all tabs stand at the same height; the Insights pager lets only
/// the page on screen write into the bar the pages share.
@Suite("F9C tab header placement")
@MainActor
struct F9CTabHeaderPlacementTests {
    @Test("a tab header puts its actions into the bar unless told otherwise")
    func defaultIsBar() {
        #expect(EnvironmentValues().hlTabHeaderActionPlacement == .bar)
    }

    @Test("only the Insights page on screen writes into the bar")
    func pagerPlacement() {
        #expect(InsightsPagedScroll<EmptyView>.actionPlacement(isActive: true) == .bar)
        #expect(InsightsPagedScroll<EmptyView>.actionPlacement(isActive: false) == .hidden)
    }
}
