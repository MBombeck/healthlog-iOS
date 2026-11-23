import Foundation

/// The mood page's period window: the one option set every detail page with a
/// time series offers (T, W, M, 6M, J, Alle), so the floating control on the
/// mood page reads exactly like the one on the metric pages.
typealias MoodPeriod = HLTimeRange

extension HLTimeRange {
    /// Keeps only entries within the trailing window from `now`.
    ///
    /// The cutoff is `rawValue` days before local midnight, inclusive. `.all`
    /// keeps its 3650 days instead of having no lower edge: `MoodAnalysisCache`
    /// rebuilds this window from the same raw value, so the page and the cache
    /// always cut the history at the same instant.
    func filter(_ entries: [MoodEntry], now: Date = .now, calendar: Calendar = .current) -> [MoodEntry] {
        guard let cutoff = calendar.date(byAdding: .day, value: -rawValue, to: calendar.startOfDay(for: now)) else {
            return entries
        }
        return entries.filter { $0.recordedAt >= cutoff }
    }
}
