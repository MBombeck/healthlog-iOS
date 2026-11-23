import SwiftUI

/// The load of a metric page: once when the page first appears, and again
/// only when what it shows changes (metric, period, source), never because
/// the pager moved.
///
/// The page's store outlives the page in the pager's store cache, so a page
/// that comes back into view, or is built again, finds its data there. Its
/// own type, so the paging contract test hosts exactly this wiring.
struct InsightsMetricLoadTask: ViewModifier {
    let store: ChartDetailStore

    func body(content: Content) -> some View {
        content.task(id: store.queryKey) {
            // v0.14 audit #17 — close the tap-to-detail interval begun in
            // `DashboardScreen.openDetail`.
            HLPerfSignpost.endTapToDetailIfPending()
            await store.load()
        }
    }
}
