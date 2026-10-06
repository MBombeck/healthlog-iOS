import Foundation
@testable import HealthLog
import Testing

/// **v1.39.1 (#1032) — every logged day entry reaches the calendar.**
///
/// Until v1.39.1 the calendar read carried flow, symptoms, BBT, the ovulation
/// test, the mucus reading and the cervix signs, and dropped the rest of the
/// day log. The server now also sends `intermenstrualBleeding`,
/// `sexualActivity`, `pregnancyTest`, `progesteroneTest`, `contraceptive` and
/// `hasNote` (`CycleCalendarEnvelope` at tag `v1.39.1`, unchanged since the
/// pre-release state these fixtures were first taken from; commits
/// `adec5bd04` + `0390d124c`). The grid marks intercourse on the day and rings
/// a day that holds anything else without a marker of its own; both are in
/// the legend and in the day's VoiceOver label.
@MainActor
@Suite("v1.39.1 #1032 — cycle calendar shows intercourse and the other day entries")
struct CycleCalendarV1391Tests {
    /// One `data.days[]` entry with every v1.39.1 key. `overrides` replaces
    /// the raw JSON value of a key; `v1391: false` drops the six new keys
    /// entirely (a server older than v1.39.1).
    private static func day(_ overrides: [String: String] = [:], v1391: Bool = true) -> String {
        var fields: [(String, String)] = [
            ("date", #""2026-09-20""#), ("phase", #""FOLLICULAR""#), ("isPredictedPeriod", "false"),
            ("isFertileWindow", "false"), ("isPredictedOvulation", "false"), ("isPeriodLogged", "false"),
            ("isCycleStart", "false"), ("cycleDay", "4"), ("periodEndable", "true"), ("flow", "null"),
            ("hasSymptoms", "false"), ("confidence", "0.6"), ("basalBodyTempC", "null"),
            ("temperatureExcluded", "false"), ("ovulationTest", "null"), ("cervicalMucus", "null"),
            ("cervixPosition", "null"), ("cervixFirmness", "null"), ("cervixOpening", "null")
        ]
        if v1391 {
            fields += [
                ("intermenstrualBleeding", "false"), ("sexualActivity", "false"), ("pregnancyTest", "null"),
                ("progesteroneTest", "null"), ("contraceptive", "null"), ("hasNote", "false")
            ]
        }
        let body = fields.map { key, value in "\"\(key)\":\(overrides[key] ?? value)" }
        return "{" + body.joined(separator: ",") + "}"
    }

    private static func decode(_ json: String) throws -> CalendarDayDTO {
        try JSONDecoder.hlDefault.decode(CalendarDayDTO.self, from: Data(json.utf8))
    }

    @Test("intercourse decodes and is named in the day's VoiceOver label")
    func intercourse() throws {
        let dto = try Self.decode(Self.day(["sexualActivity": "true"]))
        #expect(dto.sexualActivity)
        let label = CycleCalendarGrid.accessibilityLabel(dayNumber: 20, dto: dto)
        #expect(label.contains(String(localized: "cycle.calendar.a11y.intercourse")))
        // Intercourse has its own marker, so it does not also light the ring.
        #expect(CycleCalendarGrid.otherEntryLabels(dto).isEmpty)
    }

    @Test("a day with only a test, contraception, spotting or a note no longer reads as empty")
    func otherEntries() throws {
        let dto = try Self.decode(Self.day([
            "intermenstrualBleeding": "true", "pregnancyTest": #""NEGATIVE""#,
            "contraceptive": #""ORAL""#, "hasNote": "true"
        ]))
        let others = CycleCalendarGrid.otherEntryLabels(dto)
        #expect(others == [
            String(localized: "cycle.capture.intermenstrualBleeding.label"),
            String(localized: "cycle.capture.pregnancyTest.label"),
            String(localized: "cycle.capture.contraceptive.label"),
            String(localized: "cycle.capture.note.header")
        ])
        let label = CycleCalendarGrid.accessibilityLabel(dayNumber: 20, dto: dto)
        for part in others {
            #expect(label.contains(part))
        }
    }

    @Test("readings the v1.39.0 grid already carried (BBT, mucus, cervix) also light the ring")
    func v139ReadingsRing() throws {
        let dto = try Self.decode(Self.day(["basalBodyTempC": "36.6", "cervicalMucus": #""CREAMY""#, "cervixPosition": #""HIGH""#]))
        #expect(CycleCalendarGrid.otherEntryLabels(dto).count == 3)
    }

    @Test("a server older than v1.39.1 decodes as before: nothing extra logged")
    func olderServer() throws {
        let dto = try Self.decode(Self.day(v1391: false))
        #expect(!dto.sexualActivity)
        #expect(!dto.hasNote)
        #expect(dto.cycleDay == 4)
        #expect(CycleCalendarGrid.otherEntryLabels(dto).isEmpty)
        #expect(CycleCalendarGrid.accessibilityLabel(dayNumber: 20, dto: dto) == "20")
    }

    @Test("a malformed new field never fails the day")
    func malformedTolerated() throws {
        let dto = try Self.decode(Self.day(["sexualActivity": #""yes""#, "hasNote": "7", "pregnancyTest": "3"]))
        #expect(!dto.sexualActivity)
        #expect(!dto.hasNote)
        #expect(dto.pregnancyTest == nil)
        #expect(dto.date == "2026-09-20")
    }
}
