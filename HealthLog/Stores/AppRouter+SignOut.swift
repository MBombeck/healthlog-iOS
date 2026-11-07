import SwiftUI

/// SET-ROUTE (#153 follow-up) — the More stack now remembers the Settings
/// pages as values, in memory, so they survive the privacy shield. A sign-out
/// must not hand that stack to the next session: whoever signs in next would
/// otherwise land on Settings › Account, where the last session signed out.
extension AppRouter {
    /// Back to the Home tab with every stack at its root. Pending deep links
    /// and request counters are left alone; they belong to the next sign-in.
    func resetNavigationForSignOut() {
        selectedTab = .home
        homePath = .init()
        medsPath = .init()
        insightsPath = .init()
        morePath = .init()
        focusedVisitId = nil
    }
}
