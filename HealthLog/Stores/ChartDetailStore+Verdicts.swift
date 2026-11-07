import Foundation

/// #135 (server v1.43) — the series route's own verdict and reference lines,
/// read for the metric page. Nothing here judges or places a line: the store
/// hands on what the server sent, converted into the unit the chart plots in.
public extension ChartDetailStore {
    /// The reference lines in the account's unit, the same conversion the
    /// plotted points take (``plotPoints(units:)``): glucose arrives converted
    /// by the server and passes through, a blood pressure in kPa or a weight
    /// in lb converts like a point. Empty on an older server, on a series that
    /// carries none and on a kind this build cannot name.
    func plotReferenceLines(units: UnitPreferences) -> [SeriesReferenceLine] {
        guard !kind.isUnknown, let lines = series?.referenceLines, !lines.isEmpty else { return [] }
        return lines.map { line in
            let converted = kind.unitFamily == nil ? line.value : convertSeriesValue(line.value, units: units)
            return line.withValue(converted)
        }
    }

    /// **1.5 VERDICTS (#135 rest)** — the change the hero chip and the range
    /// caption show, and where its colour comes from.
    ///
    /// - The series carries `change` (v1.43): its first-to-last-day delta and
    ///   its `sentiment`, as sent. Nothing is recomputed.
    /// - The series comes from a server that knows `change` but sent none
    ///   (under two days in the window): no change, nothing shown. The app does
    ///   not make up a figure the server declined to give.
    /// - An older server (no verdict fields at all): the page's own comparison
    ///   of the window's two halves, in neutral colour.
    var rangeChange: RangeChange? {
        Self.rangeChange(series: series)
    }

    nonisolated static func rangeChange(series: MeasurementSeries?) -> RangeChange? {
        guard let series else { return nil }
        if let change = series.change, change.delta.isFinite {
            return RangeChange(delta: change.delta, sentiment: change.sentiment, basis: .firstToLastDay)
        }
        if series.carriesServerVerdicts { return nil }
        guard let local = priorHalfDelta(series.points) else { return nil }
        return RangeChange(delta: local, sentiment: nil, basis: .priorHalf)
    }

    /// The older servers' comparison: mean of the later half of the loaded
    /// points against the earlier half. `nil` under four points.
    nonisolated static func priorHalfDelta(_ points: [SeriesPoint]) -> Double? {
        guard points.count >= 4 else { return nil }
        let half = points.count / 2
        let priorAvg = points.prefix(half).map(\.value).reduce(0, +) / Double(half)
        let recentAvg = points.suffix(points.count - half).map(\.value).reduce(0, +) / Double(points.count - half)
        return recentAvg - priorAvg
    }
}

/// One change of a metric over the shown window (``ChartDetailStore/rangeChange``).
public struct RangeChange: Equatable, Sendable {
    /// What the change compares, so the caption can say it.
    public enum Basis: Equatable, Sendable {
        /// The server's `change`: first to last day in the window.
        case firstToLastDay
        /// An older server: the later half of the window against the earlier.
        case priorHalf
    }

    /// In the series' unit (convert with ``ChartDetailStore/convertDelta(_:units:)``).
    public let delta: Double
    /// The server's verdict on this change; `nil` → neutral colour.
    public let sentiment: TrendSentiment?
    public let basis: Basis
}

extension MeasurementSeries {
    /// `true` when the series came from a server that sends verdicts (v1.43:
    /// `direction`, `change`, `referenceLines`). On such a server a missing
    /// `change` is the server's answer, not a gap to fill.
    var carriesServerVerdicts: Bool {
        direction != nil || change != nil || referenceLines != nil
    }
}
