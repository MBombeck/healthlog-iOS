import SwiftUI

/// **The fixed top of the Insights tab: the page's head, then the strip.**
///
/// As in the reference: the title of the page with its actions at the top,
/// the pill strip right under it, the page's content under both. Each page
/// keeps its own head (its actions open its own sheets), fixed in a top
/// inset of the page, so the title slides with its page and lands without a
/// jump. Under the head the page leaves the strip's room free; the ONE strip
/// of the tab stands there, over the pager, at the height of the active
/// page's head.
///
/// Heights travel through this small model rather than through the
/// container's body: the strip reads them in a view of its own.
@MainActor
@Observable
final class InsightsChromeMetrics {
    /// The head of the active page, in points.
    private(set) var headHeight: CGFloat = 0
    /// The strip, in points: the room every page leaves under its head.
    private(set) var stripHeight: CGFloat = 0

    /// Below this the change is rounding, not a new height.
    nonisolated static let tolerance: CGFloat = 0.5

    func report(headHeight height: CGFloat) {
        if abs(height - headHeight) > Self.tolerance { headHeight = height }
    }

    func report(stripHeight height: CGFloat) {
        if abs(height - stripHeight) > Self.tolerance { stripHeight = height }
    }
}

extension EnvironmentValues {
    /// The heights of the tab's fixed top; `nil` outside the pager.
    @Entry var insightsChrome: InsightsChromeMetrics?
}

extension View {
    /// Pins `head` at the top of a pager page, with the strip's room under
    /// it. Outside the pager (`enabled == false`) the page keeps its head in
    /// its content and this does nothing.
    func insightsPageHead(enabled: Bool, @ViewBuilder _ head: () -> some View) -> some View {
        modifier(InsightsPageHeadModifier(enabled: enabled, head: head()))
    }
}

private struct InsightsPageHeadModifier<Head: View>: ViewModifier {
    let enabled: Bool
    let head: Head

    func body(content: Content) -> some View {
        if enabled {
            content.safeAreaInset(edge: .top, spacing: 0) {
                InsightsPinnedHead(head: head)
            }
        } else {
            content
        }
    }
}

/// The pinned head of a page and the strip's room under it, on the app's
/// background so the page scrolls under both.
private struct InsightsPinnedHead<Head: View>: View {
    let head: Head
    @Environment(\.insightsChrome) private var chrome
    @Environment(\.insightsPageIsActive) private var isActive
    /// The last measured height of this head, reported again when the page
    /// becomes the active one.
    @State private var height: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            head
                // The column and margins of `HLPage`, so the title stands
                // where it stood at the top of the page's content.
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxWidth: HLLayout.readableWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, HLLayout.pageMargin)
                .padding(.top, HLLayout.pageTop)
                .padding(.bottom, HLSpace.sm)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newHeight in
                    height = newHeight
                    if isActive { chrome?.report(headHeight: newHeight) }
                }
                .onChange(of: isActive, initial: true) { _, active in
                    if active, height > 0 { chrome?.report(headHeight: height) }
                }
            InsightsStripRoom()
        }
        .background(HLSurface.primary.ignoresSafeArea(edges: [.top, .horizontal]))
        // Its own container: the page's identifier, set on the page around
        // it, would otherwise replace the title's and the actions' own.
        .accessibilityElement(children: .contain)
    }
}

/// The room a page leaves for the strip under its head.
private struct InsightsStripRoom: View {
    @Environment(\.insightsChrome) private var chrome

    var body: some View {
        Color.clear
            .frame(height: chrome?.stripHeight ?? 0)
            .accessibilityHidden(true)
    }
}

/// The one strip of the tab, under the active page's head.
struct InsightsChromeStrip: View {
    let context: InsightsStripContext
    let chrome: InsightsChromeMetrics
    /// Read here, not in the container, so the pill that follows a swipe
    /// runs this view alone.
    let pager: InsightsPagerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        InsightsPinnedStrip(context: context, shownSelection: pager.stripSelection)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chrome.report(stripHeight: $0) }
            .offset(y: chrome.headHeight)
            // A page with a taller head (a title on two lines) moves the
            // strip once, when the page lands.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: chrome.headHeight)
    }
}
