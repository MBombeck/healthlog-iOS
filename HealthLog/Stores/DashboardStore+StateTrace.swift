import Foundation

/// **V0.5.4-BF-1 forensic trail helpers.** Split out of `DashboardStore.swift`
/// to keep that file under the 600-line swiftlint `file_length` baseline —
/// the sticky-state-machine debug-logging path is independent of the rest
/// of the store and isolating it makes grepping flicker-related logs in
/// the source tree easier (`grep -rn stateTag HealthLog/Stores`).
extension DashboardStore {
    /// Forensic-only label per `MetricDataState` case. Compact (~12 chars)
    /// so log-stream output stays readable in `Console.app`. No PII — only
    /// the case tag (+ for `.empty` the reason discriminator) is emitted.
    static func stateTag(_ state: MetricDataState) -> String {
        switch state {
        case .unknown: "unknown"
        case .loading: "loading"
        case .ready: "ready"
        case let .empty(reason):
            switch reason {
            case .noData: "empty(noData)"
            case .outsideRange: "empty(outsideRange)"
            case .sourceFiltered: "empty(sourceFiltered)"
            }
        }
    }
}
