import Foundation
@testable import HealthLog
import Testing

/// Dashboard footer wiring after removing the redundant capture action.
@MainActor
@Suite("Dashboard quick actions (item 7.2)")
struct DashboardQuickActionsTests {
    @Test("router.requestCapture() flips to the Erfassen tab (capture-picker entry)")
    func requestCaptureSelectsMeasureTab() {
        let router = AppRouter()
        #expect(router.selectedTab == .home)
        router.requestCapture()
        #expect(router.selectedTab == .measure)
    }

    @Test("footer invokes the customize closure it is handed")
    func footerFiresCustomizeAction() {
        var customized = false
        let footer = DashboardQuickActionsFooter(onShowCustomize: { customized = true })
        footer.onShowCustomize()
        #expect(customized)
    }
}
