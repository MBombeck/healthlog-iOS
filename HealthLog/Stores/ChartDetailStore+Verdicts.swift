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
    ///
    /// **#176 (v1.48)** — for the week, the month and the year the server's
    /// comparison with the previous window of the same length comes first
    /// (`/api/analytics/range`, ``rangeTrend``): the month is the rule the
    /// dashboard card's arrow follows, so the tile and the page agree. Its
    /// direction is the server's `trend`, never the sign read here.
    var rangeChange: RangeChange? {
        let current = rangeTrend?.windowDays == range.rawValue ? rangeTrend?.value : nil
        return Self.rangeChange(series: series, rangeTrend: Self.usableRangeTrend(current, kind: kind))
    }

    /// The range read the page may use. Server 1.49.0 names its unit and is
    /// always usable. An older answer is in the stored unit: fine for the
    /// families the page converts itself, but glucose's stored mg/dL cannot
    /// be told from the account's unit, so glucose keeps the series' change.
    nonisolated static func usableRangeTrend(_ trend: AnalyticsRangeTrend?, kind: MetricKind) -> AnalyticsRangeTrend? {
        guard let trend else { return nil }
        if trend.isInAccountUnit { return trend }
        return kind.unitFamily == .glucose ? nil : trend
    }

    nonisolated static func rangeChange(series: MeasurementSeries?, rangeTrend: AnalyticsRangeTrend?) -> RangeChange? {
        if let shown = rangeTrend?.shownChange {
            return RangeChange(
                delta: shown.delta,
                sentiment: agreeingSentiment(series?.change, trend: shown.trend),
                basis: .priorWindow,
                trend: shown.trend,
                inAccountUnit: rangeTrend?.isInAccountUnit ?? false,
                unit: rangeTrend?.unit
            )
        }
        return rangeChange(series: series)
    }

    /// The series' verdict, kept only where its change points the way the
    /// window comparison does: the server judged that direction for this
    /// person, so the pill keeps the tile arrow's colour. A change the other
    /// way says nothing about this one, and the pill stays grey.
    nonisolated static func agreeingSentiment(_ change: SeriesChange?, trend: TrendIndicator) -> TrendSentiment? {
        guard let change, change.delta.isFinite else { return nil }
        switch trend {
        case .up: return change.delta > 0 ? change.sentiment : nil
        case .down: return change.delta < 0 ? change.sentiment : nil
        case .flat, .unknown: return nil
        }
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
        /// #176 (v1.48): the window's mean against the previous window of
        /// the same length, as `/api/analytics/range` compares them.
        case priorWindow
    }

    /// In the series' unit (convert with ``ChartDetailStore/displayDelta(of:units:)``),
    /// or already in the account's unit when ``inAccountUnit``.
    public let delta: Double
    /// The server's verdict on this change; `nil` → neutral colour.
    public let sentiment: TrendSentiment?
    public let basis: Basis
    /// The server's direction for this change (``Basis/priorWindow``); `nil`
    /// where the sign of ``delta`` is the direction.
    public let trend: TrendIndicator?
    /// Server 1.49.0: the window comparison came in the account's unit and
    /// is shown as sent.
    public let inAccountUnit: Bool
    /// The concrete unit the server sent with it (`kg`, `lb`, `mmol/L`,
    /// `bpm`), shown as sent; `nil` before 1.49.0 or for the series' change.
    public let unit: String?

    public init(
        delta: Double,
        sentiment: TrendSentiment?,
        basis: Basis,
        trend: TrendIndicator? = nil,
        inAccountUnit: Bool = false,
        unit: String? = nil
    ) {
        self.delta = delta
        self.sentiment = sentiment
        self.basis = basis
        self.trend = trend
        self.inAccountUnit = inAccountUnit
        self.unit = unit
    }

    /// The arrow: the server's `trend` when it sent one (`flat` is a dash,
    /// even for a small non-zero delta), else the sign of the delta.
    public var symbol: String {
        switch trend {
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .flat: "minus"
        case .unknown, .none: delta > 0 ? "arrow.up" : delta < 0 ? "arrow.down" : "minus"
        }
    }
}

extension MeasurementSeries {
    /// `true` when the series came from a server that sends verdicts (v1.43:
    /// `direction`, `change`, `referenceLines`). On such a server a missing
    /// `change` is the server's answer, not a gap to fill.
    var carriesServerVerdicts: Bool {
        direction != nil || change != nil || referenceLines != nil
    }
}
