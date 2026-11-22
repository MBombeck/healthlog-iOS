import Foundation
@testable import HealthLog
import Testing

/// The cycle page in the order and forms of every detail page: key figure,
/// forecast, statistics raster, charts with scrubbing, calendar and patterns,
/// the explainer last.
@Suite("E-P3 cycle page order and forms")
@MainActor
struct EP3DiaryCycleTests {
    // MARK: - Section order

    @Test("The sections follow the detail-page order, the explainer last")
    func sectionOrderWithPhase() {
        #expect(CycleScreenSection.visible(hasPhase: true) == [
            .ring, .prediction, .upcoming, .statistics, .temperature, .history, .calendar, .patterns, .explainer
        ])
    }

    @Test("Without a phase the explainer drops out and the order stays")
    func sectionOrderWithoutPhase() {
        let sections = CycleScreenSection.visible(hasPhase: false)
        #expect(!sections.contains(.explainer))
        #expect(sections == CycleScreenSection.allCases.filter { $0 != .explainer })
        #expect(sections.first == .ring)
        #expect(sections.last == .patterns)
    }

    // MARK: - Statistics raster

    @Test("Average length, variability and period become three raster cells in days")
    func statCellsFromStats() throws {
        let json = #"{"avgLengthDays":28,"lengthVariabilityDays":2.6,"avgPeriodLengthDays":5,"regularity":"REGULAR"}"#
        let stats = try JSONDecoder.hlDefault.decode(CycleStatsDTO.self, from: Data(json.utf8))
        let cells = CycleStatsCard.cells(stats)
        let days = String(localized: "cycle.stats.cell.unit.days")
        #expect(cells.map(\.value) == ["28", "3", "5"])
        #expect(cells.map(\.label) == [
            String(localized: "cycle.stats.cell.avgLength"),
            String(localized: "cycle.stats.variability"),
            String(localized: "cycle.stats.cell.avgPeriod")
        ])
        #expect(cells.allSatisfy { $0.unit == days })
    }

    @Test("One day reads in the singular, every other count in the plural")
    func dayUnitSingular() {
        #expect(CycleStatsCard.dayUnit(1) == String(localized: "cycle.stats.cell.unit.day"))
        #expect(CycleStatsCard.dayUnit(2) == String(localized: "cycle.stats.cell.unit.days"))
        #expect(CycleStatsCard.dayUnit(0) == String(localized: "cycle.stats.cell.unit.days"))
        let cells = CycleStatsCard.cells(avgLength: 28, variability: 1, avgPeriod: 5)
        #expect(cells[1].unit == String(localized: "cycle.stats.cell.unit.day"))
    }

    @Test("A figure the server does not send drops out of the raster")
    func statCellsDropMissing() {
        #expect(CycleStatsCard.cells(avgLength: nil, variability: nil, avgPeriod: nil).isEmpty)
        let cells = CycleStatsCard.cells(avgLength: 30, variability: nil, avgPeriod: nil)
        #expect(cells.map(\.value) == ["30"])
    }

    // MARK: - Phase badge

    @Test("The phase badge names the day and the phase, or the phase alone")
    func phaseBadgeText() {
        let name = String(localized: CyclePhaseExplainer.nameKey(for: .follicular))
        let withDay = CyclePhaseExplainer.badgeText(phase: .follicular, dayOfCycle: 9)
        #expect(withDay.contains(name))
        #expect(withDay.contains("9"))
        #expect(CyclePhaseExplainer.badgeText(phase: .follicular, dayOfCycle: nil) == name)
    }

    // MARK: - Charts

    @Test("Each history bar stands on its start day, so the scrubber can find it")
    func historyBarsCarryDates() throws {
        let cycles = try JSONDecoder.hlDefault.decode(CycleListResponse.self, from: Data(Self.historyJSON.utf8)).cycles
        let model = CycleHistoryChartModel.build(cycles: cycles, averageLength: 28)
        #expect(model.cycles.count == 2)
        for cycle in model.cycles {
            #expect(cycle.date == ProfileDay.startOfDay(forKey: cycle.startDate, timeZone: .current))
            #expect(cycle.length == Double(cycle.lengthDays))
        }
        let june = try #require(ProfileDay.startOfDay(forKey: "2026-06-03", timeZone: .current))
        let nearest = HLChartScrubber.nearest(to: june, in: model.cycles, date: \.date)
        #expect(nearest?.id == "c1")
        let spoken = try #require(CycleHistoryChart.announcement(for: june, in: model.cycles))
        #expect(spoken.hasPrefix(model.cycles[1].label))
        #expect(spoken.contains("30"))
    }

    @Test("Scrubbing the temperature chart reads the nearest reading with its unit")
    func bbtAnnouncement() throws {
        let first = try #require(ProfileDay.startOfDay(forKey: "2026-07-02", timeZone: .current))
        let second = try #require(ProfileDay.startOfDay(forKey: "2026-07-05", timeZone: .current))
        let points = [
            CycleBBTChartModel.Point(day: "2026-07-02", date: first, value: 36.45, phase: nil, excluded: false),
            CycleBBTChartModel.Point(day: "2026-07-05", date: second, value: 36.8, phase: nil, excluded: false)
        ]
        let spoken = try #require(
            CycleBBTChart.announcement(for: second.addingTimeInterval(3600), in: points, units: .standard)
        )
        #expect(spoken.contains(HLValueFormat.number(36.8, fractionDigits: 2 ... 2)))
        #expect(spoken.hasSuffix(CycleBBTChart.unitText(units: .standard)))
        #expect(CycleBBTChart.announcement(for: second, in: [], units: .standard) == nil)
    }

    private static let historyJSON = #"""
    {"cycles":[
      {
        "id":"c1","startDate":"2026-06-01","endDate":"2026-06-30",
        "periodEndDate":"2026-06-05","lengthDays":30,
        "ovulationDate":"2026-06-15","ovulationConfirmed":true,
        "isPredicted":false,"syncVersion":1,"updatedAt":null
      },
      {
        "id":"c2","startDate":"2026-05-01","endDate":"2026-05-29",
        "periodEndDate":"2026-05-04","lengthDays":28,
        "ovulationDate":null,"ovulationConfirmed":false,
        "isPredicted":false,"syncVersion":1,"updatedAt":null
      }
    ],"stats":null}
    """#
}
