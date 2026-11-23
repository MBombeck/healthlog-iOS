import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// #181 (server 1.49.0, `measurement.reading-timezone`) — the reading's and the
/// night's own zone: decoded additively on the sleep night and on measurement
/// rows, shown only when the server names one, and named only when its clock
/// differs from the device's. An older server sends no key; nothing changes.
@Suite("Reading time zone (#181)")
struct ReadingTimeZoneTests {
    private static let newYork = TimeZone(identifier: "America/New_York")!
    private static let berlin = TimeZone(identifier: "Europe/Berlin")!
    private static let paris = TimeZone(identifier: "Europe/Paris")!
    private static let instant = ISO8601DateFormatter().date(from: "2026-06-03T22:10:00Z")!

    // MARK: - ReadingTimeZone

    @Test("a real IANA name resolves; nil, empty and unknown names read as no zone")
    func zoneResolution() {
        #expect(ReadingTimeZone.zone("America/New_York")?.identifier == "America/New_York")
        #expect(ReadingTimeZone.zone(nil) == nil)
        #expect(ReadingTimeZone.zone("") == nil)
        #expect(ReadingTimeZone.zone("Mars/Olympus_Mons") == nil)
    }

    @Test("away means another clock at that instant, not another name")
    func awayByOffset() {
        #expect(ReadingTimeZone.isAway(Self.newYork, at: Self.instant, device: Self.berlin))
        #expect(!ReadingTimeZone.isAway(Self.paris, at: Self.instant, device: Self.berlin))
        #expect(ReadingTimeZone.awayZone("Europe/Paris", at: Self.instant, device: Self.berlin) == nil)
        #expect(ReadingTimeZone.awayZone("America/New_York", at: Self.instant, device: Self.berlin) == Self.newYork)
        #expect(ReadingTimeZone.awayZone(nil, at: Self.instant, device: Self.berlin) == nil)
    }

    @Test("the place name is the zone's city, spaces for underscores")
    func placeName() throws {
        #expect(ReadingTimeZone.placeName(Self.newYork) == "New York")
        #expect(try ReadingTimeZone.placeName(#require(TimeZone(identifier: "Asia/Kolkata"))) == "Kolkata")
        #expect(try ReadingTimeZone.placeName(#require(TimeZone(identifier: "Europe/Isle_of_Man"))) == "Isle of Man")
    }

    // MARK: - Sleep night

    private func night(_ zoneField: String) throws -> SleepSession {
        let json = #"""
        {"data":{"main":{"night":"2026-06-04","source":"APPLE_HEALTH",
          "start":"2026-06-03T22:10:00Z","end":"2026-06-04T06:30:00Z",
          "asleepMinutes":432,"stages":{"CORE":240},"segments":[]\#(zoneField)},"naps":[]}}
        """#
        let dto = try JSONDecoder.hlDefault.decode(SleepNightEnvelope.self, from: Data(json.utf8)).data
        return try #require(dto.main)
    }

    @Test("main.timeZone decodes; null, absent and a non-string read as nil and keep the night")
    func sleepDecode() throws {
        #expect(try night(#","timeZone":"America/New_York""#).timeZone == "America/New_York")
        #expect(try night(#","timeZone":null"#).timeZone == nil)
        #expect(try night("").timeZone == nil)
        #expect(try night(#","timeZone":42"#).timeZone == nil)
    }

    @Test("the night shows its own zone and names it only when away from the device")
    func sleepDisplayZone() throws {
        let abroad = try night(#","timeZone":"America/New_York""#)
        #expect(SleepHypnogramScreen.displayZone(for: abroad) == Self.newYork)
        let note = try #require(SleepHypnogramScreen.zoneNote(for: abroad, device: Self.berlin))
        #expect(note.contains("New York"))
        #expect(!note.contains("sleep.hypnogram"))
        #expect(SleepHypnogramScreen.zoneNote(for: abroad, device: Self.newYork) == nil)

        let home = try night("")
        #expect(SleepHypnogramScreen.displayZone(for: home) == .current)
        #expect(SleepHypnogramScreen.zoneNote(for: home, device: Self.berlin) == nil)
    }

    @Test("bedtime reads in the night's zone: 22:10 UTC is 18:10 in New York")
    func sleepClock() {
        let german = Locale(identifier: "de_DE")
        let shown = HLTimeFormat.shortTime(Self.instant, locale: german, timeZone: Self.newYork)
        #expect(shown == "18:10")
    }

    // MARK: - Measurement rows

    private func wire(_ zoneField: String) throws -> MeasurementWireDTO {
        let json = #"""
        {"id":"m1","type":"WEIGHT","value":72.4,"unit":"kg","measuredAt":"2026-06-03T22:10:00Z",
         "source":"APPLE_HEALTH"\#(zoneField)}
        """#
        return try JSONDecoder.hlDefault.decode(MeasurementWireDTO.self, from: Data(json.utf8))
    }

    @Test("a row's timeZone reaches the domain reading; an older server's row has none")
    func measurementDecode() throws {
        let abroad = try wire(#","timeZone":"America/New_York""#)
        #expect(abroad.timeZone == "America/New_York")
        #expect(abroad.toDomain()?.timeZone == "America/New_York")
        #expect(try wire("").toDomain()?.timeZone == nil)
        #expect(try wire(#","timeZone":null"#).timeZone == nil)
        #expect(try wire(#","timeZone":"""#).timeZone == nil)
        #expect(try wire(#","timeZone":7"#).timeZone == nil)
    }

    @Test("a merged blood pressure keeps its halves' zone")
    func bloodPressureZone() throws {
        let sys = #"{"id":"s","type":"BLOOD_PRESSURE_SYS","value":120,"measuredAt":"2026-06-03T22:10:00Z","timeZone":"Asia/Kolkata"}"#
        let dia = #"{"id":"d","type":"BLOOD_PRESSURE_DIA","value":80,"measuredAt":"2026-06-03T22:10:00Z","timeZone":"Asia/Kolkata"}"#
        let wires = try [sys, dia].map { try JSONDecoder.hlDefault.decode(MeasurementWireDTO.self, from: Data($0.utf8)) }
        let merged = MeasurementAggregator.mergeBloodPressure(wires)
        #expect(merged.count == 1)
        #expect(merged.first?.timeZone == "Asia/Kolkata")
    }

    @Test("the row hint names the place and its clock only when away")
    @MainActor
    func rowHint() throws {
        let abroad = try #require(try wire(#","timeZone":"America/New_York""#).toDomain())
        let hint = try #require(MeasurementRow.zoneHint(for: abroad, device: Self.berlin))
        #expect(hint.contains("New York"))
        #expect(!hint.contains("measurement.row"))
        #expect(MeasurementRow.zoneHint(for: abroad, device: Self.newYork) == nil)
        let detail = try #require(MeasurementRow.detailLine(for: abroad, device: Self.berlin))
        #expect(detail.contains("New York"))

        let home = try #require(try wire("").toDomain())
        #expect(MeasurementRow.zoneHint(for: home, device: Self.berlin) == nil)
        #expect(MeasurementRow.detailLine(for: home, device: Self.berlin)?.contains("New York") != true)
    }
}
