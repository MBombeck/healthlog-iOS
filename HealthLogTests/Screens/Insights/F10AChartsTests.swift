import CoreGraphics
import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// The statistics table under a metric chart: a name column only for named
/// rows (a pressure), the unit after each value otherwise, names never cut.
@MainActor
@Suite("F10A statistics table")
struct F10AStatsTableTests {
    private static func cells(_ unit: String?) -> [HLStatCell] {
        [
            HLStatCell(label: "Min", value: "61", unit: unit),
            HLStatCell(label: "Ø", value: "64", unit: unit)
        ]
    }

    @Test("a pressure keeps its name column, the unit heads the names")
    func namedRows() {
        let rows = [
            MetricStatsTable.Row(title: "Systolisch", cells: Self.cells("mmHg")),
            MetricStatsTable.Row(title: "Diastolisch", cells: Self.cells("mmHg"))
        ]
        #expect(MetricStatsTable.showsNameColumn(rows))
        #expect(MetricStatsTable.valueUnit(rows) == nil)
        #expect(MetricStatsTable.unit(rows) == "mmHg")
    }

    @Test("the one series of a page has no name column, the unit stands after each value")
    func singleSeries() {
        let rows = [MetricStatsTable.Row(title: "", cells: Self.cells("bpm"))]
        #expect(!MetricStatsTable.showsNameColumn(rows))
        #expect(MetricStatsTable.valueUnit(rows) == "bpm")
    }

    @Test("a series without a unit shows bare values")
    func noUnit() {
        let rows = [MetricStatsTable.Row(title: "", cells: Self.cells(""))]
        #expect(!MetricStatsTable.showsNameColumn(rows))
        #expect(MetricStatsTable.valueUnit(rows) == nil)
    }

    @Test("a stacked value is read on one line")
    func spokenDuration() {
        let row = MetricStatsTable.Row(title: "", cells: [HLStatCell(label: "Min", value: "6 Std.\n47 Min.", unit: "")])
        #expect(MetricStatsTable.spoken(row) == "Min 6 Std. 47 Min.")
        #expect(MetricStatsTable.oneLine("7 h\n13 min") == "7 h 13 min")
    }

    @Test("a scale names itself at the main value only")
    func scaleUnit() {
        #expect(MetricDurationFormat.isScale(.dayStrain))
        #expect(!MetricDurationFormat.isScale(.pulse))
        #expect(MetricDurationFormat.cellUnit("von 21", kind: .dayStrain).isEmpty)
        #expect(MetricDurationFormat.axisUnit("von 21", kind: .dayStrain).isEmpty)
        #expect(MetricDurationFormat.cellUnit("bpm", kind: .pulse) == "bpm")
        #expect(MetricDurationFormat.axisUnit("bpm", kind: .pulse) == "bpm")
    }
}

/// One way to write a length of time on the sleep page: the cell uses the
/// head's words, stacked hours over minutes.
@MainActor
@Suite("F10A duration format")
struct F10ADurationFormatTests {
    private static let german = Locale(identifier: "de_DE")

    @Test("a cell is the head's text, one part per line")
    func cellMatchesHead() {
        for hours in [7.2167, 6.1, 8.0, 0.5] {
            let cell = MetricDurationFormat.cell(hours: hours, locale: Self.german)
            let head = MetricDurationFormat.text(hours: hours, locale: Self.german)
            #expect(cell.replacingOccurrences(of: "\n", with: " ") == head)
        }
        #expect(MetricDurationFormat.cell(hours: 8, locale: Self.german).contains("\n") == false)
        #expect(MetricDurationFormat.cell(hours: 7.2167, locale: Self.german).split(separator: "\n").count == 2)
    }

    @Test("the parts join to the duration text")
    func partsJoin() {
        let parts = HLTimeFormat.durationParts(7 * 3600 + 13 * 60, locale: Self.german)
        #expect(parts.count == 2)
        #expect(parts.joined(separator: " ") == HLTimeFormat.duration(7 * 3600 + 13 * 60, locale: Self.german))
    }
}

