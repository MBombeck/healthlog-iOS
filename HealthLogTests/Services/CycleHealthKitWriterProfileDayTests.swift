import Foundation
@testable import HealthLog
import Testing

#if canImport(HealthKit)

    /// **#115 B5 — a server cycle day is written to Health on the account's day.**
    ///
    /// The writer parsed `dayLog.date` as midnight of the DEVICE zone (a
    /// formatter that froze `.current` at first use). A day the server cut in the
    /// account zone therefore landed on another instant whenever phone and
    /// account disagreed. It now writes at noon of that day in the account zone:
    /// that instant is on the logged day in the account zone, and on the same
    /// calendar date in every zone within ±12 h of it — the Health app shows the
    /// device's day, so the entry appears on the right date either way.
    @Suite("#115 B5 — cycle writer on the account's day")
    struct CycleHealthKitWriterProfileDayTests {
        private func zone(_ identifier: String) throws -> TimeZone {
            try #require(TimeZone(identifier: identifier))
        }

        @Test("the sample instant is noon of the server day in the account zone")
        func sampleIsProfileNoon() throws {
            let losAngeles = try zone("America/Los_Angeles")
            let date = try #require(CycleHealthKitWriter.sampleDate(forDayKey: "2026-06-18", timeZone: losAngeles))
            #expect(date == ISO8601DateFormatter().date(from: "2026-06-18T19:00:00Z"))
        }

        @Test(
            "the instant names the logged day in the account zone and in every device zone within ±12 h",
            arguments: ["America/Los_Angeles", "Europe/Berlin", "Asia/Tokyo", "Pacific/Auckland"]
        )
        func dayHoldsAcrossDeviceZones(profileID: String) throws {
            let profile = try zone(profileID)
            for key in ["2026-03-29", "2026-06-18", "2026-10-25", "2026-12-31"] {
                let date = try #require(CycleHealthKitWriter.sampleDate(forDayKey: key, timeZone: profile))
                #expect(ProfileDay.key(for: date, timeZone: profile) == key)
                for offsetHours in [-11, -6, 0, 6, 11] {
                    let offset = profile.secondsFromGMT(for: date) + offsetHours * 3600
                    // Real zones span UTC−12 … UTC+14.
                    guard (-12 * 3600 ... 14 * 3600).contains(offset) else { continue }
                    let device = try #require(TimeZone(secondsFromGMT: offset))
                    #expect(
                        ProfileDay.key(for: date, timeZone: device) == key,
                        "\(profileID) \(key): device at \(offsetHours) h shows another day"
                    )
                }
            }
        }

        /// The importer skips our own samples by their echo marker. Should one
        /// ever come back without it, the importer's point-event rule keys it on
        /// the same day the writer meant — no second day log.
        @Test("the importer would key the written instant on the same day")
        func importerAgreesWithWriter() throws {
            let berlin = try zone("Europe/Berlin")
            let date = try #require(CycleHealthKitWriter.sampleDate(forDayKey: "2026-06-18", timeZone: berlin))
            #expect(CycleHealthKitImporter.dayKey(start: date, end: date, timeZone: berlin) == "2026-06-18")
        }

        @Test("a key that is no calendar date writes nothing")
        func invalidKeyIsNil() throws {
            let berlin = try zone("Europe/Berlin")
            #expect(CycleHealthKitWriter.sampleDate(forDayKey: "2026-02-30", timeZone: berlin) == nil)
            #expect(CycleHealthKitWriter.sampleDate(forDayKey: "", timeZone: berlin) == nil)
        }
    }

#endif
