import Foundation
@testable import HealthLog
import Testing

/// #1343 / #191 (server 1.49.0) — the additive `performance` object on
/// `GET /api/workouts/{id}`: decoded figure by figure, never at the cost of
/// the workout, and shown as rows only for the figures that are there.
@Suite("Workout performance figures (#191)")
struct WorkoutPerformanceTests {
    private func decode(_ performance: String) throws -> WorkoutListEntryDTO {
        let json = #"""
        {"id":"w-1","sportType":"running","startedAt":"2026-11-20T07:00:00Z","endedAt":"2026-11-20T07:45:00Z",
         "durationSec":2700,"distanceM":8000,"activeEnergyKcal":520,"avgHr":148,"maxHr":171,
         "source":"GARMIN","externalId":"fit:1"\#(performance)}
        """#
        return try JSONDecoder.hlDefault.decode(WorkoutListEntryDTO.self, from: Data(json.utf8))
    }

    private static let german = Locale(identifier: "de_DE")

    @Test("every figure decodes; the server's nulls stay absent")
    func fullBlock() throws {
        let dto = try decode(#"""
        ,"performance":{"aerobicTrainingEffect":3.2,"anaerobicTrainingEffect":1.4,"trainingLoad":142,
          "recoveryTimeMin":1080,"sweatLossMl":650,"avgPowerW":278,"avgVerticalOscillationMm":84,
          "avgGroundContactTimeMs":246,"avgGroundContactBalancePct":null}
        """#)
        let performance = try #require(dto.performance)
        #expect(performance.aerobicTrainingEffect == 3.2)
        #expect(performance.trainingLoad == 142)
        #expect(performance.avgVerticalOscillationMm == 84)
        #expect(performance.avgGroundContactBalancePct == nil)
        #expect(performance.hasFigures)
    }

    @Test("an older server (no key) and a workout without figures (null) show nothing")
    func absent() throws {
        #expect(try decode("").performance == nil)
        #expect(try decode(#","performance":null"#).performance == nil)
        #expect(WorkoutDetailView.performanceRows(WorkoutPerformanceDTO()).isEmpty)
    }

    @Test("a malformed figure or block costs the figure, never the workout")
    func tolerant() throws {
        let odd = try decode(#","performance":{"trainingLoad":"high","sweatLossMl":500}"#)
        #expect(odd.id == "w-1")
        #expect(odd.performance?.trainingLoad == nil)
        #expect(odd.performance?.sweatLossMl == 500)
        let notAnObject = try decode(#","performance":[1,2]"#)
        #expect(notAnObject.id == "w-1")
        #expect(notAnObject.performance?.hasFigures == false)
    }

    @Test("rows only for present figures, in the web's order, with their units")
    func rows() {
        let performance = WorkoutPerformanceDTO(
            aerobicTrainingEffect: 3.24,
            trainingLoad: 142.4,
            recoveryTimeMin: 90,
            sweatLossMl: 650,
            avgPowerW: 278,
            avgVerticalOscillationMm: 84,
            avgGroundContactTimeMs: 246,
            avgGroundContactBalancePct: 49.5
        )
        let rows = WorkoutDetailView.performanceRows(performance, locale: Self.german)
        #expect(rows.map(\.id) == [
            "aerobic", "load", "recovery", "sweat", "power", "oscillation", "groundContact", "balance"
        ])
        let value = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.value) })
        #expect(value["aerobic"] == "3,2")
        #expect(value["load"] == "142")
        #expect(value["sweat"]?.contains("650") == true)
        #expect(value["sweat"]?.hasSuffix("ml") == true)
        #expect(value["power"]?.hasSuffix("W") == true)
        // Millimetres on the wire, centimetres on screen.
        #expect(value["oscillation"]?.contains("8,4") == true)
        #expect(value["oscillation"]?.hasSuffix("cm") == true)
        #expect(value["groundContact"]?.hasSuffix("ms") == true)
        #expect(value["recovery"] == HLTimeFormat.duration(90 * 60, locale: Self.german))
        #expect(value["balance"]?.contains("49,5") == true)
        #expect(value["balance"]?.contains("50,5") == true)
    }
}
