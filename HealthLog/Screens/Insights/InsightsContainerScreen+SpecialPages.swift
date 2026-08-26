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
}
