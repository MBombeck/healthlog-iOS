import Foundation
@testable import HealthLog
import Testing

/// The measurement widget became configurable. The default choice has to leave
/// a widget that was already on the Home Screen exactly as it was, and a picked
/// metric has to show that metric and nothing else.
@Suite("Measurement widget metric selection")
struct WidgetMetricSelectionTests {
    private static let day: TimeInterval = 86400
    private static let now = Date(timeIntervalSince1970: 1_793_950_000)
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        return calendar
    }

    private static func reading(_ kind: String, _ value: String, at date: Date = now) -> WidgetSnapshot.LatestMeasurement {
        WidgetSnapshot.LatestMeasurement(
            kindRaw: kind, title: kind, formattedValue: value, unit: "u", symbol: "scalemass", recordedAt: date
        )
    }

    private static func glance(_ kind: String, _ value: String, days: [Double]) -> WidgetSnapshot.MetricGlance {
        WidgetSnapshot.MetricGlance(
            kindRaw: kind, title: kind, symbol: "heart", formattedValue: value, unit: "u", recordedAt: now,
            trend: days.enumerated().map { index, v in
                .init(date: now.addingTimeInterval(Double(index - days.count) * day), value: v)
            }
        )
    }

    private static func measurement(_ kind: MetricKind, _ value: Double, daysAgo: Double, hour: Double = 0) -> HealthLog.Measurement {
        HealthLog.Measurement(
            id: "\(kind.rawValue)-\(daysAgo)-\(hour)", kind: kind,
            recordedAt: now.addingTimeInterval(-daysAgo * day + hour * 3600), value: .scalar(value)
        )
    }

    // MARK: Update path

    @Test("A snapshot written before the choice existed still decodes and resolves to the same reading")
    func oldSnapshotKeepsItsReading() throws {
        let latest = Self.reading("weight", "72,4")
        let old = WidgetSnapshot(nextDose: nil, compliance: .init(scheduled: 0, taken: 0), latestMeasurement: latest, generatedAt: Self.now)
        // The shape the previous build wrote: no `metricGlances` key at all.
        var object = try #require(JSONSerialization.jsonObject(with: {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(old)
        }()) as? [String: Any])
        object.removeValue(forKey: "metricGlances")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WidgetSnapshot.self, from: data)

        #expect(decoded.metricGlances.isEmpty)
        let resolved = WidgetMetricSelection.resolve(snapshot: decoded, choice: nil)
        #expect(resolved.reading == latest)
        #expect(resolved.followsLatest)
        #expect(resolved.trend.isEmpty)
        #expect(!resolved.drawsTrend)
    }

    @Test("A placed widget has no choice, and no choice and the explicit default are the same")
    func defaultIsNoChoice() {
        let snapshot = WidgetSnapshot(
            nextDose: nil, compliance: .init(scheduled: 0, taken: 0),
            latestMeasurement: Self.reading("pulse", "61"),
            metricGlances: [Self.glance("weight", "72", days: [1, 2, 3])],
            generatedAt: Self.now
        )
        let none = WidgetMetricSelection.resolve(snapshot: snapshot, choice: nil)
        let token = WidgetMetricSelection.resolve(snapshot: snapshot, choice: WidgetMetricSelection.latestToken)
        #expect(none == token)
        #expect(none.reading?.kindRaw == "pulse", "the default is the newest reading, not the first glance")
    }

    @Test("The widget kind a placed instance is stored under did not change")
    func kindIsStable() {
        #expect(WidgetKind.latestMeasurement == "dev.healthlog.app.widgets.latest-measurement")
    }

    @Test("A snapshot with glances survives encode and decode")
    func roundTrip() throws {
        let snapshot = WidgetSnapshot(
            nextDose: nil, compliance: .init(scheduled: 1, taken: 1),
            metricGlances: [Self.glance("weight", "72", days: [1, 2, 3])], generatedAt: Self.now
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WidgetSnapshotStore(url: url)
        try store.write(snapshot)
        #expect(store.read() == snapshot)
    }

    // MARK: Picking

    @Test("A picked metric shows that metric with its trend")
    func pickedMetric() {
        let snapshot = WidgetSnapshot(
            nextDose: nil, compliance: .init(scheduled: 0, taken: 0),
            latestMeasurement: Self.reading("pulse", "61"),
            metricGlances: [Self.glance("pulse", "61", days: [60, 61]), Self.glance("weight", "72", days: [70, 71, 72])],
            generatedAt: Self.now
        )
        let resolved = WidgetMetricSelection.resolve(snapshot: snapshot, choice: "weight")
        #expect(resolved.reading?.formattedValue == "72")
        #expect(resolved.trend.count == 3)
        #expect(!resolved.followsLatest)
        #expect(resolved.drawsTrend)
    }

    @Test("A picked metric without data shows nothing, never another metric")
    func pickedWithoutData() {
        let snapshot = WidgetSnapshot(
            nextDose: nil, compliance: .init(scheduled: 0, taken: 0),
            latestMeasurement: Self.reading("pulse", "61"), generatedAt: Self.now
        )
        let resolved = WidgetMetricSelection.resolve(snapshot: snapshot, choice: "weight")
        #expect(resolved.reading == nil)
        #expect(!resolved.followsLatest)
    }

    @Test("The default draws the trend of the latest kind when one is known")
    func defaultTrend() {
        let snapshot = WidgetSnapshot(
            nextDose: nil, compliance: .init(scheduled: 0, taken: 0),
            latestMeasurement: Self.reading("weight", "72"),
            metricGlances: [Self.glance("weight", "72", days: [70, 71, 72])], generatedAt: Self.now
        )
        let resolved = WidgetMetricSelection.resolve(snapshot: snapshot, choice: nil)
        #expect(resolved.followsLatest)
        #expect(resolved.drawsTrend)
    }

    // MARK: Building the glances

    @Test("One glance per kind, newest kind first, cumulative and unknown kinds left out")
    func buildsGlances() {
        let recent = [
            Self.measurement(.weight, 72, daysAgo: 2),
            Self.measurement(.pulse, 60, daysAgo: 1),
            Self.measurement(.steps, 4000, daysAgo: 0)
        ]
        let glances = WidgetSnapshot.MetricGlance.makeAll(from: recent, calendar: Self.calendar)
        #expect(glances.map(\.kindRaw) == [MetricKind.pulse.rawValue, MetricKind.weight.rawValue])
    }

    @Test("The trend is one point per day, the day's last reading, oldest first")
    func dailyTrend() {
        let recent = [
            Self.measurement(.weight, 70, daysAgo: 3),
            Self.measurement(.weight, 71, daysAgo: 2, hour: 1),
            Self.measurement(.weight, 72, daysAgo: 2, hour: 2),
            Self.measurement(.weight, 73, daysAgo: 0)
        ]
        let glance = WidgetSnapshot.MetricGlance.makeAll(from: recent, calendar: Self.calendar).first
        #expect(glance?.trend.map(\.value) == [70, 72, 73])
        #expect(glance?.trend == glance?.trend.sorted { $0.date < $1.date })
    }

    @Test("The trend is capped to the newest days")
    func trendCap() {
        let recent = (0 ..< 30).map { Self.measurement(.weight, Double(60 + $0), daysAgo: Double(29 - $0)) }
        let glance = WidgetSnapshot.MetricGlance.makeAll(from: recent, calendar: Self.calendar, maxPoints: 14).first
        #expect(glance?.trend.count == 14)
        #expect(glance?.trend.last?.value == 89)
    }

    @Test("The number of offered kinds is capped")
    func kindCap() {
        let kinds: [MetricKind] = [.weight, .pulse, .glucose, .bodyFat, .spo2]
        let recent = kinds.enumerated().map { Self.measurement($1, 1, daysAgo: Double($0)) }
        #expect(WidgetSnapshot.MetricGlance.makeAll(from: recent, calendar: Self.calendar, maxKinds: 3).count == 3)
    }

    @Test("Non-finite readings are not offered")
    func nonFinite() {
        let recent = [Self.measurement(.weight, .nan, daysAgo: 0)]
        #expect(WidgetSnapshot.MetricGlance.makeAll(from: recent, calendar: Self.calendar).isEmpty)
    }

    // MARK: Drawing

    @Test("A flat series sits in the middle, and fewer than two points draw nothing")
    func normalization() {
        let flat = Self.glance("weight", "72", days: [5, 5, 5]).trend
        #expect(WidgetMetricSelection.normalized(flat).allSatisfy { $0.y == 0.5 })
        #expect(WidgetMetricSelection.normalized(Array(flat.prefix(1))).isEmpty)
        #expect(WidgetMetricSelection.normalized([]).isEmpty)
    }

    @Test("A rising series runs from the bottom left to the top right")
    func risingSeries() throws {
        let points = WidgetMetricSelection.normalized(Self.glance("weight", "72", days: [1, 2, 3]).trend)
        #expect(try #require(points.first).y == 0)
        #expect(try #require(points.last).y == 1)
        #expect(try #require(points.first).x == 0)
        #expect(try #require(points.last).x == 1)
    }

    @Test("The trend line takes the tint, so tinted and clear rendering draw it")
    func trendIsAccented() {
        #expect(WidgetTintPolicy.isAccented(.trendLine, in: .latestMeasurement))
    }

    // MARK: Update path with trends already written

    @Test("After the update the app has written glances, a widget on the default still shows what it showed")
    func placedWidgetAfterTheAppWroteGlances() {
        let latest = Self.reading("weight", "72,4")
        let snapshot = WidgetSnapshot(
            nextDose: nil, compliance: .init(scheduled: 0, taken: 0),
            latestMeasurement: latest,
            metricGlances: [Self.glance("weight", "72,4", days: [70, 71, 72])],
            generatedAt: Self.now
        )
        let resolved = WidgetMetricSelection.resolve(snapshot: snapshot, choice: nil)
        #expect(resolved.reading == latest)
        for family in [WidgetMetricSelection.TrendFamily.small, .large, .accessoryRectangular] {
            #expect(!WidgetMetricSelection.drawsTrend(in: family, resolved: resolved), "\(family)")
        }
        // The families added with the choice may draw it.
        #expect(WidgetMetricSelection.drawsTrend(in: .medium, resolved: resolved))
        #expect(WidgetMetricSelection.drawsTrend(in: .extraLarge, resolved: resolved))
    }

    @Test("A picked metric draws its trend where there is room, never in circular and inline")
    func pickedMetricFamilies() {
        let snapshot = WidgetSnapshot(
            nextDose: nil, compliance: .init(scheduled: 0, taken: 0),
            metricGlances: [Self.glance("weight", "72", days: [70, 71, 72])], generatedAt: Self.now
        )
        let resolved = WidgetMetricSelection.resolve(snapshot: snapshot, choice: "weight")
        for family in [WidgetMetricSelection.TrendFamily.small, .medium, .large, .extraLarge, .accessoryRectangular] {
            #expect(WidgetMetricSelection.drawsTrend(in: family, resolved: resolved), "\(family)")
        }
        #expect(!WidgetMetricSelection.drawsTrend(in: .accessoryCircular, resolved: resolved))
        #expect(!WidgetMetricSelection.drawsTrend(in: .accessoryInline, resolved: resolved))
    }

    // MARK: Rare kinds beyond the newest page

    @Test("A full page of pulse readings keeps the stored weight glance")
    func fullPageKeepsRareKind() {
        let stored = [Self.glance(MetricKind.weight.rawValue, "72", days: [70, 71, 72])]
        let page = (0 ..< 400).map { Self.measurement(.pulse, 60 + Double($0 % 7), daysAgo: 0, hour: -Double($0) / 100) }
        let fresh = WidgetSnapshot.MetricGlance.makeAll(from: page, calendar: Self.calendar)
        #expect(fresh.map(\.kindRaw) == [MetricKind.pulse.rawValue])

        let merged = WidgetSnapshot.MetricGlance.merged(
            stored: stored, fresh: fresh, pageMayBeTruncated: true, calendar: Self.calendar
        )
        #expect(Set(merged.map(\.kindRaw)) == [MetricKind.pulse.rawValue, MetricKind.weight.rawValue])

        let snapshot = WidgetSnapshot(
            nextDose: nil, compliance: .init(scheduled: 0, taken: 0), metricGlances: merged, generatedAt: Self.now
        )
        #expect(WidgetMetricSelection.resolve(snapshot: snapshot, choice: MetricKind.weight.rawValue).reading?.formattedValue == "72")
    }

    @Test("A complete page is the whole truth, so a kind it lacks goes away")
    func completePageDropsMissingKind() {
        let stored = [Self.glance("weight", "72", days: [70, 71])]
        let merged = WidgetSnapshot.MetricGlance.merged(stored: stored, fresh: [], pageMayBeTruncated: false)
        #expect(merged.isEmpty)
    }

    @Test("A kind on both sides keeps its older days and takes the page's newer ones")
    func mergedTrendUnitesDays() {
        let old = Self.glance("weight", "70", days: [1, 2, 3])
        let new = WidgetSnapshot.MetricGlance(
            kindRaw: "weight", title: "weight", symbol: "heart", formattedValue: "80", unit: "u", recordedAt: Self.now,
            trend: [.init(date: Self.now, value: 9)]
        )
        let merged = WidgetSnapshot.MetricGlance.merged(
            stored: [old], fresh: [new], pageMayBeTruncated: true, calendar: Self.calendar
        )
        #expect(merged.count == 1)
        #expect(merged[0].formattedValue == "80")
        #expect(merged[0].trend.count == 4)
        #expect(merged[0].trend.last?.value == 9)
    }

    // MARK: Monotone curve

    private static func bezier(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double, _ t: Double) -> Double {
        let u = 1 - t
        return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
    }

    @Test("The curve never leaves the range of the two readings it connects", arguments: [
        [73.4, 73.1, 73.2, 72.9, 72.8, 72.6, 72.7, 72.5, 72.4],
        [1, 1, 1, 9, 9, 1, 1],
        [0, 10, 0, 10, 0],
        [5, 5, 5, 5],
        [1, 2, 3, 100, 101],
    ] as [[Double]])
    func curveStaysBetweenNeighbours(values: [Double]) {
        let points = values.enumerated().map { (x: Double($0.offset) / Double(values.count - 1), y: $0.element) }
        let segments = WidgetMetricSelection.monotoneSegments(points)
        #expect(segments.count == values.count - 1)
        for (index, segment) in segments.enumerated() {
            let start = points[index]
            let lo = min(start.y, segment.end.y)
            let hi = max(start.y, segment.end.y)
            for step in 0 ... 40 {
                let y = Self.bezier(start.y, segment.control1.y, segment.control2.y, segment.end.y, Double(step) / 40)
                #expect(y >= lo - 1e-9 && y <= hi + 1e-9, "segment \(index) at \(step): \(y) outside \(lo)...\(hi)")
            }
        }
    }

    @Test("Fewer than two points give no curve, and the curve passes through every point")
    func curveEndpoints() {
        #expect(WidgetMetricSelection.monotoneSegments([]).isEmpty)
        #expect(WidgetMetricSelection.monotoneSegments([(0, 1)]).isEmpty)
        let segments = WidgetMetricSelection.monotoneSegments([(0, 1), (1, 2), (2, 0)])
        #expect(segments.map(\.end.y) == [2, 0])
    }

    // MARK: Deleted readings

    @Test("A reading deleted from the page names its kind")
    func deletionIsDetected() {
        let weight = Self.measurement(.weight, 72, daysAgo: 0)
        let pulse = Self.measurement(.pulse, 60, daysAgo: 1)
        let deleted = WidgetSnapshot.MetricGlance.deletedKinds(previous: [weight, pulse], current: [pulse])
        #expect(deleted == [MetricKind.weight.rawValue])
        #expect(WidgetSnapshot.MetricGlance.deletedKinds(previous: [], current: [weight, pulse]).isEmpty)
    }

    @Test("A reading that only rolled off the end of a full page is not a deletion")
    func rollOffIsNotDeletion() {
        let old = Self.measurement(.weight, 72, daysAgo: 30)
        let page = (0 ..< 3).map { Self.measurement(.pulse, 60, daysAgo: Double($0), hour: 0) }
        #expect(WidgetSnapshot.MetricGlance.deletedKinds(previous: [old] + page, current: page, pageLimit: 3).isEmpty)
        // The same disappearance from a page that is not full is a deletion.
        #expect(WidgetSnapshot.MetricGlance
            .deletedKinds(previous: [old] + page, current: page, pageLimit: 400) == [MetricKind.weight.rawValue])
        // A newer row vanishing from a full page is a deletion.
        let newer = Self.measurement(.weight, 71, daysAgo: -1)
        #expect(WidgetSnapshot.MetricGlance
            .deletedKinds(previous: [newer] + page, current: page, pageLimit: 3) == [MetricKind.weight.rawValue])
    }

    @Test("A deleted kind leaves the stored glances even when the page is full")
    func deletedGlanceIsDropped() {
        let stored = [Self.glance(MetricKind.weight.rawValue, "72", days: [70, 71, 72])]
        let merged = WidgetSnapshot.MetricGlance.merged(
            stored: stored, fresh: [], pageMayBeTruncated: true, discarding: [MetricKind.weight.rawValue]
        )
        #expect(merged.isEmpty)
    }

    @Test("A deleted kind that is still on the page is rebuilt from the page, without the deleted day")
    func deletedGlanceRebuilt() {
        let stored = [Self.glance(MetricKind.weight.rawValue, "99", days: [90, 95, 99])]
        let page = [Self.measurement(.weight, 72, daysAgo: 5), Self.measurement(.weight, 71, daysAgo: 6)]
        let fresh = WidgetSnapshot.MetricGlance.makeAll(from: page, calendar: Self.calendar)
        let merged = WidgetSnapshot.MetricGlance.merged(
            stored: stored, fresh: fresh, pageMayBeTruncated: true,
            discarding: [MetricKind.weight.rawValue], calendar: Self.calendar
        )
        #expect(merged.count == 1)
        #expect(merged[0].trend.map(\.value) == [71, 72])
    }
}
