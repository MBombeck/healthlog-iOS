import Foundation
@testable import HealthLog
import SwiftUI
import Testing

// swiftlint:disable force_unwrapping

/// #135 (server v1.43, #116 items 3, 4, 5) — direction verdicts, chart
/// reference lines and record benchmarks, decoded and rendered as the server
/// sends them.
///
/// Fixtures follow `docs/api/openapi.yaml` at `MBombeck/HealthLog` tag
/// `v1.43.0` (`2f5c4659f`): `TrendVerdict`, `TrendSentiment`, `SeriesChange`,
/// `SeriesReferenceLine` (`MeasurementSeriesResponse`), `DashboardMetricCard`
/// (`direction`, `trendSentiment`) and `RecordBenchmark` on `PersonalRecord`.
@Suite("#135 — server verdicts, reference lines, benchmarks: decoding")
struct ServerVerdictsDecodingTests {
    private let decoder = JSONDecoder.hlDefault

    private static let glucoseSeriesV143 = """
    { "kind": "glucose", "unit": "mmol/L",
      "points": [
        { "id": "g1", "at": "2026-10-01T08:00:00Z", "value": 5.6, "secondary": null },
        { "id": "g2", "at": "2026-10-08T08:00:00Z", "value": 6.4, "secondary": null }
      ],
      "stats": { "mean": 6.0, "min": 5.6, "max": 6.4, "stdDev": 0.4, "count": 2 },
      "direction": { "direction": "hold", "targetPosition": "inside", "basis": "metric_default" },
      "change": { "from": 5.6, "to": 6.4, "delta": 0.8, "sentiment": "neutral" },
      "referenceLines": [
        { "value": 3.9, "kind": "lower", "source": "clinical", "appliesTo": "value",
          "labelKey": "charts.reference.glucoseLow", "label": "Unterzuckerung" },
        { "value": 10.0, "kind": "upper", "source": "clinical", "appliesTo": "value",
          "labelKey": "charts.reference.glucoseHigh", "label": "Hoher Zucker" }
      ] }
    """

    private static let glucoseSeriesV142 = """
    { "kind": "glucose", "unit": "mmol/L",
      "points": [{ "id": "g1", "at": "2026-10-01T08:00:00Z", "value": 5.6, "secondary": null }],
      "stats": { "mean": 5.6, "min": 5.6, "max": 5.6, "stdDev": 0, "count": 1 } }
    """

    private func series(_ json: String) throws -> MeasurementSeries {
        try decoder.decode(MeasurementSeries.self, from: Data(json.utf8))
    }

    @Test("A v1.43 series carries its verdict, its change and the mmol/L lines at 3.9 and 10.0")
    func seriesV143() throws {
        let decoded = try series(Self.glucoseSeriesV143)
        #expect(decoded.direction == TrendVerdict(direction: .hold, targetPosition: .inside, basis: .metricDefault))
        #expect(decoded.change == SeriesChange(from: 5.6, to: 6.4, delta: 0.8, sentiment: .neutral))
        let lines = try #require(decoded.referenceLines)
        #expect(lines.map(\.value) == [3.9, 10.0])
        #expect(lines.map(\.kind) == [.lower, .upper])
        #expect(lines.allSatisfy { $0.source == .clinical && $0.appliesTo == .value })
        #expect(lines.first?.label == "Unterzuckerung")
    }

    @Test("A v1.42 series has none of the fields: nothing to colour, nothing to draw")
    func seriesV142() throws {
        let decoded = try series(Self.glucoseSeriesV142)
        #expect(decoded.direction == nil)
        #expect(decoded.change == nil)
        #expect(decoded.referenceLines == nil)
    }

