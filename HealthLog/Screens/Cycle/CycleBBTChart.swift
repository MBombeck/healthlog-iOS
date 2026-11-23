import Accessibility
import Charts
import SwiftUI

struct CycleBBTChartModel: Equatable {
    struct Point: Identifiable, Equatable {
        let day: String
        let date: Date
        let value: Double
        let phase: CyclePhaseValue?
        let excluded: Bool
        var id: String {
            day
        }
    }

    struct LineSegment: Identifiable, Equatable {
        let id: Int
        let points: [Point]
    }

    struct Ovulation: Equatable {
        let day: String
        let date: Date
        let confirmed: Bool
    }

    let points: [Point]
    let lineSegments: [LineSegment]
    let ovulation: Ovulation?

    var hasEnoughData: Bool {
        points.count >= 2
    }

    /// The y range the readings need. Without one Swift Charts
    /// starts the axis at 0, so a cycle between 36.4 and 36.9 °C lay flat at
    /// the top of a 0 to 40 °C chart. A quarter of the spread (at least 0.2 in
    /// the plotted unit) above and below, on tenths.
    var yDomain: ClosedRange<Double> {
        let values = points.map(\.value)
        guard let low = values.min(), let high = values.max() else { return 0 ... 1 }
        let pad = max((high - low) * 0.25, 0.2)
        return ((low - pad) * 10).rounded(.down) / 10 ... ((high + pad) * 10).rounded(.up) / 10
    }

    static func build(
        days: [CalendarDayDTO],
        cycles: [MenstrualCycleDTO],
        prediction: CyclePredictionDTO?,
        today: String
    ) -> CycleBBTChartModel {
        let observed = cycles
            .filter { !$0.isPredicted && $0.startDate <= today && ($0.endDate.map { $0 >= today } ?? true) }
            .max { $0.startDate < $1.startDate }
        let from = observed?.startDate ?? CyclePredictionEngine.addDays(today, -34)
        let candidates = days
            .filter { $0.date >= from && $0.date <= today && $0.basalBodyTempC != nil }
            .sorted { $0.date < $1.date }
        let points = candidates.compactMap { day -> Point? in
            guard let value = day.basalBodyTempC, let date = chartDate(day.date) else { return nil }
            return Point(
                day: day.date,
                date: date,
                value: value,
                phase: day.phaseValue,
                excluded: day.temperatureExcluded
            )
        }

        var segments: [LineSegment] = []
        var current: [Point] = []
        for point in points {
            if point.excluded {
                if !current.isEmpty {
                    segments.append(LineSegment(id: segments.count, points: current))
                    current = []
                }
            } else {
                current.append(point)
            }
        }
        if !current.isEmpty {
            segments.append(LineSegment(id: segments.count, points: current))
        }

        let observedOvulation = observed?.ovulationDate.flatMap { day -> Ovulation? in
            guard day >= from, day <= today, let date = chartDate(day) else { return nil }
            return Ovulation(day: day, date: date, confirmed: observed?.ovulationConfirmed == true)
        }
        let predictedOvulation = prediction?.predictedOvulation.flatMap { day -> Ovulation? in
            guard day >= from, day <= today, let date = chartDate(day) else { return nil }
            return Ovulation(day: day, date: date, confirmed: prediction?.ovulationConfirmed == true)
        }
        return CycleBBTChartModel(
            points: points,
            lineSegments: segments,
            ovulation: observedOvulation ?? predictedOvulation
        )
    }

    /// The same chart with every reading mapped through `display`
    /// (°C → the account's unit). Segments, phases and ovulation stay as built.
    func converted(_ display: (Double) -> Double) -> CycleBBTChartModel {
        func map(_ point: Point) -> Point {
            Point(day: point.day, date: point.date, value: display(point.value), phase: point.phase, excluded: point.excluded)
        }
        return CycleBBTChartModel(
            points: points.map(map),
            lineSegments: lineSegments.map { LineSegment(id: $0.id, points: $0.points.map(map)) },
            ovulation: ovulation
        )
    }

    private static func chartDate(_ key: String) -> Date? {
        guard let milliseconds = CyclePredictionEngine.parseDayMs(key) else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}

struct CycleBBTChart: View {
    @Environment(\.colorScheme) private var colorScheme
    /// The basal temperature reads in the account's unit (°F on an
    /// imperial account); the logged value stays canonical °C.
    @Environment(\.unitPreferences) private var units
    let days: [CalendarDayDTO]
    let cycles: [MenstrualCycleDTO]
    let prediction: CyclePredictionDTO?
    let rawMode: Bool
    let today: String
    /// The day under the finger while the chart is scrubbed.
    @State private var selectedDate: Date?

    /// Built canonical (°C), plotted in the account's unit.
    private var model: CycleBBTChartModel {
        CycleBBTChartModel.build(days: days, cycles: cycles, prediction: prediction, today: today)
            .converted { [units] in units.displayValue($0, kind: .bodyTemperature) }
    }

