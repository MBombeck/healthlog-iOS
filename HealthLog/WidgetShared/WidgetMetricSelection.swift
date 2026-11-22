import Foundation

/// **Which reading the measurement widget shows for its configuration.**
///
/// The widget was a fixed "last recorded" glance. It now lets the person pick a
/// metric, and the old behaviour is the choice "Zuletzt erfasst": no choice, or
/// the explicit ``latestToken``, resolves to exactly the single reading the
/// snapshot has always carried, so a widget placed before the update keeps
/// showing the same thing.
public enum WidgetMetricSelection {
    /// The id of the "Zuletzt erfasst" choice.
    public static let latestToken = "latest"

    public struct Resolved: Equatable, Sendable {
        /// The reading to paint, or `nil` when there is nothing to show.
        public let reading: WidgetSnapshot.LatestMeasurement?
        /// One point per day, oldest first. Empty when no trend is known.
        public let trend: [WidgetSnapshot.MetricGlance.TrendPoint]
        /// `true` for "Zuletzt erfasst". The existing layouts then stay as they
        /// were, with no trend drawn into them.
        public let followsLatest: Bool

        /// The trend only counts as a line from two points on.
        public var drawsTrend: Bool {
            trend.count >= 2
        }
    }

    public static func resolve(snapshot: WidgetSnapshot, choice kindRaw: String?) -> Resolved {
        guard let kindRaw, kindRaw != latestToken else {
            let latest = snapshot.latestMeasurement
            let trend = latest.flatMap { latest in
                snapshot.metricGlances.first { $0.kindRaw == latest.kindRaw }?.trend
            } ?? []
            return Resolved(reading: latest, trend: trend, followsLatest: true)
        }
        guard let glance = snapshot.metricGlances.first(where: { $0.kindRaw == kindRaw }) else {
            return Resolved(reading: nil, trend: [], followsLatest: false)
        }
        return Resolved(reading: glance.latest, trend: glance.trend, followsLatest: false)
    }

    /// The widget families that differ in whether they draw a trend.
    public enum TrendFamily: Sendable {
        case small, medium, large, extraLarge
        case accessoryCircular, accessoryRectangular, accessoryInline
    }

    /// Whether a family draws the trend. The families a measurement widget
    /// already had before the choice existed (small, large, rectangular) draw it
    /// only for a picked metric, so a widget placed earlier keeps its look even
    /// though the app now writes trends. The families added with the choice draw
    /// it whenever a trend is known. The circular and inline accessories have no
    /// room for one.
    public static func drawsTrend(in family: TrendFamily, resolved: Resolved) -> Bool {
        guard resolved.drawsTrend else { return false }
        switch family {
        case .small, .large, .accessoryRectangular: return !resolved.followsLatest
        case .medium, .extraLarge: return true
        case .accessoryCircular, .accessoryInline: return false
        }
    }

    public struct CurveSegment: Equatable, Sendable {
        public let control1: (x: Double, y: Double)
        public let control2: (x: Double, y: Double)
        public let end: (x: Double, y: Double)

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.control1 == rhs.control1 && lhs.control2 == rhs.control2 && lhs.end == rhs.end
        }
    }

    /// Cubic Bezier segments of the monotone interpolant (Fritsch and Carlson)
    /// through `points`, which must run left to right. Between two points the
    /// curve stays inside the range of those two points' `y`, so it cannot
    /// swing past a reading. Points that do not advance in `x` are joined by a
    /// flat tangent.
    public static func monotoneSegments(_ points: [(x: Double, y: Double)]) -> [CurveSegment] {
        let n = points.count
        guard n >= 2 else { return [] }
        let dx = (0 ..< n - 1).map { points[$0 + 1].x - points[$0].x }
        let secant = (0 ..< n - 1).map { dx[$0] > 0 ? (points[$0 + 1].y - points[$0].y) / dx[$0] : 0 }
        var slope = [Double](repeating: 0, count: n)
        slope[0] = secant[0]
        slope[n - 1] = secant[n - 2]
        if n > 2 {
            for k in 1 ..< n - 1 {
                slope[k] = secant[k - 1] * secant[k] <= 0 ? 0 : (secant[k - 1] + secant[k]) / 2
            }
        }
        for k in 0 ..< n - 1 {
            if secant[k] == 0 {
                slope[k] = 0
                slope[k + 1] = 0
                continue
            }
            let alpha = slope[k] / secant[k]
            let beta = slope[k + 1] / secant[k]
            if alpha < 0 { slope[k] = 0 }
            if beta < 0 { slope[k + 1] = 0 }
            let sum = alpha * alpha + beta * beta
            if sum > 9 {
                let tau = 3 / sum.squareRoot()
                slope[k] = tau * alpha * secant[k]
                slope[k + 1] = tau * beta * secant[k]
            }
        }
        return (0 ..< n - 1).map { k in
            let h = dx[k]
            return CurveSegment(
                control1: (points[k].x + h / 3, points[k].y + slope[k] * h / 3),
                control2: (points[k + 1].x - h / 3, points[k + 1].y - slope[k + 1] * h / 3),
                end: points[k + 1]
            )
        }
    }

    /// The line a trend draws: points scaled into `0...1` on both axes, so a
    /// flat series sits in the middle instead of dividing by zero. Fewer than
    /// two points give no line.
    public static func normalized(
        _ trend: [WidgetSnapshot.MetricGlance.TrendPoint]
    ) -> [(x: Double, y: Double)] {
        let points = trend.filter(\.value.isFinite)
        guard points.count >= 2,
              let lo = points.map(\.value).min(),
              let hi = points.map(\.value).max() else { return [] }
        let span = hi - lo
        let t0 = points[0].date.timeIntervalSinceReferenceDate
        let tSpan = points[points.count - 1].date.timeIntervalSinceReferenceDate - t0
        return points.enumerated().map { index, point in
            let x = tSpan > 0
                ? (point.date.timeIntervalSinceReferenceDate - t0) / tSpan
                : Double(index) / Double(points.count - 1)
            let y = span > 0 ? (point.value - lo) / span : 0.5
            return (x, y)
        }
    }
}

