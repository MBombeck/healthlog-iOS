import Foundation

/// SUPP (1.5.0, #131) — what the detail page says about the latest day
/// beyond its total: the split by source and, only on the server's verdict,
/// the upper intake level with its source. Both come from the server; the
/// day's `/daily` point wins, the overview row fills in for a server or a
/// moment where the series does not carry them.
public struct NutrientLatestBreakdown: Equatable, Sendable {
    public let parts: [NutrientSourcePart]
    /// The upper-limit sentence, `nil` unless the server says the day is above.
    public let upperLimitNote: String?

    public var isEmpty: Bool {
        parts.isEmpty && upperLimitNote == nil
    }
}

public struct NutrientSourcePart: Equatable, Sendable, Identifiable {
    public let source: NutrientSource
    public let amount: Double
    public let unit: String

    public var id: String {
        source.rawValue
    }

    public var amountText: String {
        NutrientDisplay.formatted(amount: amount, wireUnit: unit)
    }
}

public extension NutrientStore {
    /// The breakdown of the latest day with data for `code`, or an empty one.
    func latestBreakdown(for code: NutrientCode) -> NutrientLatestBreakdown {
        Self.latestBreakdown(
            series: dailyByCode[code],
            row: rows.first { $0.nutrient == code && code != .unknown }
        )
    }

    nonisolated static func latestBreakdown(
        series: NutrientDailySeriesDTO?,
        row: NutrientOverviewRowDTO?
    ) -> NutrientLatestBreakdown {
        let latest = series?.latestNonEmptyDay
        // The overview row describes its own `latestDay`; it only stands in
        // for the series when both name the same day (or there is no series).
        let rowMatches = row.map { row in latest.map { $0.day == row.latestDay } ?? true } ?? false
        let unit = series?.unit ?? row?.unit ?? ""
        let bySource = latest?.bySource ?? (rowMatches ? row?.latestBySource : nil)
        let parts = (bySource?.visibleParts ?? []).map {
            NutrientSourcePart(source: $0.source, amount: $0.amount, unit: unit)
        }
        let above = latest?.aboveUpperLimit ?? (rowMatches ? row?.latestAboveUpperLimit : nil)
        let limit = series?.upperLimit ?? row?.upperLimit
        return NutrientLatestBreakdown(
            parts: parts,
            upperLimitNote: NutrientDisplay.upperLimitNote(above: above, limit: limit)
        )
    }
}