    @Test("Unknown words decode to the neutral case; a broken line or verdict never costs the chart")
    func tolerant() throws {
        let decoded = try series("""
        { "kind": "bloodPressure", "unit": "mmHg",
          "points": [{ "id": "b1", "at": "2026-10-01T08:00:00Z", "value": 128, "secondary": 82 }],
          "stats": { "mean": 128, "min": 128, "max": 128, "stdDev": 0, "count": 1 },
          "direction": { "direction": "sideways", "targetPosition": "beyond", "basis": "horoscope" },
          "change": "not an object",
          "referenceLines": [
            { "value": 135, "kind": "upper", "source": "personal", "appliesTo": "value", "labelKey": "k", "label": "Mein Ziel" },
            { "value": "high", "kind": "upper" },
            { "value": 85, "kind": "diagonal", "source": "family", "appliesTo": "tertiary", "labelKey": "k2", "label": "?" }
          ] }
        """)
        #expect(decoded.points.count == 1)
        #expect(decoded.direction?.direction == .unknown)
        #expect(decoded.direction?.targetPosition == .unknown)
        #expect(decoded.direction?.basis == .unknown)
        #expect(decoded.change == nil)
        let lines = try #require(decoded.referenceLines)
        #expect(lines.count == 2, "only the unreadable row is dropped")
        #expect(lines[0].source == .personal)
        #expect(lines[1].kind == .unknown && lines[1].source == .unknown && lines[1].appliesTo == .unknown)
    }

    @Test("An empty list is the server's \"nothing to draw\", kept apart from an older server")
    func emptyLines() throws {
        let decoded = try series("""
        { "kind": "steps", "unit": "steps", "points": [],
          "stats": { "mean": 0, "min": 0, "max": 0, "stdDev": 0, "count": 0 },
          "direction": null, "change": null, "referenceLines": [] }
        """)
        #expect(decoded.referenceLines == [])
        #expect(decoded.direction == nil)
    }

    @Test("The verdict and the lines survive the SWR cache round trip and every point rebuild")
    func roundTripAndRebuild() throws {
        let decoded = try series(Self.glucoseSeriesV143)
        let data = try JSONEncoder.hlDefault.encode(decoded)
        let again = try decoder.decode(MeasurementSeries.self, from: data)
        #expect(again.direction == decoded.direction)
        #expect(again.change == decoded.change)
        #expect(again.referenceLines == decoded.referenceLines)
        let rebuilt = decoded.replacing(points: Array(decoded.points.prefix(1)))
        #expect(rebuilt.points.count == 1)
        #expect(rebuilt.unit == "mmol/L")
        #expect(rebuilt.direction == decoded.direction)
        #expect(rebuilt.referenceLines == decoded.referenceLines)
        #expect(rebuilt.stats.mean == decoded.stats.mean, "the server's stats stay")
    }

    // MARK: - Dashboard cards

    private static func summary(card extra: String) -> String {
        """
        { "greeting": { "salutation": "Hallo", "date": "2026-10-16T08:00:00Z" },
          "compliance": { "scheduledToday": 0, "takenToday": 0 },
          "highlightInsight": null,
          "metrics": [
            { "id": "m1", "kind": "bloodPressure", "titleKey": "dashboard.metric.title.bloodPressure",
              "latestValue": 128, "secondaryValue": 82, "unitKey": "dashboard.metric.unit.mmHg",
              "trend": "up", "sparkline": [120, 124, 128], "updatedAt": "2026-10-16T07:00:00Z"\(extra) }
          ],
          "lastUpdated": "2026-10-16T08:00:00Z" }
        """
    }

    @Test("A v1.43 summary card carries its trend sentiment and direction, and keeps them through the cache")
    func dashboardCardV143() throws {
        let json = Self.summary(card: """
        , "direction": { "direction": "up-bad", "targetPosition": "above", "basis": "personal_target" },
          "trendSentiment": "negative"
        """)
        let decoded = try decoder.decode(DashboardSummary.self, from: Data(json.utf8))
        let card = try #require(decoded.metrics.first)
        #expect(card.trendSentiment == .negative)
        #expect(card.direction == TrendVerdict(direction: .upBad, targetPosition: .above, basis: .personalTarget))
        let again = try decoder.decode(DashboardSummary.self, from: JSONEncoder.hlDefault.encode(decoded))
        #expect(again.metrics.first?.trendSentiment == .negative)
        #expect(again.metrics.first?.direction?.basis == .personalTarget)
    }

