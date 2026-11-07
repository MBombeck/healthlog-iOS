import Foundation
@testable import HealthLog
import Testing

/// **1.5 VERDICTS (#135 rest, #151)** — no arrow and no colour claims
/// what the server did not say.
///
/// Fixture shapes follow `docs/api/openapi.yaml` at `v1.47.0`: `TargetItem`
/// (`direction`, `trendSentiment`), the snapshot's `tiles.directions`,
/// `SeriesChange` on `GET /api/measurements/series`, and the `TrendSlope`
/// objects that answer `null` since v1.46 when a window has too few days.
@Suite("1.5 VERDICTS — trend colours from the server")
struct TrendVerdictSourcesTests {
    // MARK: - Fixtures

    private static func card(
        _ kind: MetricKind,
        trend: TrendIndicator,
        sentiment: TrendSentiment? = nil
    ) -> DashboardMetric {
        DashboardMetric(
            id: kind.rawValue, kind: kind, title: "t", latestValue: 1, secondaryValue: nil, unit: "",
            trend: trend, sparkline: [], updatedAt: nil, trendSentiment: sentiment
        )
    }

    private static func targetJSON(type: String, verdict: String?) -> String {
        let extra = verdict.map { #","direction":\#($0),"trendSentiment":"negative""# } ?? ""
        return #"""
        {"type":"\#(type)","label":"x","current":126,"average30":124,"trend":"up","unit":"mmHg",
         "range":{"min":100,"max":120},"classification":null,"source":"personal",
         "daysInRange7d":2,"daysLogged7d":7,"daysInRange30d":11,"daysLogged30d":30,
         "lastMetGoalAt":null,"streakDays":0,"insufficientData":false,"consistency7d":["in",null,"out"]\#(extra)}
        """#
    }

    private static func targets(_ rows: [String]) throws -> InsightsTargetsResponseDTO {
        let json = #"{"targets":[\#(rows.joined(separator: ","))],"pageSummary":{"targetsMetThisWeek":0,"totalTargets":1,"streakHighlight":null},"bpDiastolic":null,"profile":null}"#
        return try JSONDecoder.hlDefault.decode(InsightsTargetsResponseDTO.self, from: Data(json.utf8))
    }

    private static func snapshot(_ tiles: String?) throws -> DashboardSnapshotBriefing {
        let json = tiles.map { #"{"briefingState":"ready","tiles":\#($0)}"# } ?? #"{"briefingState":"ready"}"#
        return try JSONDecoder.hlDefault.decode(DashboardSnapshotBriefing.self, from: Data(json.utf8))
    }

    private static let above = #"{"direction":"up-bad","targetPosition":"above","basis":"personal_target"}"#
    private static let below = #"{"direction":"up-good","targetPosition":"below","basis":"personal_target"}"#

    // MARK: - Contract: TargetItem

    @Test("TargetItem decodes direction and trendSentiment (server with the field)")
    func targetWithVerdict() throws {
        let decoded = try Self.targets([Self.targetJSON(type: "BLOOD_PRESSURE", verdict: Self.above)])
        let item = try #require(decoded.targets.first)
        #expect(item.direction == TrendVerdict(direction: .upBad, targetPosition: .above, basis: .personalTarget))
        #expect(item.trendSentiment == .negative)
        #expect(item.consistency7d == [.inBand, nil, .outBand])
    }

    @Test("TargetItem from a server without the fields, with null, and with a block it cannot read")
    func targetWithoutVerdict() throws {
        let older = try #require(Self.targets([Self.targetJSON(type: "WEIGHT", verdict: nil)]).targets.first)
        #expect(older.direction == nil)
        #expect(older.trendSentiment == nil)
        let nulled = try #require(Self.targets([Self.targetJSON(type: "WEIGHT", verdict: "null")]).targets.first)
        #expect(nulled.direction == nil)
        let broken = try #require(Self.targets([Self.targetJSON(type: "WEIGHT", verdict: "42")]).targets.first)
        #expect(broken.direction == nil)
        #expect(broken.label == "x")
        let unknown = try #require(Self.targets([Self.targetJSON(
            type: "WEIGHT", verdict: #"{"direction":"sideways","targetPosition":null,"basis":"oracle"}"#
        )]).targets.first)
        #expect(unknown.direction?.direction == .unknown)
    }

    // MARK: - Contract: tiles.directions

    @Test("tiles.directions decodes per type; a row it cannot read is dropped alone")
    func snapshotDirections() throws {
        let decoded = try Self.snapshot(#"""
        {"weightTrend":{"direction":"hold","targetPosition":"inside"},
         "directions":{"BLOOD_PRESSURE_SYS":\#(Self.above),"ACTIVITY_STEPS":\#(Self.below),"PULSE":7}}
        """#)
        #expect(decoded.directions["BLOOD_PRESSURE_SYS"]?.direction == .upBad)
        #expect(decoded.directions["ACTIVITY_STEPS"]?.direction == .upGood)
        #expect(decoded.directions["PULSE"] == nil)
        #expect(decoded.weightTrend?.direction == .hold)
    }

    @Test("a snapshot without tiles.directions (older server, older cache) has none")
    func snapshotWithoutDirections() throws {
        #expect(try Self.snapshot(nil).directions.isEmpty)
        #expect(try Self.snapshot(#"{"summaries":{}}"#).directions.isEmpty)
        #expect(try Self.snapshot(#"{"directions":"nope"}"#).directions.isEmpty)
    }

    @Test("the SWR round trip keeps tiles.directions")
    func snapshotRoundTrip() throws {
        let decoded = try Self.snapshot(#"{"directions":{"WEIGHT":\#(Self.below)}}"#)
        let again = try JSONDecoder.hlDefault.decode(
            DashboardSnapshotBriefing.self, from: JSONEncoder.hlDefault.encode(decoded)
        )
        #expect(again == decoded)
        #expect(again.directions["WEIGHT"]?.direction == .upGood)
    }

    // MARK: - Tile colour: target, then tiles.directions, then the card, then neutral

    @Test("Acceptance: blood pressure above its own target rising is bad, below it rising is good")
    @MainActor
    func bloodPressureAgainstTarget() throws {
        let rising = Self.card(.bloodPressure, trend: .up)
        let aboveTarget = try TileTrendVerdicts(
            targets: Self.targets([Self.targetJSON(type: "BLOOD_PRESSURE", verdict: Self.above)]), snapshot: nil
        )
        let belowTarget = try TileTrendVerdicts(
            targets: Self.targets([Self.targetJSON(type: "BLOOD_PRESSURE", verdict: Self.below)]), snapshot: nil
        )
        #expect(TrendChip(trend: .up, mode: aboveTarget.mode(for: rising)).colorRole == .statusBad)
        #expect(TrendChip(trend: .up, mode: belowTarget.mode(for: rising)).colorRole == .statusOK)
    }

    @Test("the target outranks tiles.directions, which outranks the card's trendSentiment")
    func order() throws {
        let card = Self.card(.bloodPressure, trend: .up, sentiment: .positive)
        let directions = try Self.snapshot(#"{"directions":{"BLOOD_PRESSURE_SYS":\#(Self.below)}}"#)
        let target = try Self.targets([Self.targetJSON(type: "BLOOD_PRESSURE", verdict: Self.above)])
        #expect(TileTrendVerdicts(targets: target, snapshot: directions).mode(for: card) == .serverSentiment(.upBad))
        #expect(TileTrendVerdicts(targets: nil, snapshot: directions).mode(for: card) == .serverSentiment(.upGood))
        #expect(TileTrendVerdicts(targets: nil, snapshot: nil).mode(for: card) == .serverVerdict(.positive))
        #expect(TileTrendVerdicts.none.mode(for: Self.card(.bloodPressure, trend: .up)) == .neutral)
    }

    @Test("the resting-pulse target row colours the resting tile, never raw pulse")
    func restingPulseTarget() throws {
        let target = try Self.targets([Self.targetJSON(type: "PULSE", verdict: Self.above)])
        let verdicts = TileTrendVerdicts(targets: target, snapshot: nil)
        #expect(verdicts.mode(for: Self.card(.restingHeartRate, trend: .up)) == .serverSentiment(.upBad))
        #expect(verdicts.mode(for: Self.card(.pulse, trend: .up)) == .neutral)
    }

    @Test("an unknown verdict word at any level falls through and colours nothing by itself")
    func unknownFallsThrough() {
        let verdicts = TileTrendVerdicts(
            targets: ["WEIGHT": .unknown], directions: ["WEIGHT": .unknown], weightTrend: .unknown
        )
        #expect(verdicts.mode(for: Self.card(.weight, trend: .up)) == .neutral)
        #expect(verdicts.mode(for: Self.card(.weight, trend: .up, sentiment: .negative)) == .serverVerdict(.negative))
    }

    @Test("rising steps without a verdict are neutral, with tiles.directions up-good they are good")
    @MainActor
    func risingSteps() {
        let steps = Self.card(.steps, trend: .up)
        #expect(TrendChip(trend: .up, mode: TileTrendVerdicts.none.mode(for: steps)).colorRole == .textSecondary)
        let verdicts = TileTrendVerdicts(targets: [:], directions: ["ACTIVITY_STEPS": .upGood], weightTrend: nil)
        #expect(TrendChip(trend: .up, mode: verdicts.mode(for: steps)).colorRole == .statusOK)
    }

    @Test("VoiceOver hears the colour the target paints")
    func spokenFromTarget() {
        let verdicts = TileTrendVerdicts(targets: ["BLOOD_PRESSURE": .upBad], directions: [:], weightTrend: nil)
        let rising = Self.card(.bloodPressure, trend: .up)
        #expect(rising.spokenVerdictSuffix(verdicts) == ", " + String(localized: "trend.verdict.spoken.negative"))
        #expect(rising.spokenVerdictSuffix(.none).isEmpty)
    }

    @Test("the Insights vitals take the same verdicts")
    func vitalsUseVerdicts() {
        let verdicts = TileTrendVerdicts(targets: [:], directions: ["RESTING_HEART_RATE": .upBad], weightTrend: nil)
        let tiles = InsightsVitalsDashboard.tiles(from: [Self.card(.restingHeartRate, trend: .down)], verdicts: verdicts)
        #expect(tiles.first?.mode == .serverSentiment(.upBad))
        #expect(tiles.first?.accessibilityLabel.contains(String(localized: "trend.verdict.spoken.positive")) == true)
    }

    // MARK: - Metric page: series.change

    private static func point(_ value: Double, _ day: Int) -> SeriesPoint {
        SeriesPoint(id: "\(day)", at: Date(timeIntervalSince1970: 1_700_000_000 + Double(day) * 86400), value: value, secondary: nil)
    }

    private static func series(
        change: SeriesChange? = nil,
        direction: TrendVerdict? = nil,
        lines: [SeriesReferenceLine]? = nil
    ) -> MeasurementSeries {
        let points = [point(100, 0), point(100, 1), point(110, 2), point(110, 3)]
        return MeasurementSeries(
            kind: .steps, points: points, stats: SeriesStats(mean: 105, min: 100, max: 110, stdDev: 5, count: 4),
            unit: "", direction: direction, change: change, referenceLines: lines
        )
    }

    @Test("with change: the server's delta and sentiment, nothing recomputed")
    func withChange() throws {
        let change = SeriesChange(from: 6000, to: 8400, delta: 2400, sentiment: .positive)
        let result = try #require(ChartDetailStore.rangeChange(series: Self.series(change: change)))
        #expect(result == RangeChange(delta: 2400, sentiment: .positive, basis: .firstToLastDay))
    }

    @Test("without change on a server that sends verdicts: nothing shown, no own figure")
    func verdictServerWithoutChange() {
        #expect(ChartDetailStore.rangeChange(series: Self.series(direction: TrendVerdict(direction: .upGood))) == nil)
        #expect(ChartDetailStore.rangeChange(series: Self.series(lines: [])) == nil)
    }

    @Test("an older server: the own comparison, neutral")
    func olderServer() throws {
        let result = try #require(ChartDetailStore.rangeChange(series: Self.series()))
        #expect(result.basis == .priorHalf)
        #expect(result.sentiment == nil)
        #expect(result.delta == 10)
        #expect(ChartDetailStore.rangeChange(series: nil) == nil)
    }

    @Test("series.change decodes from the wire, absent and null alike")
    func changeDecodes() throws {
        func decode(_ extra: String) throws -> MeasurementSeries {
            let json = #"{"kind":"weight","unit":"kg","points":[],"stats":{"mean":0,"min":0,"max":0,"stdDev":0,"count":0}\#(extra)}"#
            return try JSONDecoder.hlDefault.decode(MeasurementSeries.self, from: Data(json.utf8))
        }
        let with = try decode(#","change":{"from":73,"to":72.4,"delta":-0.6,"sentiment":"positive"},"direction":null,"referenceLines":[]"#)
        #expect(with.change?.sentiment == .positive)
        #expect(with.carriesServerVerdicts)
        let nulled = try decode(#","change":null,"referenceLines":[]"#)
        #expect(nulled.change == nil)
        #expect(nulled.carriesServerVerdicts)
        let older = try decode("")
        #expect(older.carriesServerVerdicts == false)
    }

    // MARK: - #151: slope null is no trend

    @Test("a null slope or a slope without direction draws no chip; the others keep their order")
    func nullSlopesDrawNothing() throws {
        let json = #"""
        {"count":9,"slope7":null,"slope30":{"slope":null,"direction":null,"confidence":null},
         "slope90":{"slope":0.01,"direction":"up","confidence":0.4}}
        """#
        let summary = try JSONDecoder.hlDefault.decode(MetricSummary.self, from: Data(json.utf8))
        let slopes = ChartDetailStore.trendSlopes(from: summary)
        #expect(slopes.count == 1)
        #expect(slopes.first?.window == .quarter)
        #expect(ChartDetailStore.trendSlopes(from: MetricSummary(slope7: TrendSlope(slope: 0.2))).isEmpty)
    }
}
