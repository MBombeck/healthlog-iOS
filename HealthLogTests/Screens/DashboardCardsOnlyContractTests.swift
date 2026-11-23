import Foundation
@testable import HealthLog
import Testing

@Suite("Dashboard ships one canonical cards presentation")
struct DashboardCardsOnlyContractTests {
    @Test("Cards is the only selectable dashboard presentation")
    func cardsIsOnlyPresentation() {
        #expect(DashboardLayout.allCases == [.cards])
        #expect(DashboardLayout(rawValue: "hero") == nil)
        #expect(DashboardLayout(rawValue: "list") == nil)
    }
}
