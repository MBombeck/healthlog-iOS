@testable import HealthLog
import SwiftUI
import Testing

/// Medications and Home in the standardisation pass: the link under the full
/// intake history, and the one size of the "taken" mark on the card and in
/// Home's intake sheet.
@Suite("E3 medications and start")
struct E3BMedicationsAndStartTests {
    private typealias Link = IntakeHistorySection.HistoryLink

    @Test("Collapsed, the link unfolds what is loaded or what the server still has")
    func collapsedShowsMore() {
        #expect(IntakeHistorySection.historyLink(filtersMissed: false, isExpanded: false, hasOlderLoadedRows: true, hasMore: false)
            == Link.showMore)
        #expect(IntakeHistorySection.historyLink(filtersMissed: false, isExpanded: false, hasOlderLoadedRows: false, hasMore: true)
            == Link.showMore)
    }

    @Test("Collapsed with nothing more, there is no link")
    func collapsedWithNothingMore() {
        #expect(IntakeHistorySection.historyLink(filtersMissed: false, isExpanded: false, hasOlderLoadedRows: false, hasMore: false)
            == Link.none)
    }

    @Test("Unfolded, the link pages while the server has more, then folds back")
    func expandedPagesThenFolds() {
        #expect(IntakeHistorySection.historyLink(filtersMissed: false, isExpanded: true, hasOlderLoadedRows: true, hasMore: true)
            == Link.loadMore)
        #expect(IntakeHistorySection.historyLink(filtersMissed: false, isExpanded: true, hasOlderLoadedRows: true, hasMore: false)
            == Link.showFewer)
    }

    @Test("The missed-only filter only pages", arguments: [false, true])
    func missedFilterOnlyPages(isExpanded: Bool) {
        #expect(IntakeHistorySection.historyLink(filtersMissed: true, isExpanded: isExpanded, hasOlderLoadedRows: true, hasMore: true)
            == Link.loadMore)
        #expect(IntakeHistorySection.historyLink(filtersMissed: true, isExpanded: isExpanded, hasOlderLoadedRows: true, hasMore: false)
            == Link.none)
    }

    @Test("The taken mark has one size on the card and in Home's intake sheet")
    @MainActor
    func markSize() {
        #expect(MedicationQuickMarkButton.symbolSize == HLIconSize.lg)
    }
}
