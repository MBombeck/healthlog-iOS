import Foundation
@testable import HealthLog
import Testing

/// #67 — dashboard partial-failure resilience contract.
///
/// Locks the decision the Home metrics section makes while `summary == nil`: a
/// failed summary subrequest with no cached fallback shows an honest error +
/// retry (`.error`) instead of an indefinite skeleton, while a successfully
/// decoded summary (even a stale cached one) always wins → `.content`. This is
/// the pure spec `DashboardMetricsHost` renders against, so the resilience
/// behaviour is pinned without instantiating the SwiftUI tree.
@Suite("DashboardMetricsSectionState — #67 partial-failure resilience")
struct DashboardMetricsSectionStateTests {
    @Test("A present summary always renders content, even mid-error")
    func summaryWinsOverError() {
        // A failing *secondary* request sets `error` while a summary is still
        // present — the intact section must stay put, never blank.
        #expect(
            DashboardMetricsSectionState.resolve(hasSummary: true, hasError: true, isLoading: false) == .content
        )
        #expect(
            DashboardMetricsSectionState.resolve(hasSummary: true, hasError: false, isLoading: true) == .content
        )
    }

    @Test("Failed load with no cached summary shows the honest error+retry, not a skeleton")
    func failedLoadShowsError() {
        #expect(
            DashboardMetricsSectionState.resolve(hasSummary: false, hasError: true, isLoading: false) == .error
        )
    }

    @Test("Cold launch / in-flight load shows the skeleton")
    func loadingShowsSkeleton() {
        // No data yet, nothing failed.
        #expect(
            DashboardMetricsSectionState.resolve(hasSummary: false, hasError: false, isLoading: true) == .skeleton
        )
        // First idle tick before the fetch kicks off.
        #expect(
            DashboardMetricsSectionState.resolve(hasSummary: false, hasError: false, isLoading: false) == .skeleton
        )
    }

    @Test("A retry after an error re-enters the skeleton, not a stuck error card")
    func retryInFlightShowsSkeleton() {
        // On retry the store clears `error` and flips `isLoading` true — the
        // section must fall back to the skeleton, not freeze on the error card.
        #expect(
            DashboardMetricsSectionState.resolve(hasSummary: false, hasError: false, isLoading: true) == .skeleton
        )
    }
}
