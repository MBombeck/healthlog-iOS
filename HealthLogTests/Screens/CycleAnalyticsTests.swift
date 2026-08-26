import Foundation
@testable import HealthLog
import Testing

@Suite("Cycle Build 5 analytics transforms")
struct CycleAnalyticsTests {
    @Test("Seed catalogue has exact categories and 15 unique keys")
    func seedCatalogue() {
        #expect(CycleSymptomCatalog.seedSections.map(\.items.count) == [8, 3, 4])
        let keys = CycleSymptomCatalog.seedSections.flatMap(\.items).map(\.key)
        #expect(Set(keys).count == 15)
        #expect(keys.contains("libido_high"))
        #expect(keys.contains("libido_low"))
        #expect(keys.contains("diarrhea"))
        #expect(keys.contains("constipation"))
    }

    @Test("BBT transform uses current cycle, marks excluded values, and distinguishes ovulation")
    func bbtCurrentCycle() throws {
        let days = try decodeDays([
            day("2026-07-01", 36.45, phase: "MENSTRUAL"),
            day("2026-07-10", 36.40, phase: "FOLLICULAR"),
            day("2026-07-11", 36.70, phase: "OVULATORY", excluded: true),
            day("2026-07-12", 36.75, phase: "LUTEAL"),
            day("2026-05-01", 36.1, phase: "LUTEAL")
        ])
        let cycles = try decodeCycles(Self.currentCycleJSON)
        let model = CycleBBTChartModel.build(days: days, cycles: cycles, prediction: nil, today: "2026-07-20")
        #expect(model.points.count == 4)
        #expect(model.points.first(where: { $0.day == "2026-07-11" })?.excluded == true)
        #expect(model.lineSegments.flatMap(\.points).contains(where: \.excluded) == false)
        #expect(model.ovulation?.day == "2026-07-12")
        #expect(model.ovulation?.confirmed == true)
    }

    @Test("BBT transform falls back to 35 days and requires two values")
    func bbtFallbackAndEmpty() throws {
        let one = try decodeDays([day("2026-07-20", 36.5, phase: nil)])
        #expect(CycleBBTChartModel.build(days: one, cycles: [], prediction: nil, today: "2026-07-20").hasEnoughData == false)

        let days = try decodeDays([
            day("2026-06-16", 36.3, phase: nil),
            day("2026-06-17", 36.4, phase: nil),
            day("2026-07-20", 36.6, phase: nil)
        ])
        let model = CycleBBTChartModel.build(days: days, cycles: [], prediction: nil, today: "2026-07-20")
        #expect(model.points.map(\.day) == ["2026-06-16", "2026-06-17", "2026-07-20"])
    }

    @Test("History keeps at most 12 observed cycles oldest first")
    func historyOrderingAndPredictionFilter() throws {
        let rows = (1 ... 14).map { index in
            let day = String(format: "%02d", index)
            return #"""
            {
              "id":"c\#(index)","startDate":"2026-06-\#(day)",
              "endDate":"2026-07-\#(day)",
              "periodEndDate":"2026-06-\#(String(format: "%02d", min(index + 4, 28)))",
              "lengthDays":28,"ovulationDate":null,"ovulationConfirmed":false,
              "isPredicted":false,"syncVersion":1,"updatedAt":null
            }
            """#
        }
        let predicted = #"""
        {
          "id":"predicted","startDate":"2026-08-01","endDate":null,
          "periodEndDate":null,"lengthDays":28,"ovulationDate":null,
          "ovulationConfirmed":false,"isPredicted":true,
          "syncVersion":0,"updatedAt":null
        }
        """#
        let rowsJSON = rows.reversed().joined(separator: ",")
        let cycles = try decodeCycles(
            #"{"cycles":[\#(predicted),\#(rowsJSON)],"stats":null}"#
        )
        let model = CycleHistoryChartModel.build(cycles: cycles, averageLength: 28)
        #expect(model.cycles.count == 12)
        #expect(model.cycles.map(\.startDate) == model.cycles.map(\.startDate).sorted())
        #expect(model.cycles.contains(where: { $0.id == "predicted" }) == false)
    }

    @Test("History includes period length and confirmed ovulation only")
    func historySegments() throws {
        let cycles = try decodeCycles(Self.historyCyclesJSON)
        let model = CycleHistoryChartModel.build(cycles: cycles, averageLength: 28)
        #expect(model.cycles[1].periodDays == 5)
        #expect(model.cycles[1].confirmedOvulationDay == 15)
        #expect(model.cycles[0].confirmedOvulationDay == nil)
    }

    private func day(_ date: String, _ temp: Double, phase: String?, excluded: Bool = false) -> String {
        #"""
        {
          "date":"\#(date)","phase":\#(phase.map { "\"\($0)\"" } ?? "null"),
          "isPredictedPeriod":false,"isFertileWindow":false,
          "isPredictedOvulation":false,"isPeriodLogged":false,
          "flow":null,"hasSymptoms":false,"confidence":0.5,
          "basalBodyTempC":\#(temp),"temperatureExcluded":\#(excluded),
          "ovulationTest":null,"cervicalMucus":null
        }
        """#
    }

    private static let currentCycleJSON = #"""
    {"cycles":[{
      "id":"current","startDate":"2026-07-01","endDate":null,
      "periodEndDate":"2026-07-05","lengthDays":null,
      "ovulationDate":"2026-07-12","ovulationConfirmed":true,
      "isPredicted":false,"syncVersion":1,"updatedAt":null
    }],"stats":null}
    """#

    private static let historyCyclesJSON = #"""
    {"cycles":[
      {
        "id":"c1","startDate":"2026-06-01","endDate":"2026-06-29",
        "periodEndDate":"2026-06-05","lengthDays":28,
        "ovulationDate":"2026-06-15","ovulationConfirmed":true,
        "isPredicted":false,"syncVersion":1,"updatedAt":null
      },
      {
        "id":"c2","startDate":"2026-05-01","endDate":"2026-05-29",
        "periodEndDate":"2026-05-04","lengthDays":28,
        "ovulationDate":"2026-05-14","ovulationConfirmed":false,
        "isPredicted":false,"syncVersion":1,"updatedAt":null
      }
    ],"stats":null}
    """#

    private func decodeDays(_ rows: [String]) throws -> [CalendarDayDTO] {
        let data = Data("{\"profile\":null,\"prediction\":null,\"days\":[\(rows.joined(separator: ","))]}".utf8)
        return try JSONDecoder.hlDefault.decode(CycleCalendarResponse.self, from: data).days
    }

    private func decodeCycles(_ json: String) throws -> [MenstrualCycleDTO] {
        try JSONDecoder.hlDefault.decode(CycleListResponse.self, from: Data(json.utf8)).cycles
    }
}