public extension WidgetSnapshot.MetricGlance {
    /// Newest kinds first, capped, one glance per named non-cumulative kind.
    /// Cumulative kinds (steps and the other per-day totals) are left out: the
    /// recent page holds single samples of them, and a sample is not the day.
    static func makeAll(
        from recent: [Measurement],
        units: UnitPreferences = .standard,
        calendar: Calendar = .current,
        maxKinds: Int = 40,
        maxPoints: Int = 14
    ) -> [WidgetSnapshot.MetricGlance] {
        let named = recent.filter { !$0.kind.isUnknown && !$0.kind.isCumulative && $0.primaryValue.isFinite }
        let byKind = Dictionary(grouping: named, by: \.kind)
        let newestFirst = byKind.values
            .compactMap { rows -> [Measurement]? in
                rows.isEmpty ? nil : rows.sorted { $0.recordedAt > $1.recordedAt }
            }
            .sorted { $0[0].recordedAt > $1[0].recordedAt }
        return newestFirst.prefix(maxKinds).compactMap { rows in
            guard let latest = WidgetSnapshot.LatestMeasurement.make(from: rows[0], units: units) else { return nil }
            return WidgetSnapshot.MetricGlance(
                kindRaw: latest.kindRaw,
                title: latest.title,
                symbol: latest.symbol,
                formattedValue: latest.formattedValue,
                unit: latest.unit,
                recordedAt: latest.recordedAt,
                trend: dailyTrend(rows, calendar: calendar, maxPoints: maxPoints)
            )
        }
    }

    /// The last reading of each day, oldest first, at most `maxPoints` days.
    /// `rows` arrive newest first.
    private static func dailyTrend(
        _ rows: [Measurement],
        calendar: Calendar,
        maxPoints: Int
    ) -> [TrendPoint] {
        var seen = Set<Date>()
        var points: [TrendPoint] = []
        for row in rows {
            let day = calendar.startOfDay(for: row.recordedAt)
            guard seen.insert(day).inserted else { continue }
            points.append(TrendPoint(date: row.recordedAt, value: row.primaryValue))
            if points.count == maxPoints { break }
        }
        return points.reversed()
    }
}

public extension WidgetSnapshot.MetricGlance {
    /// The kinds that lost a reading between two loads of the newest page.
    ///
    /// A row that vanished was deleted unless it merely rolled off the end of a
    /// full page: those are older than everything still on the page. A deleted
    /// reading must not stay behind in a stored glance, so the caller drops the
    /// glance of every kind named here before it merges.
    static func deletedKinds(
        previous: [Measurement],
        current: [Measurement],
        pageLimit: Int = 400
    ) -> Set<String> {
        let currentIds = Set(current.map(\.id))
        let oldestShown = current.count >= pageLimit ? current.map(\.recordedAt).min() : nil
        return Set(previous.lazy.filter { row in
            guard !currentIds.contains(row.id) else { return false }
            guard let oldestShown else { return true }
            return row.recordedAt >= oldestShown
        }.map(\.kind.rawValue))
    }

    /// Folds the glances of a freshly loaded page into the ones already stored.
    ///
    /// The app only ever holds the newest page of readings (400 rows). On an
    /// account with many samples of one kind, a rarer kind such as weight is not
    /// on that page, and replacing the stored glances would drop it from the
    /// choice list and blank a widget showing it. So a page that may be cut off
    /// only replaces the kinds it contains and keeps the stored glance of every
    /// other kind. A complete page is the whole truth: a kind it lacks has no
    /// readings left and goes away. For a kind on both sides the trend days are
    /// united, the page's reading winning for a day both know.
    static func merged(
        stored: [WidgetSnapshot.MetricGlance],
        fresh: [WidgetSnapshot.MetricGlance],
        pageMayBeTruncated: Bool,
        discarding: Set<String> = [],
        calendar: Calendar = .current,
        maxKinds: Int = 40,
        maxPoints: Int = 14
    ) -> [WidgetSnapshot.MetricGlance] {
        guard pageMayBeTruncated else { return Array(fresh.prefix(maxKinds)) }
        let stored = stored.filter { !discarding.contains($0.kindRaw) }
        var result = fresh.map { glance -> WidgetSnapshot.MetricGlance in
            guard let old = stored.first(where: { $0.kindRaw == glance.kindRaw }) else { return glance }
            var byDay: [Date: TrendPoint] = [:]
            for point in old.trend + glance.trend {
                byDay[calendar.startOfDay(for: point.date)] = point
            }
            let united = byDay.values.sorted { $0.date < $1.date }.suffix(maxPoints)
            return WidgetSnapshot.MetricGlance(
                kindRaw: glance.kindRaw, title: glance.title, symbol: glance.symbol,
                formattedValue: glance.formattedValue, unit: glance.unit,
                recordedAt: glance.recordedAt, trend: Array(united)
            )
        }
        let freshKinds = Set(fresh.map(\.kindRaw))
        result += stored.filter { !freshKinds.contains($0.kindRaw) }
        return Array(result.sorted { $0.recordedAt > $1.recordedAt }.prefix(maxKinds))
    }
}
