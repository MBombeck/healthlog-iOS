import Accessibility
import Charts
import SwiftUI

struct CycleHistoryChartModel: Equatable {
    struct Cycle: Identifiable, Equatable {
        let id: String
        let startDate: String
        /// 1.4 B4 — what the axis shows under the bar: the start as a date in
        /// words ("13. Mai"), not the day key cut to "2026-05-…".
        let label: String
        let lengthDays: Int
        let periodDays: Int
        let confirmedOvulationDay: Int?
    }

    let cycles: [Cycle]
    let averageLength: Int?

    static func build(cycles: [MenstrualCycleDTO], averageLength: Int?) -> CycleHistoryChartModel {
        let closed = cycles
            .filter { !$0.isPredicted && $0.lengthDays != nil }
            .sorted { $0.startDate > $1.startDate }
            .prefix(12)
            .sorted { $0.startDate < $1.startDate }
        let labels = axisLabels(for: closed.map(\.startDate))
        let observed = zip(closed, labels).compactMap { cycle, label -> Cycle? in
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
                label: label,
                lengthDays: length,
                periodDays: periodDays,
                confirmedOvulationDay: ovulationDay
            )
        }
        return CycleHistoryChartModel(cycles: observed, averageLength: averageLength)
    }

    /// 1.4 B4 — one label per bar: day and month in the reader's language
    /// ("13. Mai", "May 13"). The bars are told apart by their label, so when
    /// two starts would read alike (the same day a year apart) every label
    /// carries the year. A key that is not a day keeps itself.
    static func axisLabels(for dayKeys: [String], locale: Locale = .autoupdatingCurrent) -> [String] {
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        func labels(template: String) -> [String] {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = locale
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.setLocalizedDateFormatFromTemplate(template)
            return dayKeys.map { key in parser.date(from: key).map(formatter.string(from:)) ?? key }
        }
        let short = labels(template: "dMMM")
        return Set(short).count == short.count ? short : labels(template: "dMMMyy")
    }
}

struct CycleHistoryChart: View {
    let cycles: [MenstrualCycleDTO]
    let averageLength: Int?

    private var model: CycleHistoryChartModel {
        CycleHistoryChartModel.build(cycles: cycles, averageLength: averageLength)
    }

    var body: some View {
        // 1.4 B2 — no completed cycle yet: the card is absent.
        if !model.cycles.isEmpty {
            HLSettingsCard(icon: "chart.bar.xaxis", title: "cycle.history.title") {
                chart
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(model.cycles) { cycle in
                BarMark(
                    x: .value(String(localized: "cycle.history.axis.cycle"), cycle.label),
                    yStart: .value(String(localized: "cycle.history.axis.days"), 0),
                    yEnd: .value(String(localized: "cycle.history.period"), cycle.periodDays)
                )
                .foregroundStyle(HLChartTints.series)
                BarMark(
                    x: .value(String(localized: "cycle.history.axis.cycle"), cycle.label),
                    yStart: .value(String(localized: "cycle.history.period"), cycle.periodDays),
                    yEnd: .value(String(localized: "cycle.history.axis.days"), cycle.lengthDays)
                )
                .foregroundStyle(HLChartTints.seriesLow)
                if let ovulationDay = cycle.confirmedOvulationDay {
                    PointMark(
                        x: .value(String(localized: "cycle.history.axis.cycle"), cycle.label),
                        y: .value(String(localized: "cycle.history.ovulation.confirmed"), ovulationDay)
                    )
                    .foregroundStyle(HLText.primary)
                    .symbol(.diamond)
                    .symbolSize(55)
                }
            }
            // 1.4 B4 — the average's label sits beside the plot on the leading
            // axis (below), not on the bars where it ran into their tops.
            if let average = model.averageLength {
                RuleMark(y: .value(String(localized: "cycle.history.average"), average))
                    .foregroundStyle(HLText.secondary)
                    .lineStyle(StrokeStyle(
                        lineWidth: HLChartGrid.thresholdWidth,
                        dash: HLChartGrid.thresholdDash
                    ))
            }
        }
        .frame(height: HLChartStyle.heightRegular)
        // 1.4 B4 — the first and the last cycle's start as dates ("14. Aug."),
        // not a row of cut ISO keys, each kept inside the plot (the app's one
        // date-axis rule, as in the sleep composition).
        .chartXAxis {
            AxisMarks(values: edgeStartKeys) { value in
                AxisValueLabel(anchor: ChartDateAxis.labelAnchor(index: value.index, count: value.count)) {
                    if let key = value.as(String.self) {
                        Text(Self.startLabel(key))
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks()
            AxisMarks(position: .leading, values: model.averageLength.map { [$0] } ?? []) { value in
                AxisValueLabel {
                    if let average = value.as(Int.self) {
                        Text("Ø \(String(average))")
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                    }
                }
            }
        }
        .chartYAxisLabel("cycle.history.axis.days")
        .accessibilityChartDescriptor(ChartDescriptor(descriptor: descriptor))
    }

    /// The first and the last cycle's start key, the only labelled columns.
    private var edgeStartKeys: [String] {
        let keys = model.cycles.map(\.startDate)
        guard let first = keys.first, let last = keys.last else { return [] }
        return first == last ? [first] : [first, last]
    }

    /// A cycle's start day ("2026-08-14") as the axis shows it.
    nonisolated static func startLabel(_ key: String) -> String {
        guard let milliseconds = CyclePredictionEngine.parseDayMs(key) else { return key }
        return Date(timeIntervalSince1970: milliseconds / 1000).formatted(.dateTime.day().month(.abbreviated))
    }

    private var descriptor: AXChartDescriptor {
        let points = model.cycles.enumerated().map { index, cycle in
            (
                x: Double(index),
                y: Double(cycle.lengthDays),
                xLabel: cycle.label
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
