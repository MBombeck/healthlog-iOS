import Accessibility
import Charts
import SwiftUI

struct CycleHistoryChartModel: Equatable {
    struct Cycle: Identifiable, Equatable {
        let id: String
        let startDate: String
        /// The start as a day, where the bar stands on the time axis.
        let date: Date
        /// What the axis shows under the bar: the start as a date in
        /// words ("13. Mai"), not the day key cut to "2026-05-…".
        let label: String
        let lengthDays: Int
        let periodDays: Int
        let confirmedOvulationDay: Int?

        /// The length as the value the scrubber reads.
        var length: Double {
            Double(lengthDays)
        }
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
            guard let length = cycle.lengthDays,
                  let date = ProfileDay.startOfDay(forKey: cycle.startDate, timeZone: .current) else { return nil }
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
                date: date,
                label: label,
                lengthDays: length,
                periodDays: periodDays,
                confirmedOvulationDay: ovulationDay
            )
        }
        return CycleHistoryChartModel(cycles: observed, averageLength: averageLength)
    }

    /// One label per bar: day and month in the reader's language
    /// ("13. Mai", "May 13"). The bars are told apart by their label, so when
    /// two starts would read alike (the same day a year apart) every label
    /// carries the year. A key that is not a day keeps itself.
    static func axisLabels(for dayKeys: [String], locale: Locale = .autoupdatingCurrent) -> [String] {
        func labels(withYear: Bool) -> [String] {
            dayKeys.map { key in
                guard let day = ProfileDay.startOfDay(forKey: key, timeZone: .current) else { return key }
                // Measured against the day itself the helper leaves the year
                // off; against the distant past it adds it.
                return HLDateFormat.dayMonth(day, relativeTo: withYear ? .distantPast : day, locale: locale)
            }
        }
        let short = labels(withYear: false)
        return Set(short).count == short.count ? short : labels(withYear: true)
    }
}

struct CycleHistoryChart: View {
    let cycles: [MenstrualCycleDTO]
    let averageLength: Int?
    /// The cycle under the finger while the chart is scrubbed.
    @State private var selectedDate: Date?
    /// The value axis thins itself out at the accessibility sizes.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Width of one bar: a cycle is a column, not a day-wide sliver.
    private static let barWidth: CGFloat = HLSpace.md

    private var model: CycleHistoryChartModel {
        CycleHistoryChartModel.build(cycles: cycles, averageLength: averageLength)
    }

    private var unit: String {
        String(localized: "cycle.history.axis.days")
    }

    var body: some View {
        // No completed cycle yet: the card is absent.
        if !model.cycles.isEmpty {
            HLSectionHeader("cycle.history.title", rank: .area)
            HLCard {
                chart
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(model.cycles) { cycle in
                BarMark(
                    x: .value(String(localized: "cycle.history.axis.cycle"), cycle.date, unit: .day),
                    yStart: .value(String(localized: "cycle.history.axis.days"), 0),
                    yEnd: .value(String(localized: "cycle.history.period"), cycle.periodDays),
                    width: .fixed(Self.barWidth)
                )
                .foregroundStyle(HLChartTints.series)
                BarMark(
                    x: .value(String(localized: "cycle.history.axis.cycle"), cycle.date, unit: .day),
                    yStart: .value(String(localized: "cycle.history.period"), cycle.periodDays),
                    yEnd: .value(String(localized: "cycle.history.axis.days"), cycle.lengthDays),
                    width: .fixed(Self.barWidth)
                )
                .foregroundStyle(HLChartTints.seriesLow)
                if let ovulationDay = cycle.confirmedOvulationDay {
                    PointMark(
                        x: .value(String(localized: "cycle.history.axis.cycle"), cycle.date, unit: .day),
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
            }
            HLChartScrubber.marks(selectedDate: selectedDate, in: model.cycles, date: \.date, value: \.length) { cycle in
                HLScrubCallout(title: cycle.label, value: "\(cycle.lengthDays)", unit: unit)
            }
        }
        .frame(height: HLChartStyle.heightRegular)
        // The outer bars stand inside the plot, not half over its edge.
        .chartXScale(range: .plotDimension(padding: Self.barWidth))
        // The axes of every chart, with one addition: the average's label
        // stands on the trailing edge, where no value label can meet it.
        .chartYAxis {
            HLChartAxis.values(at: dynamicTypeSize)
            AxisMarks(position: .trailing, values: model.averageLength.map { [$0] } ?? []) { value in
                AxisValueLabel {
                    if let average = value.as(Int.self) {
                        Text("Ø \(String(average))")
                            .hlText(.chartAxis)
                    }
                }
            }
        }
        .chartXAxis { HLChartAxis.dates(model.cycles.map(\.date)) }
        .hlChartUnit(unit)
        .hlChartScrub($selectedDate) { [model] date in
            Self.announcement(for: date, in: model.cycles)
        }
        .accessibilityChartDescriptor(ChartDescriptor(descriptor: descriptor))
    }

    /// What VoiceOver says for the cycle nearest to the scrubbed day.
    static func announcement(for date: Date, in cycles: [CycleHistoryChartModel.Cycle]) -> String? {
        guard let cycle = HLChartScrubber.nearest(to: date, in: cycles, date: \.date) else { return nil }
        let days = String(format: String(localized: "cycle.history.days.value"), cycle.lengthDays)
        return "\(cycle.label), \(days)"
    }

    /// A cycle's start day ("2026-08-14") as the axis shows it.
    nonisolated static func startLabel(_ key: String) -> String {
        guard let milliseconds = CyclePredictionEngine.parseDayMs(key) else { return key }
        let day = Date(timeIntervalSince1970: milliseconds / 1000)
        // Day and month only, against the day itself: the axis has no room
        // for a year.
        return HLDateFormat.dayMonth(day, relativeTo: day)
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
