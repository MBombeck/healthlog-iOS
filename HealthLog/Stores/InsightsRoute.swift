import Foundation
import SwiftUI

/// Typed `AppRouter.insightsPath` payload: the pages the Insights stack
/// pushes from its overview.
///
/// The overview is one page of the horizontal pager, not the root of the
/// stack. A push it declared itself (`navigationDestination(isPresented:)`
/// on the page, a `@State` flag in the page) lived inside the paged scroll
/// view, so whether a tap pushed depended on that page's state and on the
/// stack still seeing the page's destination. The value goes onto the
/// stack's own path instead, and the container registers the destination
/// at the root of the stack, outside the pager.
enum InsightsRoute: Hashable {
    /// The timeline, from the row at the foot of the overview.
    case timeline
}

extension AppRouter {
    /// The row at the foot of the overview: one tap pushes the timeline.
    /// A second tap while the page is already on its way does not push it
    /// twice; the row is only on screen while the stack stands at its root.
    func openTimelineFromInsights() {
        guard insightsPath.isEmpty else { return }
        timeline.noteOpened()
        insightsPath.append(InsightsRoute.timeline)
    }

    /// The timeline pushed by value as the first page of the More stack is an
    /// opening by the person. Notes it before the page appears, so the page
    /// answers it once.
    func noteTimelineOpening(from oldPath: NavigationPath, to newPath: NavigationPath) {
        guard !isMovingPagesForLayout, oldPath.isEmpty, newPath == NavigationPath([MoreRoute.timeline]) else { return }
        HLLog.ui.notice("Zeitleiste: Tipp in Mehr")
        timeline.noteOpened()
    }
}
