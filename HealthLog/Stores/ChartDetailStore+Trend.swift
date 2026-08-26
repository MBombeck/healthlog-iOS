import Foundation
import Observation

/// `ChartDetailStore` trend + year-over-year decoration (HeroStrip trend chips).
/// Extracted from `ChartDetailStore.swift` (file_length discipline — pure move,
/// no behaviour change).
@MainActor
public extension ChartDetailStore {
    // MARK: - v0.7.0 W-API-RENDER — trend + year-over-year decoration

    /// Ordered 7/30/90-day regression slopes for the HeroStrip trend chips.
    /// Each entry pairs a window label key with the server `TrendSlope`.
    /// Empty when no comprehensive summary landed for this metric.
    var trendSlopes: [(window: TrendWindow, slope: TrendSlope)] {
        Self.trendSlopes(from: metricSummary)
    }

    /// Pure helper — `nonisolated` so unit tests can pin the slope ordering
    /// without a live store load. Returns 7/30/90 windows in fixed order,
    /// skipping any the server omitted.
    nonisolated static func trendSlopes(
        from summary: MetricSummary?
    ) -> [(window: TrendWindow, slope: TrendSlope)] {
        guard let summary else { return [] }
        var out: [(TrendWindow, TrendSlope)] = []
        if let s = summary.slope7 { out.append((.week, s)) }
        if let s = summary.slope30 { out.append((.month, s)) }
        if let s = summary.slope90 { out.append((.quarter, s)) }
        return out
    }

    /// Window descriptor for a trend chip — drives the short label ("7T" /
    /// "30T" / "90T") rendered next to each slope direction glyph.
    enum TrendWindow: Sendable {
        case week
        case month
        case quarter

        public var shortLabel: String {
            switch self {
            case .week: String(localized: "7d")
            case .month: String(localized: "30d")
            case .quarter: String(localized: "90d")
            }
        }
    }

    /// Server-computed 30-day average a year ago (`avg30LastYear`). The hero
    /// "vor 1 Jahr" row renders this baseline + a delta against the current
    /// 30-day average. `nil` when the server has no year-old window (user
    /// onboarded < 1y ago) or no summary landed.
    var avg30LastYear: Double? {
        metricSummary?.avg30LastYear
    }

    /// Delta of the current 30-day average against the year-ago baseline.
    /// `nil` when either side is missing. Positive = higher than a year ago.
    var deltaVsLastYear: Double? {
        Self.deltaVsLastYear(from: metricSummary)
    }

    /// Pure helper — `nonisolated` so the year-over-year delta math can be
    /// pinned in unit tests. Prefers the current 30-day average, falling
    /// back to `latest`, and returns `nil` when no baseline (`avg30LastYear`)
    /// or no current value exists.
    nonisolated static func deltaVsLastYear(from summary: MetricSummary?) -> Double? {
        guard let lastYear = summary?.avg30LastYear,
              let current = summary?.avg30 ?? summary?.latest else { return nil }
        return current - lastYear
    }
}
