import CoreGraphics

/// **The pager's snap across a change of its width.**
///
/// Every page is exactly as wide as the pager (`containerRelativeFrame`). When
/// that width changes (the Duo folds or opens, a Stage Manager window is
/// resized, the iPad turns), the scroll offset stays in points while the pages
/// change their width under it: the offset then lies inside another page or
/// between two, and the position report names a page the person never chose.
/// At rest that report would become the selection.
///
/// So a width change at rest brings the remembered page, the page of the
/// selection, back under the snap: the model latches it as a programmatic
/// target (echoes on the way are ignored) and the view scrolls to it without
/// animation. Pure, so the rule is testable without a scroll view.
enum InsightsPagerAnchor {
    /// Below this the change is rounding, not a new width.
    static let tolerance: CGFloat = 0.5

    /// Whether the pager must snap back after its width went from `oldWidth`
    /// to `newWidth`. Not before the first real measure, not for rounding,
    /// and not while a finger or the deceleration moves the pager: that
    /// motion ends on a whole page by itself.
    static func needsReanchor(oldWidth: CGFloat, newWidth: CGFloat, isScrolling: Bool) -> Bool {
        guard !isScrolling, oldWidth > 0, newWidth > 0 else { return false }
        return abs(newWidth - oldWidth) > tolerance
    }

    /// The page the pager snaps back to: the page of the selection.
    static func anchor(for selection: InsightsTabSelection, in pages: [InsightsPagerPage]) -> InsightsPagerPageID? {
        InsightsPagerPage.page(for: selection, in: pages)?.scrollIdentity
    }
}
