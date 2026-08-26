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

    private static func chartDate(_ key: String) -> Date? {
        guard let milliseconds = CyclePredictionEngine.parseDayMs(key) else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}

struct CycleBBTChart: View {
    @Environment(\.colorScheme) private var colorScheme
    let days: [CalendarDayDTO]
    let cycles: [MenstrualCycleDTO]
    let prediction: CyclePredictionDTO?
    let rawMode: Bool
    let today: String

    private var model: CycleBBTChartModel {
        CycleBBTChartModel.build(days: days, cycles: cycles, prediction: prediction, today: today)
    }

    var body: some View {
        HLSettingsCard(icon: "chart.xyaxis.line", title: "cycle.bbt.title") {
            if model.hasEnoughData {
                chart
            } else {
                Text("cycle.bbt.empty")
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                    .foregroundStyle(HLChartTints.seriesMid)
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
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                    }
            }
        }
        .frame(minHeight: 220)
        .chartYAxisLabel("cycle.bbt.axis.celsius")
        .accessibilityChartDescriptor(ChartDescriptor(descriptor: descriptor))
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
                xLabel: point.date.formatted(.dateTime.day().month(.abbreviated))
            )
        }
        return HLChartAX.singleSeries(
            title: String(localized: "cycle.bbt.title"),
            summary: String(localized: "cycle.bbt.accessibility.summary"),
            xAxisTitle: String(localized: "cycle.bbt.axis.date"),
            yAxisTitle: String(localized: "cycle.bbt.axis.temperature"),
            seriesName: String(localized: "cycle.bbt.series"),
            points: points,
            yValueLabel: { value in String(format: String(localized: "cycle.bbt.value"), value) }
        )
    }
}
