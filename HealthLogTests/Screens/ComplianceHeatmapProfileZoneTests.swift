import Foundation
@testable import HealthLog
import Testing

/// **#115 1.5 — the compliance heatmap puts each server day in its own cell.**
///
/// The server answers `GET /api/medications/intake?scope=compliance` with one
/// `{ date: "YYYY-MM-DD", scheduled, taken }` per day, keyed in the ACCOUNT
/// zone. `JSONDecoder.hlDefault` turns each `date` into UTC midnight. The old
/// grid matched those anchors with `Calendar.current.isDate(_:inSameDayAs:)`:
/// everywhere west of UTC, UTC midnight is still the previous evening, so each
/// cell showed the day before it; and the grid's "today" was the phone's today,
/// not the account's.
@Suite("ComplianceHeatmapSection — days in the profile zone (#115 1.5)")
struct ComplianceHeatmapProfileZoneTests {
    /// Server rows for the days around the instant below (Thu 18 / Fri 19 June).
    private func serverDays() throws -> [ComplianceDay] {
        let json = #"""
        [{"date":"2026-06-17","scheduled":2,"taken":0},
         {"date":"2026-06-18","scheduled":2,"taken":1},
         {"date":"2026-06-19","scheduled":2,"taken":2}]
        """#
        return try JSONDecoder.hlDefault.decode([ComplianceDay].self, from: Data(json.utf8))
    }

    private func zone(_ identifier: String) throws -> TimeZone {
        try #require(TimeZone(identifier: identifier))
    }

    /// Row index of a weekday (0 = Monday) — the grid's layout rule.
    private func row(of key: String, in timeZone: TimeZone) throws -> Int {
        let day = try #require(ProfileDay.startOfDay(forKey: key, timeZone: timeZone))
        let weekday = ProfileDay.calendar(in: timeZone).component(.weekday, from: day)
        return ((weekday - 2) + 7) % 7
    }

    @Test("Los Angeles account: today's cell is the 18th and holds the 18th's row")
    func westOfUTCProfile() throws {
        // 2026-06-19T03:00Z = Thursday 2026-06-18 20:00 in Los Angeles, while
        // this machine (Europe/Berlin) is already on Friday the 19th.
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-19T03:00:00Z"))
        let losAngeles = try zone("America/Los_Angeles")
        let days = try serverDays()
        let weeks = 12
        let lastColumn = weeks - 1

        let today = try ComplianceHeatmapSection.day(
            forRow: row(of: "2026-06-18", in: losAngeles), column: lastColumn,
            weeks: weeks, in: days, now: now, timeZone: losAngeles
        )
        #expect(today.map { ProfileDay.key(ofAnchor: $0.date) } == "2026-06-18")
        #expect(today?.taken == 1)

        let yesterday = try ComplianceHeatmapSection.day(
            forRow: row(of: "2026-06-17", in: losAngeles), column: lastColumn,
            weeks: weeks, in: days, now: now, timeZone: losAngeles
        )
        #expect(yesterday?.taken == 0)

        // Friday is still in the future for this account: no cell, no row.
        let friday = try ComplianceHeatmapSection.day(
            forRow: row(of: "2026-06-19", in: losAngeles), column: lastColumn,
            weeks: weeks, in: days, now: now, timeZone: losAngeles
        )
        #expect(friday == nil)
    }

    @Test("Tokyo account at 20:00Z: today is already Friday the 19th")
    func eastOfUTCProfile() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-18T20:00:00Z"))
        let tokyo = try zone("Asia/Tokyo")
        let today = try ComplianceHeatmapSection.day(
            forRow: row(of: "2026-06-19", in: tokyo), column: 11,
            weeks: 12, in: serverDays(), now: now, timeZone: tokyo
        )
        #expect(today.map { ProfileDay.key(ofAnchor: $0.date) } == "2026-06-19")
        #expect(today?.taken == 2)
    }

    @Test("An offline (standalone) roll-up lands in the same cells as the server rows")
    func standaloneAnchorsMatch() throws {
        // `standaloneCompliance` now emits the UTC-midnight anchor of the local
        // day key — the server shape — instead of a device-local midnight.
        let berlin = try zone("Europe/Berlin")
        let localMidnight = try #require(ProfileDay.startOfDay(forKey: "2026-06-18", timeZone: berlin))
        let anchor = ProfileDay.anchor(for: localMidnight, timeZone: berlin)
        #expect(ProfileDay.key(ofAnchor: anchor) == "2026-06-18")
    }
}
