import SwiftUI

// MARK: - Special composite pages

extension InsightsContainerScreen {
    /// One of the composite special pages (mood / medications / workouts /
    /// ECG). Each is a normal vertical page inside the pager with the strip
    /// under its title; the page wrapper in `pager` pins it with `.containerRelativeFrame(.horizontal)` ONLY (the
    /// W44 contract — never the vertical axis). The special stores are warm
    /// (loaded in the container `.task`s + already injected app-wide), so no lazy
    /// realization gate is needed here — the views read directly from the store.
    ///
    /// Lifted out of `InsightsContainerScreen` into this extension to
    /// keep the screen body under the `file_length` budget after the Recovery
    /// sub-page wiring landed. Pure move, no behaviour change.
    @ViewBuilder
    func specialPage(_ page: InsightsSpecialPage) -> some View {
        switch page {
        case .mood:
            InsightsMoodPage()
                .accessibilityIdentifier("insights.page.mood")
        case .medications:
            InsightsMedicationsPage()
                .accessibilityIdentifier("insights.page.medications")
        case .workouts:
            InsightsWorkoutsPage()
                .accessibilityIdentifier("insights.page.workouts")
        case .ecg:
            InsightsEcgPage()
                .accessibilityIdentifier("insights.page.ecg")
        }
    }

    // MARK: - Deep links to data-gated pages

    /// Resolve the router's parked Insights slug onto the pager, then admit a
    /// data-gated special target whose source has already answered empty.
    func stageDeepLink() {
        pager.stageInsightsMetricIfRequested(
            router: router,
            liveOrderedSelections: liveOrderedSelections,
            pages: pagerPages
        )
        applyAdmittedSpecialTarget()
    }

    /// A data-gated source answered: record it, and land a link that waited
    /// for it.
    func settleSpecial(_ page: InsightsSpecialPage) {
        pager.markSpecialSettled(page)
        applyAdmittedSpecialTarget()
    }

    /// A deep link to mood, medications or ECG on an account without that data
    /// used to stay staged forever: the strip offers no such page, so the link
    /// did nothing at all. Admitting the page latches its pill, after which the
    /// live order holds the target and the staged link lands on the page's own
    /// empty state, the same way Workouts shows its own.
    private func applyAdmittedSpecialTarget() {
        guard pager.admitStagedSpecialIfSettled() else { return }
        pager.tryApplyStagedMetric(liveOrderedSelections: liveOrderedSelections, pages: pagerPages)
    }
}
