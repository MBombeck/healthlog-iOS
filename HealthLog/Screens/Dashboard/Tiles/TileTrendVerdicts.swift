import Foundation

/// **1.5 VERDICTS (#135 rest)** — where the colour of a tile's trend arrow
/// comes from, on Today and in the Insights overview.
///
/// The server judges which way a change counts; the app paints that verdict
/// and nothing else. In this order:
///
/// 1. the person's own target (`direction` on `GET /api/insights/targets`),
///    judged against their band, so a blood pressure above its target that
///    rises is bad and one below it that rises is good;
/// 2. the snapshot's `tiles.directions` for the tile's measurement type (and,
///    on a server before v1.43, `tiles.weightTrend` for weight);
/// 3. the card's own `trendSentiment` from the dashboard summary;
/// 4. otherwise neutral: the arrow shows the direction in one quiet colour.
///
/// The per-metric polarity table (`MetricKindDescriptor.trendPolarity`) is no
/// colour source any more. An unknown verdict word colours nothing.
public struct TileTrendVerdicts: Equatable, Sendable {
    /// Target type (`WEIGHT`, `BLOOD_PRESSURE`, `PULSE` for the resting band,
    /// …) → the target's verdict.
    let targets: [String: TrendDirectionSentiment]
    /// Measurement type → the snapshot's verdict.
    let directions: [String: TrendDirectionSentiment]
    /// `tiles.weightTrend.direction`, the weight verdict of v1.39 to v1.42.
    let weightTrend: TrendDirectionSentiment?

    /// No verdicts at all: only the card's own `trendSentiment` can colour.
    public static let none = TileTrendVerdicts(targets: [:], directions: [:], weightTrend: nil)

    init(
        targets: [String: TrendDirectionSentiment],
        directions: [String: TrendDirectionSentiment],
        weightTrend: TrendDirectionSentiment?
    ) {
        self.targets = targets.filter { $0.value != .unknown }
        self.directions = directions.filter { $0.value != .unknown }
        self.weightTrend = weightTrend == .unknown ? nil : weightTrend
    }

    /// From what the dashboard already loaded; either side may be `nil`
    /// (cold launch, offline, an older server).
    public init(targets: InsightsTargetsResponseDTO?, snapshot: DashboardSnapshotBriefing?) {
        var byType: [String: TrendDirectionSentiment] = [:]
        for target in targets?.targets ?? [] {
            if let direction = target.direction?.direction { byType[target.type] = direction }
        }
        self.init(
            targets: byType,
            directions: (snapshot?.directions ?? [:]).mapValues(\.direction),
            weightTrend: snapshot?.weightTrend?.direction
        )
    }

    /// The chip mode for one card.
    func mode(for metric: DashboardMetric) -> TrendChip.Mode {
        if let type = MetricChartMath.bandTargetType(for: metric.kind), let verdict = targets[type] {
            return .serverSentiment(verdict)
        }
        if let key = metric.kind.availabilitySummaryKey, let verdict = directions[key] {
            return .serverSentiment(verdict)
        }
        if metric.kind == .weight, let weightTrend {
            return .serverSentiment(weightTrend)
        }
        if let sentiment = metric.trendSentiment, sentiment != .unknown {
            return .serverVerdict(sentiment)
        }
        return .neutral
    }
}