    var body: some View {
        // Fewer than two readings in this cycle: no card, rather than
        // one saying two are needed.
        if model.hasEnoughData {
            HLSectionHeader("cycle.bbt.title", rank: .area)
            HLCard {
                chart
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(model.lineSegments) { segment in
                ForEach(segment.points) { point in
                    LineMark(
                        x: .value(String(localized: "cycle.bbt.axis.date"), point.date),
                        y: .value(String(localized: "cycle.bbt.axis.temperature"), point.value),
                        series: .value("segment", segment.id)
                    )
                    .foregroundStyle(HLChartTints.series)
                    .lineStyle(StrokeStyle(lineWidth: HLChartStyle.lineWidth))
                }
            }
            ForEach(model.points) { point in
                PointMark(
                    x: .value(String(localized: "cycle.bbt.axis.date"), point.date),
                    y: .value(String(localized: "cycle.bbt.axis.temperature"), point.value)
                )
                .foregroundStyle(pointColor(point))
                .symbol(point.excluded ? .cross : .circle)
                .symbolSize(point.excluded ? 70 : 42)
            }
            if !rawMode, let ovulation = model.ovulation {
                RuleMark(x: .value(String(localized: "cycle.bbt.ovulation"), ovulation.date))
                    .foregroundStyle(HLText.secondary)
                    .lineStyle(StrokeStyle(
                        lineWidth: HLChartGrid.thresholdWidth,
                        dash: ovulation.confirmed ? [] : HLChartGrid.thresholdDash
                    ))
                    .annotation(position: .top, alignment: .leading) {
                        Text(ovulation.confirmed ? "cycle.bbt.ovulation.confirmed" : "cycle.bbt.ovulation.estimated")
                            .hlText(.chartMark)
                    }
            }
            HLChartScrubber.marks(selectedDate: selectedDate, in: model.points, date: \.date, value: \.value) { point in
                HLScrubCallout(title: HLDateFormat.dayMonth(point.date), value: valueText(point.value), unit: unitText)
            }
        }
        .frame(height: HLChartStyle.heightRegular)
        .chartYScale(domain: model.yDomain)
        .hlChartAxes(dates: model.points.map(\.date), unit: unitText)
        .hlChartScrub($selectedDate) { [model, units] date in
            Self.announcement(for: date, in: model.points, units: units)
        }
        .accessibilityChartDescriptor(ChartDescriptor(descriptor: descriptor))
    }

    /// "°C" from the catalogue on a metric account, else the account's label.
    private var unitText: String {
        Self.unitText(units: units)
    }

    static func unitText(units: UnitPreferences) -> String {
        units.transform(for: .bodyTemperature).suffix ?? String(localized: "cycle.bbt.axis.celsius")
    }

    /// A reading as the callout shows it: two decimals, as logged.
    private func valueText(_ value: Double) -> String {
        HLValueFormat.number(value, fractionDigits: 2 ... 2)
    }

    /// What VoiceOver says for the reading nearest to the scrubbed day.
    static func announcement(
        for date: Date,
        in points: [CycleBBTChartModel.Point],
        units: UnitPreferences
    ) -> String? {
        guard let point = HLChartScrubber.nearest(to: date, in: points, date: \.date) else { return nil }
        let value = HLValueFormat.number(point.value, fractionDigits: 2 ... 2)
        return "\(HLDateFormat.dayMonth(point.date)), \(value) \(unitText(units: units))"
    }

    private func pointColor(_ point: CycleBBTChartModel.Point) -> Color {
        if point.excluded { return HLText.tertiary }
        guard !rawMode, let phase = point.phase else { return HLChartTints.seriesMid }
        return CyclePhasePalette.tint(for: palettePhase(phase), scheme: colorScheme)
    }

    private func palettePhase(_ phase: CyclePhaseValue) -> CyclePhasePalette.Phase {
        switch phase {
        case .menstrual: .menstrual
        case .follicular: .follicular
        case .ovulatory: .ovulatory
        case .luteal: .luteal
        }
    }

    private var descriptor: AXChartDescriptor {
        let points = model.points.enumerated().map { index, point in
            (
                x: Double(index),
                y: point.value,
                xLabel: HLDateFormat.dayMonth(point.date, relativeTo: point.date)
            )
        }
        return HLChartAX.singleSeries(
            title: String(localized: "cycle.bbt.title"),
            summary: String(localized: "cycle.bbt.accessibility.summary"),
            xAxisTitle: String(localized: "cycle.bbt.axis.date"),
            yAxisTitle: String(localized: "cycle.bbt.axis.temperature"),
            seriesName: String(localized: "cycle.bbt.series"),
            points: points,
            yValueLabel: { [units] value in
                guard let suffix = units.transform(for: .bodyTemperature).suffix else {
                    return String(format: String(localized: "cycle.bbt.value"), value)
                }
                return "\(HLValueFormat.number(value, fractionDigits: 2 ... 2)) \(suffix)"
            }
        )
    }
}
