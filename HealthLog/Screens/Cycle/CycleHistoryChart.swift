import Accessibility
import Charts
import SwiftUI

struct CycleHistoryChartModel: Equatable {
    struct Cycle: Identifiable, Equatable {
        let id: String
        let startDate: String
        let lengthDays: Int
        let periodDays: Int
        let confirmedOvulationDay: Int?
    }

    let cycles: [Cycle]
    let averageLength: Int?

    static func build(cycles: [MenstrualCycleDTO], averageLength: Int?) -> CycleHistoryChartModel {
        let observed = cycles
            .filter { !$0.isPredicted && $0.lengthDays != nil }
            .sorted { $0.startDate > $1.startDate }
            .prefix(12)
            .sorted { $0.startDate < $1.startDate }
            .compactMap { cycle -> Cycle? in
                guard let length = cycle.lengthDays else { return nil }
                let periodDays = cycle.periodEndDate.map {
                    max(0, min(length, CyclePredictionEngine.dayDiff($0, cycle.startDate) + 1))
                } ?? 0
                let ovulationDay: Int? = if cycle.ovulationConfirmed, let day = cycle.ovulationDate {
                    max(1, min(length, CyclePredictionEngine.dayDiff(day, cycle.startDate) + 1))
                } else {
                    nil
                }
                return Cycle(
                    id: cycle.id,
                    startDate: cycle.startDate,
                    lengthDays: length,
                    periodDays: periodDays,
                    confirmedOvulationDay: ovulationDay
                )
            }
        return CycleHistoryChartModel(cycles: observed, averageLength: averageLength)
    }
}

struct CycleHistoryChart: View {
    let cycles: [MenstrualCycleDTO]
    let averageLength: Int?

    private var model: CycleHistoryChartModel {
        CycleHistoryChartModel.build(cycles: cycles, averageLength: averageLength)
    }

    var body: some View {
        HLSettingsCard(icon: "chart.bar.xaxis", title: "cycle.history.title") {
            if model.cycles.isEmpty {
                Text("cycle.history.empty")
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                chart
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(model.cycles) { cycle in
                BarMark(
                    x: .value(String(localized: "cycle.history.axis.cycle"), cycle.startDate),
                    yStart: .value(String(localized: "cycle.history.axis.days"), 0),
                    yEnd: .value(String(localized: "cycle.history.period"), cycle.periodDays)
                )
                .foregroundStyle(HLChartTints.series)
                BarMark(
                    x: .value(String(localized: "cycle.history.axis.cycle"), cycle.startDate),
                    yStart: .value(String(localized: "cycle.history.period"), cycle.periodDays),
                    yEnd: .value(String(localized: "cycle.history.axis.days"), cycle.lengthDays)
                )
                .foregroundStyle(HLChartTints.seriesLow)
                if let ovulationDay = cycle.confirmedOvulationDay {
                    PointMark(
                        x: .value(String(localized: "cycle.history.axis.cycle"), cycle.startDate),
                        y: .value(String(localized: "cycle.history.ovulation.confirmed"), ovulationDay)
                    )
                    .foregroundStyle(HLText.primary)
                    .symbol(.diamond)
                    .symbolSize(55)
                }
            }
            if let average = model.averageLength {
                RuleMark(y: .value(String(localized: "cycle.history.average"), average))
                    .foregroundStyle(HLText.secondary)
                    .lineStyle(StrokeStyle(
                        lineWidth: HLChartGrid.thresholdWidth,
                        dash: HLChartGrid.thresholdDash
                    ))
                    .annotation(position: .top, alignment: .trailing) {
                        Text(String(format: String(localized: "cycle.history.average"), average))
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                    }
            }
        }
        .frame(minHeight: 230)
        .chartYAxisLabel("cycle.history.axis.days")
        .accessibilityChartDescriptor(ChartDescriptor(descriptor: descriptor))
    }

    private var descriptor: AXChartDescriptor {
        let points = model.cycles.enumerated().map { index, cycle in
            (
                x: Double(index),
                y: Double(cycle.lengthDays),
                xLabel: cycle.startDate
            )
        }
        return HLChartAX.singleSeries(
            title: String(localized: "cycle.history.title"),
            summary: String(localized: "cycle.history.accessibility.summary"),
            xAxisTitle: String(localized: "cycle.history.axis.cycle"),
            yAxisTitle: String(localized: "cycle.history.axis.days"),
            seriesName: String(localized: "cycle.history.series"),
            points: points,
            yValueLabel: { value in String(format: String(localized: "cycle.history.days.value"), Int(value)) }
        )
    }
}
