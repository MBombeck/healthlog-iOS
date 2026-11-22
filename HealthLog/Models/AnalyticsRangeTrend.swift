import Foundation

/// **#176 (server v1.48)** — the part of `GET /api/analytics/range` the metric
/// page reads: this window's mean against the previous window of the same
/// length (`delta`) and the direction the server read from it (`trend`).
///
/// The dashboard card takes its arrow from the same comparison over `30d`
/// (`trendWindowDays: 30`), so the page shows that change instead of making
/// one up: nothing is recomputed here. `deltaPct` is a fraction (0.03 = +3 %).
///
/// **Server 1.49.0** answers in the account's unit and names it (`unit`):
/// glucose per the glucose unit, weight, length, distance and temperature per
/// the metric or imperial setting. Then `delta` is shown as sent. A server
/// before 1.49 sends no `unit` and its `delta` is in the stored unit
/// (systolic for blood pressure); the page converts that one as before, and
/// leaves glucose out, whose stored mg/dL it cannot tell from the account's
/// unit (``isInAccountUnit``).
///
/// Tolerant: an older server (no `trend`) reads as ``TrendIndicator/unknown``,
/// and an unknown token lands there too, so the page falls back to its own
/// first-to-last-day change.
public struct AnalyticsRangeTrend: Codable, Sendable, Equatable {
    /// The window the server read (`7d`, `30d`, `90d`, `1y`).
    public let range: String
    public let windowDays: Int
    public let delta: Double?
    public let deltaPct: Double?
    public let trend: TrendIndicator
    /// The unit every figure is in (server 1.49.0), raw; `nil` before.
    public let unit: String?

    public init(
        range: String,
        windowDays: Int,
        delta: Double?,
        deltaPct: Double?,
        trend: TrendIndicator,
        unit: String? = nil
    ) {
        self.range = range
        self.windowDays = windowDays
        self.delta = delta
        self.deltaPct = deltaPct
        self.trend = trend
        self.unit = unit
    }

    private enum CodingKeys: String, CodingKey {
        case range, windowDays, delta, deltaPct, trend, unit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        range = try c.decodeIfPresent(String.self, forKey: .range) ?? ""
        windowDays = (try? c.decodeIfPresent(Int.self, forKey: .windowDays)).flatMap { $0 } ?? 0
        delta = (try? c.decodeIfPresent(Double.self, forKey: .delta)).flatMap { $0 }
        deltaPct = (try? c.decodeIfPresent(Double.self, forKey: .deltaPct)).flatMap { $0 }
        trend = (try? c.decodeIfPresent(TrendIndicator.self, forKey: .trend)).flatMap { $0 } ?? .unknown
        unit = (try? c.decodeIfPresent(String.self, forKey: .unit)).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `true` when the server answered in the account's unit (1.49.0): the
    /// figures are shown as sent, never converted again.
    public var isInAccountUnit: Bool {
        unit != nil
    }

    /// The change the page may show: a known direction with a finite delta.
    /// `unknown` (no previous window, or an older server) shows nothing from
    /// this read.
    public var shownChange: (delta: Double, trend: TrendIndicator)? {
        guard trend != .unknown, let delta, delta.isFinite else { return nil }
        return (delta, trend)
    }
}