    @Test("A v1.42 card has no verdict; an unknown sentiment word stays a card, uncoloured")
    func dashboardCardOlderAndUnknown() throws {
        let old = try decoder.decode(DashboardSummary.self, from: Data(Self.summary(card: "").utf8))
        #expect(old.metrics.first?.trendSentiment == nil)
        #expect(old.metrics.first?.direction == nil)
        let odd = try decoder.decode(
            DashboardSummary.self,
            from: Data(Self.summary(card: #", "trendSentiment": "ecstatic", "direction": 42"#).utf8)
        )
        #expect(odd.metrics.count == 1)
        #expect(odd.metrics.first?.trendSentiment == .unknown)
        #expect(odd.metrics.first?.direction == nil)
    }

    // MARK: - Personal records

    private static func record(benchmark: String?) -> String {
        let field = benchmark.map { #", "benchmark": \#($0)"# } ?? ""
        return """
        [{ "id": "pr1", "userId": "u1", "metricType": "VO2_MAX", "metricSlot": null, "direction": "MAX",
           "value": 41.2, "unit": "ml/kg/min", "achievedAt": "2026-09-30T07:00:00Z",
           "sourceMeasurementId": "m9", "source": "HEALTHKIT", "externalId": null,
           "createdAt": "2026-09-30T07:05:00Z"\(field) }]
        """
    }

    @Test("A record carries the server's benchmark band and citation")
    func recordBenchmark() throws {
        let rows = try decoder.decode([PersonalRecordDTO].self, from: Data(Self.record(benchmark: """
        { "low": 35, "high": 43, "unit": "ml/kg/min", "source": "acsm-11", "sourceLabel": "ACSM, 11. Auflage" }
        """).utf8))
        #expect(rows.first?.benchmark == RecordBenchmark(
            low: 35, high: 43, unit: "ml/kg/min", source: "acsm-11", sourceLabel: "ACSM, 11. Auflage"
        ))
    }

    @Test("No benchmark, null, a broken block or a reversed band: the record stays, without a band")
    func recordWithoutBenchmark() throws {
        for benchmark in [nil, "null", #""wide""#, #"{ "low": 50, "high": 40, "unit": "x", "source": "s", "sourceLabel": "l" }"#] {
            let rows = try decoder.decode([PersonalRecordDTO].self, from: Data(Self.record(benchmark: benchmark).utf8))
            #expect(rows.count == 1)
            #expect(rows.first?.value == 41.2)
            #expect(rows.first?.benchmark == nil, "benchmark \(benchmark ?? "absent")")
        }
    }
}

@Suite("#135 — server verdicts, reference lines, benchmarks: presentation", .serialized, .mockURLSession)
@MainActor
struct ServerVerdictsPresentationTests {
    private func card(
        _ kind: MetricKind,
        trend: TrendIndicator,
        sentiment: TrendSentiment?
    ) -> DashboardMetric {
        DashboardMetric(
            id: kind.rawValue, kind: kind, title: "t", latestValue: 1, secondaryValue: nil, unit: "",
            trend: trend, sparkline: [], updatedAt: nil, trendSentiment: sentiment
        )
    }

    @Test("Acceptance: the same rising week is negative above a personal target and positive below it")
    func bloodPressureAcceptance() {
        // The server judged both; the app only paints what it was told.
        let aboveTarget = card(.bloodPressure, trend: .up, sentiment: .negative)
        let belowTarget = card(.bloodPressure, trend: .up, sentiment: .positive)
        let chipAbove = TrendChip(trend: .up, mode: TileTrendVerdicts.none.mode(for: aboveTarget))
        let chipBelow = TrendChip(trend: .up, mode: TileTrendVerdicts.none.mode(for: belowTarget))
        #expect(chipAbove.colorRole == .statusBad)
        #expect(chipBelow.colorRole == .statusOK)
    }

    @Test("The card's verdict colours when nothing ranks above it; a neutral or unknown one paints nothing")
    func verdictWins() {
        #expect(TileTrendVerdicts.none.mode(for: card(.weight, trend: .down, sentiment: .positive)) == .serverVerdict(.positive))
        #expect(TileTrendVerdicts.none.mode(for: card(.steps, trend: .up, sentiment: .negative)) == .serverVerdict(.negative))
        #expect(TrendChip.colorRole(for: .neutral) == .textSecondary)
        #expect(TrendChip.colorRole(for: .unknown) == .textSecondary)
        #expect(TrendChip(trend: .unknown, mode: .serverVerdict(.positive)).colorRole == .none)
    }

