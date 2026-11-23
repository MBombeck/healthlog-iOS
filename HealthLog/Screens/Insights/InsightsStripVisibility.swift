import SwiftUI

// MARK: - The strip over the pager

/// What the one Insights strip over the pager draws.
///
/// The container owns the selection and the order; the strip stands fixed
/// at the top of the tab and its chosen pill follows the page.
///
/// Equal when what the strip draws is equal: the selection, the order and
/// the note. The two actions are left out on purpose;
/// the container rebuilds them on every update with the same effect, and
/// counting them made every update look like a change to every strip.
struct InsightsStripContext: Equatable {
    var selection: Binding<InsightsTabSelection>
    /// The selection's value when the context was made, the one a strip draws.
    var selected: InsightsTabSelection
    var orderedSelections: [InsightsTabSelection]
    var onPillTap: @MainActor (InsightsTabSelection) -> Void
    var onCustomize: @MainActor () -> Void
    var availabilityNote: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selected == rhs.selected
            && lhs.orderedSelections == rhs.orderedSelections
            && lhs.availabilityNote == rhs.availabilityNote
    }
}

extension EnvironmentValues {
    /// Whether the page around this view is the pager's visible page.
    @Entry var insightsPageIsActive = false
    /// Whether the page around this view is a page of the Insights pager;
    /// `false` on a page shown on its own (the metric page pushed from the
    /// dashboard) and on a page pushed from inside the tab. Constant for a
    /// page, so a view that asks "am I in the pager" is not run again on
    /// every swipe; the strip's context, which changes with every page, is
    /// not in the environment at all.
    @Entry var insightsInPager = false
    /// Bumped when the pill of the active page is tapped again.
    @Entry var insightsPageRetapSignal = 0
}

/// The strip itself, from a context.
private struct InsightsContextStrip: View {
    let context: InsightsStripContext
    let shownSelection: InsightsTabSelection?

    var body: some View {
        InsightsMetricTabStrip(
            selection: context.selection,
            shownSelection: shownSelection,
            orderedSelections: context.orderedSelections,
            onPillTap: context.onPillTap,
            onCustomize: context.onCustomize,
            availabilityNote: context.availabilityNote
        )
    }
}

/// Where the strip runs on a wide window: over the readable column and one
/// page margin on each side, the same on both sides.
enum InsightsStripLayout {
    /// The widest the strip runs: the column and a margin on each side.
    static let maximumWidth = HLLayout.readableWidth + 2 * HLLayout.pageMargin

    /// The fade at a cut end: the page margin where the strip runs over it,
    /// twice that where it ends at the column, so a chip there fades out
    /// instead of reading as cut.
    static func fadeLength(contentInset: CGFloat) -> CGFloat {
        contentInset > 0 ? HLEdgeFade.length : 2 * HLLayout.pageMargin
    }

    /// The strip's width in a pager `pageWidth` wide.
    static func width(pageWidth: CGFloat) -> CGFloat {
        min(max(0, pageWidth), maximumWidth)
    }
}

/// The one strip of the tab, under the active page's head, over the pager,
/// on the app's background that fades into the page below it.
struct InsightsPinnedStrip: View {
    let context: InsightsStripContext
    /// The pill shown chosen while a swipe passes a page; `nil` shows the
    /// selection.
    var shownSelection: InsightsTabSelection?

    var body: some View {
        // The pills run over the page's column and a margin on each side;
        // the background spans the window.
        InsightsContextStrip(context: context, shownSelection: shownSelection)
            .frame(maxWidth: InsightsStripLayout.maximumWidth)
            .clipped()
            .frame(maxWidth: .infinity)
            // The app's own background behind the whole row of pills, from
            // window edge to window edge, so no page content shows between
            // two pills; below the row it fades into the page like the
            // system's soft scroll edge.
            .background {
                VStack(spacing: 0) {
                    HLSurface.primary
                    LinearGradient(
                        colors: [HLSurface.primary, HLSurface.primary.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: Self.fadeHeight)
                }
                // The fade hangs below the strip's own frame, over the page.
                .padding(.bottom, -Self.fadeHeight)
                .ignoresSafeArea(edges: .horizontal)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }

    /// How far below the pills the background fades into the page.
    static let fadeHeight: CGFloat = HLSpace.md
}

// MARK: - A page's scroll position over activation

/// What a pager page does with its own scroll position: a page the pager
/// leaves goes back to its top once it is out of view, so it is at its top
/// when it comes back, and a re-tap of the active pill brings the active page
/// to its top. Reads the activation from the environment, so a page change
/// runs this modifier and not the page.
struct InsightsPageScrollReset: ViewModifier {
    @Binding var position: ScrollPosition

    @Environment(\.insightsPageIsActive) private var isActive
    @Environment(\.insightsPageRetapSignal) private var retapSignal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Counts activation changes, so a reset meant for a page that has
    /// already come back is dropped.
    @State private var activationChanges = 0

    /// How long a page that was left stays as it is: past the end of a paging
    /// slide, so it never moves in view.
    static let resetDelay: Duration = .milliseconds(450)

    func body(content: Content) -> some View {
        content
            .onChange(of: isActive) { _, active in
                activationChanges += 1
                guard !active else { return }
                let change = activationChanges
                Task { @MainActor in
                    try? await Task.sleep(for: Self.resetDelay)
                    guard change == activationChanges else { return }
                    position.scrollTo(edge: .top)
                }
            }
            .onChange(of: retapSignal) { _, _ in
                guard isActive else { return }
                if reduceMotion {
                    position.scrollTo(edge: .top)
                } else {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        position.scrollTo(edge: .top)
                    }
                }
            }
    }
}