/// The value axis ends on a grid step at both ends, so no gap opens between
/// the unit and the top tick.
@MainActor
@Suite("F10A value axis ends")
struct F10AValueAxisTests {
    private static func isOnStep(_ value: Double, _ step: Double) -> Bool {
        abs((value / step).rounded() * step - value) < 1e-9
    }

    @Test("a calm heart rate stands on a widened axis with ticks at both ends")
    func heartRate() {
        let domain = MetricChartScale.widened(60 ... 68, toSpan: 20)
        let step = MetricChartScale.gridStep(span: 20, magnitude: domain.upperBound)
        #expect(domain.upperBound - domain.lowerBound >= 20)
        #expect(domain.lowerBound <= 60 && domain.upperBound >= 68)
        #expect(Self.isOnStep(domain.lowerBound, step))
        #expect(Self.isOnStep(domain.upperBound, step))
    }

    @Test("snapping widens to the next steps and keeps zero and 100")
    func snapping() {
        #expect(MetricChartScale.snapped(54 ... 74, step: 5) == 50 ... 75)
        #expect(MetricChartScale.snapped(0.5 ... 3, step: 1) == 0 ... 3)
        #expect(MetricChartScale.snapped(92.5 ... 100, step: 5, capsAtHundred: true) == 90 ... 100)
        #expect(MetricChartScale.snapped(10 ... 20, step: 0) == 10 ... 20)
    }

    @Test("the old guarantees hold")
    func oldGuarantees() {
        let weight = MetricChartScale.widened(72 ... 74, toSpan: 4)
        #expect(weight.upperBound - weight.lowerBound >= 4)
        let oxygen = MetricChartScale.widened(96 ... 99, toSpan: 10, capsAtHundred: true)
        #expect(oxygen == 90 ... 100)
        #expect(MetricChartScale.widened(60 ... 120, toSpan: 20) == 60 ... 120)
    }
}

/// The line under a chart: what it is narrowed to, else the comparison, else
/// an empty line of the same height, so every chart card has one height.
@MainActor
@Suite("F10A chart card foot line")
struct F10AChartFootLineTests {
    private static let delta = MetricRangeDelta(
        source: .server(delta: 1.5, unit: "kg", sentiment: .neutral),
        range: .month
    )

    @Test("a caption wins over the comparison")
    func caption() {
        guard case let .caption(text) = ChartCardFootLine.resolve(caption: "Morgens", delta: Self.delta) else {
            Issue.record("expected the caption")
            return
        }
        #expect(text == "Morgens")
    }

    @Test("a comparison with a figure shows")
    func delta() {
        guard case .delta = ChartCardFootLine.resolve(caption: nil, delta: Self.delta) else {
            Issue.record("expected the comparison")
            return
        }
    }

    @Test("without a comparison the line stays, empty")
    func reserved() {
        #expect(ChartCardFootLine.resolve(caption: nil, delta: nil).isReserved)
        let none = MetricRangeDelta(source: .ownComparison([]), range: .month)
        #expect(ChartCardFootLine.resolve(caption: nil, delta: none).isReserved)
        #expect(!ChartCardFootLine.resolve(caption: nil, delta: Self.delta).isReserved)
    }
}

/// The score tiles: on the phone the fifth tile takes the whole row; on the
/// iPad no tile stands alone and none is under 128 pt.
@MainActor
@Suite("F10A score grid lone tile")
struct F10AScoreGridTests {
    nonisolated static let widths: [CGFloat] = [320, 440, 466, 540, 669, 744, 834, 1032, 1133, 1376]

    private static let grid = HLTileGrid(
        minimumTileWidth: HLTileGrid.ringTileMinimumWidth,
        maximumColumns: InsightsScoreCardsBlock.maximumTileColumns,
        evenColumns: true,
        avoidsLoneTile: true,
        spansLoneTile: true
    )

    private static func content(_ window: CGFloat) -> CGFloat {
        min(window - 2 * HLLayout.pageMargin, HLLayout.readableWidth)
    }