    @Test("An older server without any verdict: every arrow is neutral, weight keeps tiles.weightTrend")
    func olderServerNeutral() {
        let legacyWeight = TileTrendVerdicts(targets: [:], directions: [:], weightTrend: .upBad)
        #expect(legacyWeight.mode(for: card(.weight, trend: .up, sentiment: nil)) == .serverSentiment(.upBad))
        #expect(TileTrendVerdicts.none.mode(for: card(.steps, trend: .up, sentiment: nil)) == .neutral)
        #expect(TileTrendVerdicts.none.mode(for: card(.pulse, trend: .up, sentiment: nil)) == .neutral)
        #expect(TileTrendVerdicts.none.mode(for: card(.pulse, trend: .up, sentiment: .unknown)) == .neutral)
        #expect(card(.pulse, trend: .up, sentiment: nil).spokenVerdictSuffix(.none).isEmpty)
        #expect(card(.pulse, trend: .up, sentiment: nil).spokenTrendWithVerdict(.none) == nil)
    }

    @Test("VoiceOver hears the verdict the colour shows")
    func spokenVerdict() {
        let positive = card(.hrv, trend: .up, sentiment: .positive)
        #expect(positive.spokenVerdictSuffix(.none) == ", " + String(localized: "trend.verdict.spoken.positive"))
        #expect(positive.spokenTrendWithVerdict(.none) == String(localized: "Trend rising") + positive.spokenVerdictSuffix(.none))
        #expect(card(.hrv, trend: .flat, sentiment: .neutral).spokenVerdictSuffix(.none).isEmpty)
        #expect(TrendSentiment.negative.spokenClause != nil)
    }

    @Test("Insights vitals: the verdict colours the chip; an older server keeps label and stays neutral")
    func vitalsTiles() {
        let current = card(.restingHeartRate, trend: .down, sentiment: .positive)
        let older = card(.hrv, trend: .up, sentiment: nil)
        let tiles = InsightsVitalsDashboard.tiles(from: [current, older])
        let rhr = tiles.first { $0.kind == .restingHeartRate }
        let hrv = tiles.first { $0.kind == .hrv }
        #expect(rhr?.mode == .serverVerdict(.positive))
        #expect(rhr?.accessibilityLabel.contains(String(localized: "trend.verdict.spoken.positive")) == true)
        #expect(hrv?.mode == .neutral)
        #expect(hrv?.accessibilityLabel.contains(String(localized: "Trend rising")) == false)
    }

    // MARK: - Range caption

    private func point(_ value: Double, daysAgo: Double) -> SeriesPoint {
        SeriesPoint(
            id: "\(daysAgo)", at: Date(timeIntervalSince1970: 1_700_000_000 - daysAgo * 86400), value: value, secondary: nil
        )
    }

    @Test("The range caption speaks the server's verdict; the own comparison adds nothing")
    func rangeCaption() throws {
        let adverse = try #require(MetricRangeDelta.resolve(.server(delta: 6, unit: "bpm", sentiment: .negative)))
        #expect(adverse.sentiment == .adverse)
        let spoken = MetricRangeDelta.accessibilityText(adverse, priorLabel: "since the first day in range")
        #expect(spoken.hasSuffix(String(localized: "trend.verdict.spoken.negative")))
        let rising = [point(60, daysAgo: 6), point(61, daysAgo: 5), point(66, daysAgo: 1), point(67, daysAgo: 0)]
        let neutral = try #require(MetricRangeDelta.resolve(.ownComparison(rising)))
        #expect(MetricRangeDelta.accessibilityText(neutral, priorLabel: "vs prior week") == "\(neutral.deltaText) vs prior week")
    }

    // MARK: - Reference lines

