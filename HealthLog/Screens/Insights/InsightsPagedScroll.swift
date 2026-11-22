import SwiftUI

/// The horizontally paged scroll view of Insights: one page per pill, each
/// exactly as wide as the pager, bound two ways to the pager model.
///
/// Built on the iOS-17 paged `ScrollView` (NOT `TabView(.page)`): a swipe
/// settles `scrolledID` on a page (mirrored into `selection` at rest, so the
/// strip pill follows), a pill tap sets `selection` (mirrored into
/// `scrolledID` by the container, so the pager scrolls). When the pager's
/// width changes, the page of the selection comes back under the snap.
///
/// Its own type so the whole bridge, scroll view included, can be hosted in
/// a test window and resized.
struct InsightsPagedScroll<Page: View>: View {
    let pager: InsightsPagerModel
    /// The frozen, folded page list.
    let pages: [InsightsPagerPage]
    let liveOrderedSelections: [InsightsTabSelection]
    /// The page of the selection, the one the strips and resets treat as active.
    let activePage: InsightsPagerPageID?
    @ViewBuilder let page: (InsightsPagerPage) -> Page

    /// Where a pager page's header puts its actions in a regular width: the
    /// page on screen into the shared bar, every other page nowhere. In a
    /// compact width every page shows them beside its title
    /// (``HLTabHeaderActionPlacement/resolved(sizeClass:)``).
    nonisolated static func actionPlacement(isActive: Bool) -> HLTabHeaderActionPlacement {
        isActive ? .bar : .hidden
    }

    var body: some View {
        ScrollViewReader { proxy in
            scroll(proxy: proxy)
        }
    }

    private func scroll(proxy: ScrollViewProxy) -> some View {
        // `@Bindable` so `.scrollPosition(id:)` binds to the model's `scrolledID`.
        @Bindable var pager = pager
        return ScrollView(.horizontal) {
            HStack(spacing: 0) {
                // Page on the FOLDED page list (one page per strip pill).
                ForEach(pages, id: \.scrollIdentity) { entry in
                    page(entry)
                        .environment(\.insightsPageIsActive, entry.scrollIdentity == activePage)
                        // Only the page on screen writes its actions into the
                        // one bar the pages share.
                        .environment(\.hlTabHeaderActionPlacement, Self.actionPlacement(isActive: entry.scrollIdentity == activePage))
                        // #34/#39 — every page exactly as wide as the pager, so
                        // the paging snap lands on a whole page.
                        //
                        // Hang fix — no `.vertical` axis: pinning each page to
                        // the container HEIGHT re-measured the overview's inner
                        // vertical `ScrollView` on every pass and re-triggered the
                        // pager's `.scrollPosition(id:)` resolver; AttributeGraph
                        // never converged. Each page sizes its own height.
                        .containerRelativeFrame(.horizontal)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .id(entry.scrollIdentity)
                }
            }
            .scrollTargetLayout()
        }
        // `.paging` forces a full-page snap on every swipe. The non-lazy
        // `HStack` keeps every mounted page alive (far metric pages are cheap
        // placeholders until realized). Indicators hidden — the strip IS it.
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $pager.scrolledID)
        // The page the pager rests on becomes the selection; a finger on the
        // pager ends any programmatic scroll it was waiting for.
        .onScrollPhaseChange { _, phase in
            pager.pagerScrollPhaseChanged(
                isIdle: phase == .idle,
                isUserDriven: phase == .tracking || phase == .interacting,
                pages: pages,
                liveOrderedSelections: liveOrderedSelections
            )
        }
        // Mirror a settled swipe back into `selection`. `scrollPosition(id:)`
        // also fires for transient resolver ids; the model ignores them while
        // a programmatic scroll is under way and while the pager moves.
        .onChange(of: pager.scrolledID) { _, newID in
            pager.adoptScrolledPage(newID, pages: pages, liveOrderedSelections: liveOrderedSelections)
        }
        .scrollIndicators(.hidden)
        // Each page is as wide as the pager's frame, but a scroll view draws
        // on into the side safe areas (the folded Duo's upright bar and clock,
        // an iPad sidebar), where the neighbouring page showed. Clipped at
        // the sides only, so a page still scrolls under the top edge.
        .clipShape(HorizontalClip())
        // Each page is as wide as the pager, so a new width (the Duo folds,
        // a window is resized, the iPad turns) leaves the offset inside
        // another page. At rest the page of the selection comes back under
        // the snap, without animation.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { oldWidth, newWidth in
            guard let anchor = pager.reanchorAfterWidthChange(
                oldWidth: oldWidth,
                newWidth: newWidth,
                pages: pages
            ) else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(anchor, anchor: .leading) }
            let armed = pager.programmaticScrollGeneration
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                pager.releaseStaleReanchor(generation: armed, pages: pages, liveOrderedSelections: liveOrderedSelections)
            }
        }
        .accessibilityIdentifier("insights.pager")
    }
}

/// A clip at a view's leading and trailing edges that leaves the top and the
/// bottom open.
struct HorizontalClip: Shape {
    /// How far the clip reaches past the top and the bottom.
    static let verticalReach: CGFloat = 10000

    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: 0, dy: -Self.verticalReach))
    }
}
