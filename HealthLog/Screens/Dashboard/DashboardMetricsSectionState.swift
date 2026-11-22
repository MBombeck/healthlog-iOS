import Foundation

/// Decides what the Home metrics section renders while
/// `DashboardStore.summary` is `nil`.
///
/// Pre-#67 the section had a single fallback — an indefinite `SkeletonContent()`
/// — for *both* "still loading" and "the summary subrequest failed with no
/// cached fallback". So a failed (decode / status / transport) summary request
/// left the lower dashboard cards shimmering forever while the independent score
/// rings rendered above and a generic "Couldn't read the data" banner appeared:
/// the reported partial-failure symptom.
///
/// This pure resolver splits the two so the view stops the skeleton on a
/// failure (`.error`) and leaves the report to the top banner. A successfully
/// decoded summary (even a stale cached one served by the SWR `.failed` arm)
/// always wins → `.content`, so a failing *secondary* request never blanks
/// already-loaded sections.
enum DashboardMetricsSectionState: Equatable {
    /// A summary is present — render the real metric composition.
    case content
    /// No summary AND the load failed with nothing cached to fall back on —
    /// no skeleton; the top banner carries the failure and its retry.
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
}
