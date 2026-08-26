import Foundation

/// #67 — decides what the Home metrics section renders while
/// `DashboardStore.summary` is `nil`.
///
/// Pre-#67 the section had a single fallback — an indefinite `SkeletonContent()`
/// — for *both* "still loading" and "the summary subrequest failed with no
/// cached fallback". So a failed (decode / status / transport) summary request
/// left the lower dashboard cards shimmering forever while the independent score
/// rings rendered above and a generic "Couldn't read the data" banner appeared:
/// the reported partial-failure symptom.
///
/// This pure resolver splits the two so the view can show an honest per-section
/// error + retry (`.error`) instead of a silent-blank skeleton. A successfully
/// decoded summary (even a stale cached one served by the SWR `.failed` arm)
/// always wins → `.content`, so a failing *secondary* request never blanks
/// already-loaded sections.
enum DashboardMetricsSectionState: Equatable {
    /// A summary is present — render the real metric composition.
    case content
    /// No summary AND the load failed with nothing cached to fall back on —
    /// render the honest error + retry card.
    case error
    /// No summary yet and a load is (or may still be) in flight — skeleton.
    case skeleton

    /// - Parameters:
    ///   - hasSummary: `store.summary != nil`.
    ///   - hasError: `store.error != nil`.
    ///   - isLoading: `store.isLoading` — a fetch is in flight (a retry after an
    ///     error re-enters this state, so we keep showing the skeleton then).
    static func resolve(hasSummary: Bool, hasError: Bool, isLoading: Bool) -> Self {
        if hasSummary { return .content }
        if hasError, !isLoading { return .error }
        return .skeleton
    }

    /// Operator-feedback b235 — `true` when the Home metrics section is showing
    /// the INLINE error card (`DashboardMetricsErrorState`, #67), so the caller
    /// must suppress the red top banner and NOT report the same partial failure
    /// twice. This is exactly the `.error` metrics-section state, so the two
    /// surfaces can never disagree: the banner is silenced in precisely the
    /// state that renders the inline card, and stays the sole surface in every
    /// other error case (e.g. a secondary-request failure while a cached summary
    /// still paints the tiles → `hasSummary == true` → no suppression).
    static func suppressesTopBanner(hasSummary: Bool, hasError: Bool, isLoading: Bool) -> Bool {
        resolve(hasSummary: hasSummary, hasError: hasError, isLoading: isLoading) == .error
    }
}