    @Test("on the phone the fifth score spans the row")
    func phone() {
        let width = Self.content(402)
        let count = Self.grid.columns(width: width, itemCount: 5)
        #expect(count == 2)
        let lone = Self.grid.tileWidth(width: width, count: count, index: 4, itemCount: 5)
        #expect(lone == Self.grid.rowWidth(width: width, count: count))
        let other = Self.grid.tileWidth(width: width, count: count, index: 3, itemCount: 5)
        #expect(other == Self.grid.tileWidth(width: width, count: count))
    }

    @Test("at every width no tile stands beside a hole and none is under 128 pt", arguments: widths)
    func everyWidth(window: CGFloat) {
        let width = Self.content(window)
        for itemCount in 1 ... 7 {
            let count = Self.grid.columns(width: width, itemCount: itemCount)
            for index in 0 ..< itemCount {
                let tile = Self.grid.tileWidth(width: width, count: count, index: index, itemCount: itemCount)
                #expect(tile >= HLTileGrid.ringTileMinimumWidth || count == 1)
            }
            if HLTileGrid.leavesLoneTile(itemCount: itemCount, columns: count) {
                let lone = Self.grid.tileWidth(width: width, count: count, index: itemCount - 1, itemCount: itemCount)
                #expect(lone == Self.grid.rowWidth(width: width, count: count))
            }
        }
    }

    @Test("a grid without the option keeps the lone tile at column width")
    func withoutOption() {
        let grid = HLTileGrid(minimumTileWidth: 128, maximumColumns: 2, evenColumns: true)
        let width: CGFloat = 370
        #expect(grid.tileWidth(width: width, count: 2, index: 4, itemCount: 5) == grid.tileWidth(width: width, count: 2))
    }

    @Test("the narrowest tile leaves a name 110 pt, enough for the longest one-word score name")
    func labelWidth() {
        let room = HLTileGrid.ringTileMinimumWidth - 2 * HLLayout.cardInset + 2 * ScoreRingTileLabel.insetReach
        #expect(room >= 110)
        #expect(ScoreRingTileLabel.insetReach < HLLayout.cardInset)
    }

    @Test("a one-word name holds one line, a name of several words two")
    func labelRoom() {
        #expect(ScoreRingTileLabel.reservedText(for: "Erholung") == "X")
        #expect(ScoreRingTileLabel.reservedText(for: "Health score") == "X\nX")
    }
}

/// Chart details: mood ticks only where a word stands, a clinical range in
/// neutral edges, the shortened oxygen pill, the timeline's quiet legend.
@MainActor
@Suite("F10A chart details")
struct F10AChartDetailTests {
    @Test("every mood tick carries a word")
    func moodTicks() {
        #expect(MoodTrendChart.axisTicks == [1, 3, 5])
        for tick in MoodTrendChart.axisTicks {
            #expect(!MoodTrendChart.axisLabel(tick).isEmpty)
        }
    }

    @Test("a clinical range draws neutral edges, a personal one keeps its tints")
    func bandTints() {
        let clinical = HLChartReferenceLines.band(lower: 0.85, upper: 1.15, unit: "")
        #expect(!clinical.tintsEdges)
        #expect(clinical.lines.map { HLReferenceLineStyle(line: $0, tintsEdges: clinical.tintsEdges).tintRole } == [.neutral, .neutral])
        let personal = HLChartReferenceLines.band(lower: 70, upper: 74, source: .personal, unit: "kg")
        #expect(personal.tintsEdges)
        #expect(personal.lines.map { HLReferenceLineStyle(line: $0, tintsEdges: personal.tintsEdges).tintRole } == [.lower, .upper])
        let server = HLChartReferenceLines(
            lines: [SeriesReferenceLine(value: 140, kind: .upper, source: .clinical, label: "")],
            unit: "mmHg"
        )
        #expect(server.tintsEdges)
    }

    @Test("the oxygen pill is short, the page keeps its name")
    func oxygenPill() {
        let selection = InsightsTabSelection.metric(.spo2)
        #expect(selection.pillTitle == String(localized: "insights.tabStrip.pill.spo2"))
        #expect(selection.title == MetricKind.spo2.displayName)
        #expect(selection.pillTitle.count < selection.title.count)
        #expect(InsightsTabSelection.metric(.weight).pillTitle == InsightsTabSelection.metric(.weight).title)
    }

