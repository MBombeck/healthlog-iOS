import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// **1.4 B4 — one rule for date axes.** The metric page cut its last label to
/// "1…" (HRV) and "19.…" (mood); every chart picked its own format and let
/// Swift Charts place ticks up to the plot's edge. These pin the shared rule
/// and that the charts use it.
@Suite("1.4 B4: the app's one date-axis rule")
struct ChartDateAxisTests {
    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 86400
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        calendar.firstWeekday = 2
        return calendar
    }

    /// 22 Sep 2026, 07:30 Berlin, the start of a month of daily readings.
    private var start: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 7, minute: 30)) ?? .now
    }

    @Test("the step keeps the labels to at most four, and the format follows the step")
    func stepBySpan() {
        #expect(ChartDateAxis.step(forSpan: 50 * 60) == .init(component: .minute, value: 15), "a workout")
        #expect(ChartDateAxis.step(forSpan: 8 * hour) == .init(component: .hour, value: 2), "a night")
        #expect(ChartDateAxis.step(forSpan: 7 * day) == .init(component: .day, value: 2), "a week")
        #expect(ChartDateAxis.step(forSpan: 30 * day) == .init(component: .weekOfYear, value: 1), "a month")
        #expect(ChartDateAxis.step(forSpan: 365 * day) == .init(component: .month, value: 3), "a year")
        #expect(ChartDateAxis.step(forSpan: 4 * 365 * day) == .init(component: .year, value: 1), "all")
        let sample = start
        #expect(sample.formatted(ChartDateAxis.Step(component: .hour, value: 2).format)
            == sample.formatted(.dateTime.hour().minute()))
        #expect(sample.formatted(ChartDateAxis.Step(component: .weekOfYear, value: 1).format)
            == sample.formatted(.dateTime.day().month(.abbreviated)))
        #expect(sample.formatted(ChartDateAxis.Step(component: .month, value: 3).format)
            == sample.formatted(.dateTime.month(.abbreviated)))
    }

    @Test("a month of readings gets weekly ticks on week starts, none near either edge", arguments: [30.0, 29.0, 31.0])
    func monthTicks(days: Double) {
        let end = start.addingTimeInterval(days * day)
        let ticks = ChartDateAxis.ticks(from: start, to: end, calendar: calendar)
        #expect((2 ... 4).contains(ticks.count))
        for tick in ticks {
            let position = tick.timeIntervalSince(start) / end.timeIntervalSince(start)
            #expect(position >= ChartDateAxis.edgeMargin && position <= 1 - ChartDateAxis.edgeMargin)
            #expect(calendar.component(.weekday, from: tick) == 2, "a Monday")
            #expect(calendar.component(.hour, from: tick) == 0)
        }
    }

    @Test("a night gets ticks on even hours, a year on quarter starts")
    func nightAndYear() {
        let night = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 23, minute: 10)) ?? .now
        let nightTicks = ChartDateAxis.ticks(from: night, to: night.addingTimeInterval(7.5 * hour), calendar: calendar)
        #expect(!nightTicks.isEmpty)
        #expect(nightTicks
            .allSatisfy { calendar.component(.hour, from: $0).isMultiple(of: 2) && calendar.component(.minute, from: $0) == 0 })
        let yearTicks = ChartDateAxis.ticks(from: start, to: start.addingTimeInterval(365 * day), calendar: calendar)
        #expect(yearTicks
            .allSatisfy { [1, 4, 7, 10].contains(calendar.component(.month, from: $0)) && calendar.component(.day, from: $0) == 1 })
        #expect(ChartDateAxis.ticks(from: start, to: start, calendar: calendar).isEmpty, "one reading: no axis labels")
    }

    @Test("edge labels of a two-label category axis start and end at their columns")
    func edgeLabelsStayInside() {
        #expect(ChartDateAxis.labelAnchor(index: 0, count: 2) == .topLeading)
        #expect(ChartDateAxis.labelAnchor(index: 1, count: 2) == .topTrailing)
        #expect(ChartDateAxis.labelAnchor(index: 0, count: 1) == .top, "a single label stays centred")
    }

    @Test("cycle starts read as dates, not as ISO keys")
    func cycleHistoryLabels() {
        let label = CycleHistoryChart.startLabel("2026-08-14")
        #expect(!label.contains("2026"))
        #expect(label.contains("14"))
        #expect(CycleHistoryChart.startLabel("garbage") == "garbage")
    }

    @Test("every date x-axis goes through the rule", arguments: [
        "HealthLog/Screens/Charts/ChartDetailComponents.swift",
        "HealthLog/Screens/Charts/FullscreenChartCover.swift",
        "HealthLog/Screens/Labs/BiomarkerChart.swift",
        "HealthLog/Screens/Mood/MoodTrendChart.swift",
        "HealthLog/Screens/Shared/HistoryLineChart.swift",
        "HealthLog/Screens/Cycle/CycleBBTChart.swift",
        "HealthLog/Screens/Medications/MedicationEfficacySection.swift",
        "HealthLog/Screens/Medications/MDRGatedDrugLevelSection.swift",
        "HealthLog/Screens/Workouts/WorkoutDetailView.swift",
        "HealthLog/Screens/Insights/Sub/SleepHypnogramScreen.swift"
    ])
    func chartsUseTheRule(path: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Screens
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // repo root
        let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        #expect(source.contains("ChartDateAxis.marks("))
        #expect(!source.contains("AxisValueLabel(format: .dateTime"), "no chart-local date format")
    }

    /// B4-z — the edge margin only keeps a label inside when the label is
    /// centred on its tick; Swift Charts starts date labels at the tick.
    @Test("the rule's labels are centred on their ticks")
    func labelsAreCentred() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let rule = try String(
            contentsOf: root.appendingPathComponent("HealthLog/Screens/Charts/ChartDateAxis.swift"),
            encoding: .utf8
        )
        #expect(rule.contains("AxisValueLabel(anchor: .top) {"))
    }
}

/// **1.4 B4 — a y range that fits the readings.** The medication effect chart
/// started at zero and drew its line along the top of the plot.
@Suite("1.4 B4: value axes fit their readings")
struct ChartValueDomainTests {
    @Test("an HbA1c series around 6.5 % gets a narrow range, not 0 to 7")
    func narrowSeries() throws {
        let domain = try #require(ChartValueDomain.fitting([6.4, 6.6, 6.9, 7.1]))
        #expect(domain.lowerBound > 5.5)
        #expect(domain.lowerBound < 6.4 && domain.upperBound > 7.1)
    }

    @Test("a flat series still gets a band; non-negative data never goes below zero")
    func flatAndFloor() throws {
        let flat = try #require(ChartValueDomain.fitting([80, 80]))
        #expect(flat.lowerBound < 80 && flat.upperBound > 80)
        let small = try #require(ChartValueDomain.fitting([0, 0.1]))
        #expect(small.lowerBound == 0)
        #expect(ChartValueDomain.fitting([]) == nil)
        #expect(ChartValueDomain.fitting([.nan]) == nil)
    }

    @Test("the medication effect chart uses it")
    func efficacyChartUsesIt() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("HealthLog/Screens/Medications/MedicationEfficacySection.swift"),
            encoding: .utf8
        )
        #expect(source.contains(".chartYScale(domain: yDomain)"))
        #expect(source.contains("ChartValueDomain.fitting("))
    }
}
