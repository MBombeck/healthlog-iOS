import Foundation

/// #115 · 1.1 — which way a weight change counts as progress, judged by the
/// server against the person's own stored target.
///
/// Wire: `GET /api/dashboard/snapshot` → `tiles.weightTrend`
/// (`{ direction: "up-good" | "up-bad" | "hold", targetPosition: "below" |
/// "inside" | "above" | null }`, server `src/lib/targets/weight-trend.ts`,
/// v1.39). The server resolves it from the target the person entered; the app
/// renders it and never re-derives it from a band, a height or a gravity rule.
///
/// Absent on a v1.39 snapshot means the server's historical reading: the
/// OpenAPI description says "when absent, treat it as `up-bad`". That is a
/// statement the server makes, so ``DashboardSnapshotBriefing`` resolves an
/// absent block to ``legacyReading``. No snapshot at all (offline, not yet
/// loaded) is a different case: the caller then has no judgement and the tile
/// colours nothing.
public struct WeightTrendJudgement: Codable, Sendable, Hashable {
    /// Where the reference weight sits against the stored target.
    public enum TargetPosition: String, Codable, Sendable, Hashable, TolerantServerEnum {
        case below
        case inside
        case above
        /// A position word this build does not know.
        case unknown

        public static let unknownFallback = TargetPosition.unknown
        public static let wireVocabulary: StaticString = "weight target position"
    }

    /// How the tile colours a change. Decoded tolerantly: a new word becomes
    /// ``TrendDirectionSentiment/unknown`` and colours nothing.
    public let direction: TrendDirectionSentiment
    /// `nil` when no target is stored or there is no reading yet.
    public let targetPosition: TargetPosition?

    public init(direction: TrendDirectionSentiment, targetPosition: TargetPosition?) {
        self.direction = direction
        self.targetPosition = targetPosition
    }

    /// The reading the server documents for a snapshot without the block
    /// (older cached snapshot cells, servers before v1.39).
    public static let legacyReading = WeightTrendJudgement(direction: .upBad, targetPosition: nil)

    private enum CodingKeys: String, CodingKey {
        case direction, targetPosition
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        direction = try c.decode(TrendDirectionSentiment.self, forKey: .direction)
        targetPosition = try c.decodeIfPresent(TargetPosition.self, forKey: .targetPosition)
    }
}
