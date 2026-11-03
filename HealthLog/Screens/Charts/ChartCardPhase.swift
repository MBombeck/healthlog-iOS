import Foundation

/// **1.4 B1 — which face ``ChartCard`` shows, as a pure function.**
///
/// The card used to fall back to „Noch keine Daten" three seconds into a load
/// that had not finished, and after every failed load. Both told the user there
/// was nothing to show when the truth was „still loading" or „could not load".
///
/// The order is the contract:
/// 1. Points decide first. Two or more draw the chart, one draws the
///    one-reading card, whatever the load is doing.
/// 2. A load in flight is a spinner, even when an earlier load left `.empty`
///    behind. Only the newest load clears `isLoading`, so a superseded load
///    can no longer end the spinner early.
/// 3. A finished load with an error is the error face.
/// 4. Nothing asked yet (`dataState` still pending) is a spinner too; the host
///    starts the load in the same frame.
/// 5. Only what is left, a finished load without points and without an error,
///    is „Noch keine Daten".
enum ChartCardPhase: Equatable {
    case chart
    case singlePoint
    case loading
    case failed
    case empty

    static func resolve(
        pointCount: Int,
        dataState: MetricDataState,
        isLoading: Bool,
        hasError: Bool
    ) -> ChartCardPhase {
        if pointCount >= 2 { return .chart }
        if pointCount == 1 { return .singlePoint }
        if isLoading { return .loading }
        if hasError { return .failed }
        if dataState.isPending { return .loading }
        return .empty
    }
}