    private func makeStore(kind: MetricKind) throws -> ChartDetailStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.3.0",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        return try ChartDetailStore(
            kind: kind,
            measurementsRepo: MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true)),
            insightsRepo: MetricInsightsRepository(api: api),
            resolveLocale: { "en" }
        )
    }

    private func series(
        _ kind: MetricKind,
        unit: String,
        direction: TrendVerdict? = nil,
        lines: [SeriesReferenceLine]?
    ) -> MeasurementSeries {
        let points = [point(70, daysAgo: 2), point(72, daysAgo: 1)]
        let stats = SeriesStats(mean: 71, min: 70, max: 72, stdDev: 1, count: 2)
        return MeasurementSeries(kind: kind, points: points, stats: stats, unit: unit, direction: direction, referenceLines: lines)
    }

    @Test("Glucose lines are drawn as sent; a kPa account sees blood pressure lines in kPa")
    func plotReferenceLines() throws {
        let glucose = try makeStore(kind: .glucose)
        glucose.series = series(.glucose, unit: "mmol/L", lines: [
            SeriesReferenceLine(value: 3.9, kind: .lower, source: .clinical, label: "low"),
            SeriesReferenceLine(value: 10.0, kind: .upper, source: .clinical, label: "high")
        ])
        #expect(glucose.plotReferenceLines(units: AccountUnitDisplayTests.imperial).map(\.value) == [3.9, 10.0])

        let pressure = try makeStore(kind: .bloodPressure)
        pressure.series = series(.bloodPressure, unit: "mmHg", lines: [
            SeriesReferenceLine(value: 140, kind: .upper, source: .clinical, label: "Systolic"),
            SeriesReferenceLine(value: 90, kind: .upper, source: .clinical, appliesTo: .secondary, label: "Diastolic")
        ])
        let kpa = UnitPreferences(weight: .kg, bloodPressure: .kPa, glucose: .mgdL, system: .metric)
        let converted = pressure.plotReferenceLines(units: kpa)
        #expect(abs(converted[0].value - 18.665) < 0.01)
        #expect(converted[1].appliesTo == .secondary)
        #expect(pressure.plotReferenceLines(units: AccountUnitDisplayTests.metric).map(\.value) == [140, 90])
    }

    @Test("An older server, an empty list and an unknown kind draw nothing")
    func noLines() throws {
        let store = try makeStore(kind: .glucose)
        store.series = series(.glucose, unit: "mg/dL", lines: nil)
        #expect(store.plotReferenceLines(units: AccountUnitDisplayTests.metric).isEmpty)
        store.series = series(.glucose, unit: "mg/dL", lines: [])
        #expect(store.plotReferenceLines(units: AccountUnitDisplayTests.metric).isEmpty)
        let unknown = try makeStore(kind: .unknown)
        unknown.series = series(.unknown, unit: "", lines: [SeriesReferenceLine(value: 1, kind: .upper, source: .clinical, label: "x")])
        #expect(unknown.plotReferenceLines(units: AccountUnitDisplayTests.metric).isEmpty)
    }

    @Test("Clinical lines dashed, personal lines solid; edges keep the threshold tints; VoiceOver reads value and label")
    func lineStyle() {
        let clinical = ReferenceLineStyle(line: SeriesReferenceLine(value: 180, kind: .upper, source: .clinical, label: "Hoch"))
        let personal = ReferenceLineStyle(line: SeriesReferenceLine(value: 70, kind: .lower, source: .personal, label: "Mein Ziel"))
        let odd = ReferenceLineStyle(line: SeriesReferenceLine(value: 5, kind: .unknown, source: .unknown, label: ""))
        #expect(clinical.isDashed && !personal.isDashed && odd.isDashed)
        #expect(clinical.tintRole == .upper && personal.tintRole == .lower && odd.tintRole == .neutral)
        #expect(clinical.accessibilityLabel == String(localized: "chart.referenceLine.a11y.upper"))
        #expect(personal.accessibilityValue(unit: "mg/dL") == "70 mg/dL, Mein Ziel")
        #expect(odd.accessibilityValue(unit: "") == "5")
    }

    @Test("The y-domain widens to keep every line on screen and is unchanged without lines")
    func domain() {
        let points = [point(100, daysAgo: 1), point(120, daysAgo: 0)]
        let base = MetricChartMath.logDomain(for: points)
        #expect(MetricChartMath.logDomain(for: points, including: []) == base)
        let widened = MetricChartMath.logDomain(for: points, including: [
            SeriesReferenceLine(value: 70, kind: .lower, source: .clinical, label: ""),
            SeriesReferenceLine(value: 180, kind: .upper, source: .clinical, label: "")
        ])
        #expect(widened.lowerBound <= 70 * 0.95 + 1e-9)
        #expect(widened.upperBound >= 180 * 1.05 - 1e-9)
    }

    // MARK: - Record benchmarks

    private func record(
        _ type: String,
        value: Double,
        unit: String,
        benchmark: RecordBenchmark?
    ) -> PersonalRecordDTO {
        PersonalRecordDTO(
            id: "pr-\(type)", userId: "u1", metricType: type, metricSlot: nil, direction: .max, value: value, unit: unit,
            achievedAt: Date(timeIntervalSince1970: 1_790_000_000), sourceMeasurementId: nil, source: "HEALTHKIT",
            externalId: nil, createdAt: Date(timeIntervalSince1970: 1_790_000_000), benchmark: benchmark
        )
    }

    @Test("Acceptance: a VO2 max record shows the server's band, a step record shows none")
    func benchmarkAcceptance() throws {
        let vo2 = record("VO2_MAX", value: 41, unit: "ml/kg/min", benchmark: RecordBenchmark(
            low: 35, high: 43, unit: "ml/kg/min", source: "acsm", sourceLabel: "ACSM"
        ))
        let band = try #require(RecordBenchmarkBand(record: vo2, units: .standard))
        #expect(band.low == 35 && band.high == 43 && band.value == 41)
        #expect(band.region == .inside)
        #expect(band.sourceLabel == "ACSM")
        #expect(band.summary == String(localized: "records.comparison.insideBand"))
        let steps = record("ACTIVITY_STEPS", value: 18000, unit: "steps", benchmark: nil)
        #expect(RecordBenchmarkBand(record: steps, units: .standard) == nil)
    }

    @Test("The band converts with the record; a band in another unit is not drawn")
    func benchmarkUnits() throws {
        let grip = record("GRIP_STRENGTH", value: 40, unit: "kg", benchmark: RecordBenchmark(
            low: 30, high: 45, unit: "kg", source: "s", sourceLabel: "l"
        ))
        let band = try #require(RecordBenchmarkBand(record: grip, units: AccountUnitDisplayTests.imperial))
        #expect(band.unit == grip.displayUnit(AccountUnitDisplayTests.imperial))
        #expect(abs(band.value - grip.displayValue(AccountUnitDisplayTests.imperial)) < 1e-9)
        if band.unit == "lb" {
            #expect(abs(band.low - 66.14) < 0.01)
        }
        let mismatch = record("VO2_MAX", value: 41, unit: "ml/kg/min", benchmark: RecordBenchmark(
            low: 2.4, high: 3.0, unit: "l/min", source: "s", sourceLabel: "l"
        ))
        #expect(RecordBenchmarkBand(record: mismatch, units: .standard) == nil)
    }

    @Test("Position words only: below, inside, above; never better or worse")
    func benchmarkRegion() {
        let below = RecordBenchmarkBand(low: 12, high: 20, value: 10, unit: "", sourceLabel: "")
        let above = RecordBenchmarkBand(low: 12, high: 20, value: 25, unit: "", sourceLabel: "")
        #expect(below.region == .below)
        #expect(above.region == .above)
        #expect(below.summary == String(localized: "records.comparison.belowCentered"))
        #expect(above.summary == String(localized: "records.comparison.aboveCentered"))
        #expect(below.position(of: below.value, width: 100) ?? -1 >= 0)
        #expect(above.position(of: above.value, width: 100) ?? 101 <= 100)
    }

    @Test("One band per kind, only for records that carry a benchmark")
    func comparisonPairs() {
        let withBand = record("VO2_MAX", value: 41, unit: "ml/kg/min", benchmark: RecordBenchmark(
            low: 35, high: 43, unit: "ml/kg/min", source: "s", sourceLabel: "l"
        ))
        let records = [withBand, withBand, record("ACTIVITY_STEPS", value: 1, unit: "steps", benchmark: nil)].enumerated()
            .map { index, dto in
                PersonalRecord(
                    id: "\(index)", base: dto, kind: index < 2 ? .vo2Max : .steps, sparklineValues: [], peakIndex: nil,
                    previousValue: nil, bucket: .month, impressiveness: 0.5
                )
            }
        let pairs = PersonalRecordsScreen.comparisonPairs(records, units: .standard)
        #expect(pairs.count == 1)
        #expect(pairs.first?.record.id == "0")
    }
}
