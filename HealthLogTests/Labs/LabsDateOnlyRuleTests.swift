import Foundation
@testable import HealthLog
import Testing

/// The server's lab-day rule (`isLabDateOnly`, server commit a25658c85): a
/// `takenAt` exactly on 00:00 or 12:00 UTC is a date, never moved into the
/// device's zone. Pinned in zones on both sides of UTC.
@Suite("Labs: date-only readings keep their day")
struct LabsDateOnlyRuleTests {
    private static func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier) ?? .gmt
        return calendar
    }

    private static func day(_ date: Date, in calendar: Calendar) -> DateComponents {
        calendar.dateComponents([.year, .month, .day], from: date)
    }

    @Test(
        "Noon and midnight UTC are date-only, every other instant is not",
        arguments: [
            ("2026-03-04T12:00:00.000Z", true),
            ("2026-03-04T00:00:00Z", true),
            ("2026-03-04T12:00:00.001Z", false),
            ("2026-03-04T11:59:59Z", false),
            ("2026-03-04T07:30:00.000Z", false),
            ("2026-03-04T12:00:00+01:00", false)
        ]
    )
    func predicate(raw: String, expected: Bool) {
        #expect(LabsDateFormat.isDateOnly(raw) == expected)
    }

    @Test(
        "A date-only reading lands on its own date west and east of UTC",
        arguments: ["America/Los_Angeles", "Pacific/Honolulu", "Europe/Berlin", "Pacific/Kiritimati", "UTC"]
    )
    func dateOnlyKeepsItsDay(zone: String) throws {
        let calendar = Self.calendar(zone)
        for raw in ["2026-03-04T12:00:00.000Z", "2026-03-04T00:00:00.000Z"] {
            let date = try #require(LabsDateFormat.readingDate(raw, calendar: calendar))
            let parts = Self.day(date, in: calendar)
            #expect(parts.year == 2026 && parts.month == 3 && parts.day == 4, "\(raw) in \(zone)")
        }
    }

    @Test("A drawn instant stays the instant and takes the reader's day")
    func instantIsConverted() throws {
        let raw = "2026-03-04T02:30:00.000Z"
        let instant = try #require(LabsDateFormat.parse(raw))
        let losAngeles = Self.calendar("America/Los_Angeles")
        let read = try #require(LabsDateFormat.readingDate(raw, calendar: losAngeles))
        #expect(read == instant)
        #expect(Self.day(read, in: losAngeles).day == 3)
    }

    @Test("A malformed string stays as it came")
    func malformed() {
        #expect(LabsDateFormat.readingDate("not a date") == nil)
        #expect(LabsDateFormat.labDate("not a date") == "not a date")
        #expect(LabsDateFormat.labDateTime("not a date") == "not a date")
    }

    @Test("A date-only reading shows no time of day; a drawn one does")
    func dateTimeCaption() {
        let dateOnly = "2026-03-04T12:00:00.000Z"
        #expect(LabsDateFormat.labDateTime(dateOnly) == LabsDateFormat.labDate(dateOnly))
        let drawn = "2026-03-04T07:31:00.000Z"
        #expect(LabsDateFormat.labDateTime(drawn) != LabsDateFormat.labDate(drawn))
    }

    @Test("The custom-metric helpers keep reading the plain instant")
    func customMetricHelpersUnchanged() throws {
        let raw = "2026-03-04T12:00:00.000Z"
        let instant = try #require(LabsDateFormat.parse(raw))
        #expect(LabsDateFormat.mediumDateTime(raw) == HLDateFormat.dateTime(instant, style: .abbreviated))
    }
}
