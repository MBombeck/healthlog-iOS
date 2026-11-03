import SwiftUI

// MARK: - Special composite pages

extension InsightsContainerScreen {
    /// W28c — one of the composite special pages (mood / medications / workouts /
    /// recovery). Each is a normal vertical page inside the pager: its own inner
    /// `ScrollView` reports its offset to `stripVisibility`, and the page wrapper
    /// in `pager` pins it with `.containerRelativeFrame(.horizontal)` ONLY (the
    /// W44 contract — never the vertical axis). The special stores are warm
    /// (loaded in the container `.task`s + already injected app-wide), so no lazy
    /// realization gate is needed here — the views read directly from the store.
    ///
    /// W-B189 — lifted out of `InsightsContainerScreen` into this extension to
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
        case .recovery:
            InsightsRecoveryPage()
                .accessibilityIdentifier("insights.page.recovery")
        case .ecg:
            InsightsEcgPage()
                .accessibilityIdentifier("insights.page.ecg")
        }
    }

    // MARK: - Deep links to data-gated pages (1.4 C1)

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
    /// empty state, the same way Workouts and Recovery show theirs.
    private func applyAdmittedSpecialTarget() {
        guard pager.admitStagedSpecialIfSettled() else { return }
        pager.tryApplyStagedMetric(liveOrderedSelections: liveOrderedSelections, pages: pagerPages)
    }
}

extension View {
    /// 1.4 C1 — where an Insights special page puts its empty state: from the
    /// top, inside the page margins, like Workouts and ECG. Mood and
    /// Medications centred theirs without margins, so the button ran into
    /// both screen edges once a link could reach those pages empty.
    func insightsEmptyStatePlacement() -> some View {
        frame(maxWidth: .infinity)
            .padding(.horizontal, HLSpace.xl)
            .padding(.top, HLSpace.xxxl)
            .frame(maxHeight: .infinity, alignment: .top)
    }
}