    @Test("the timeline legend value keeps one style")
    func timelineLegend() {
        #expect(TimelineValueLabel.valueRole == .rowSubtitle)
    }
}

/// Round 3: ticks on the grid step, a flush strip on wide pages with fades
/// only at cut ends, the shown page in its category pill, a compact mood grid.
@MainActor
@Suite("F10A round three")
struct F10ARoundThreeTests {
    @Test("the tick step puts ticks on both ends of a snapped axis")
    func tickStep() {
        #expect(MetricChartScale.tickStep(for: 50 ... 75) == 5)
        #expect(MetricChartScale.tickStep(for: 60 ... 140) == 20)
        #expect(MetricChartScale.tickStep(for: 71 ... 75) == 1)
        #expect(MetricChartScale.tickStep(for: 0 ... 1) == 0.2)
        #expect(MetricChartScale.tickStep(for: 5 ... 5) == nil)
        for domain in [50.0 ... 75, 60 ... 140, 90 ... 100, 0.5 ... 1.5, 6 ... 16] {
            if let step = MetricChartScale.tickStep(for: domain) {
                #expect((domain.upperBound - domain.lowerBound) / step <= 6 + 1e-9)
            }
        }
    }

    @Test("the axis ticks follow the step, a duration whole hours, the large sizes the system")
    func axisValues() {
        #expect(MetricChartScale.axisValues(domain: 50 ... 75, kind: .pulse, useLog: false, isAccessibilitySize: false) != nil)
        #expect(MetricChartScale.axisValues(domain: 50 ... 75, kind: .pulse, useLog: true, isAccessibilitySize: false) == nil)
        #expect(MetricChartScale.axisValues(domain: 50 ... 75, kind: .pulse, useLog: false, isAccessibilitySize: true) == nil)
        #expect(MetricChartScale.axisValues(domain: 6 ... 9, kind: .sleep, useLog: false, isAccessibilitySize: true) != nil)
    }

    @Test("the strip fades over at least a fade length at a cut end")
    func stripFade() {
        #expect(InsightsStripLayout.fadeLength(contentInset: HLLayout.pageMargin) >= HLEdgeFade.length)
        #expect(InsightsStripLayout.fadeLength(contentInset: 0) >= HLEdgeFade.length)
    }

    @Test("only a cut end fades")
    func cutEnds() {
        #expect(HLEdgeFade.cutEnds(offset: 0, visible: 300, content: 600) == (leading: false, trailing: true))
        #expect(HLEdgeFade.cutEnds(offset: 300, visible: 300, content: 600) == (leading: true, trailing: false))
        #expect(HLEdgeFade.cutEnds(offset: 100, visible: 300, content: 600) == (leading: true, trailing: true))
        #expect(HLEdgeFade.cutEnds(offset: 0, visible: 300, content: 200) == (leading: false, trailing: false))
    }

    @Test("a category pill names the page shown in it, its category otherwise")
    func categoryPill() {
        let members: [InsightsTabSelection] = [.metric(.recoveryScore), .metric(.dayStrain)]
        let shown = InsightsMetricTabStrip.categoryPillTitle(.recovery, selection: .metric(.dayStrain), members: members)
        #expect(shown == InsightsTabSelection.metric(.dayStrain).pillTitle)
        let other = InsightsMetricTabStrip.categoryPillTitle(.recovery, selection: .metric(.weight), members: members)
        #expect(other == InsightsMetricCategory.recovery.label)
        let spoken = InsightsMetricTabStrip.categoryPillAccessibilityLabel(.recovery, selection: .metric(.dayStrain), members: members)
        #expect(spoken.hasPrefix(InsightsMetricCategory.recovery.label))
    }

    @Test("the short mood grid keeps its weeks compact")
    func moodGrid() {
        #expect(MoodHeatmapSection.weekColumnMaxWidth <= 32)
        #expect(MoodHeatmapSection.weekColumnMaxWidth >= 10)
    }
}
