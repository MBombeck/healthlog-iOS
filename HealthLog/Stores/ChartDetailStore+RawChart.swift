import Foundation

// The chart drawn from single readings: which points it draws when the server
// series is missing or empty, and whether the page limit cut the range short.

extension ChartDetailStore {
    /// The series points when the server sent any, else the in-range readings
    /// in time order. An empty series is no evidence against readings the
    /// list page holds, so it never hides them.
    nonisolated static func chartPoints(series: MeasurementSeries?, recent: [Measurement]) -> [SeriesPoint] {
        if let points = series?.points, !points.isEmpty {
            return points
        }
        return recent
            .sorted { $0.recordedAt < $1.recordedAt }
            .map { measurement in
                SeriesPoint(
                    id: measurement.id,
                    at: measurement.recordedAt,
                    value: measurement.value.primaryComponent,
                    secondary: nil
                )
            }
    }

    /// `true` when a full page ends after the start of the range: readings
    /// older than the page's oldest row may exist and are not on it.
    nonisolated static func recentPageIsCut(_ recent: [Measurement], limit: Int, cutoff: Date) -> Bool {
        guard limit > 0, recent.count >= limit, let oldest = recent.map(\.recordedAt).min() else { return false }
        return oldest > cutoff
    }

    /// The limit to name under the chart when it is drawn from readings and
    /// the page was cut, else `nil`. A series or a part-of-day chart is not
    /// bound by the page, so neither gets the note.
    var rawChartCapLimit: Int? {
        guard activePartOfDay == nil, displaySeries?.points.isEmpty ?? true else { return nil }
        return recentPageCapLimit
    }
}
