import Foundation
@testable import HealthLog
import Testing

/// **#115 B6 — the mood history's Custom range opens on the account's days.**
///
/// Choosing "Custom" pre-filled "the last 29 days" from `Calendar.current` and
/// `.now` in the phone's zone. For a phone east of the account the range ended
/// on the phone's tomorrow and started a day late; the server reads `from`/`to`
/// in the account zone. The default is now cut in the profile zone, like the
/// fixed presets (#115 1.5).
@Suite("#115 B6 — mood history custom range in the profile zone")
struct MoodHistoryCustomRangeProfileDayTests {
    private func instant(_ iso: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: iso))
    }

    @Test("an account west of UTC: late evening there is still that day, whatever the phone says")
    func westOfUTC() throws {
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        // 23:30 UTC = 16:30 in Los Angeles on 24 Sep, already 25 Sep in Berlin.
        let range = try MoodHistoryFilter.defaultCustomRange(now: instant("2026-09-24T23:30:00Z"), timeZone: losAngeles)
        #expect(range.to == "2026-09-24")
        #expect(range.from == "2026-08-26")
    }

    @Test("the range spans the same 30 calendar days the old default meant")
    func spansTwentyNineDaysBack() throws {
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        let range = try MoodHistoryFilter.defaultCustomRange(now: instant("2026-03-29T10:00:00Z"), timeZone: berlin)
        #expect(range.to == "2026-03-29")
        #expect(range.from == ProfileDay.key("2026-03-29", addingDays: -29))
    }

    @Test("the default range feeds the query verbatim")
    func queryUsesRange() throws {
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let range = try MoodHistoryFilter.defaultCustomRange(now: instant("2026-09-24T23:30:00Z"), timeZone: losAngeles)
        let filter = MoodHistoryFilter(period: .custom, customFrom: range.from, customTo: range.to)
        let query = filter.query(limit: 50, offset: 0)
        #expect(query.from == "2026-08-26")
        #expect(query.to == "2026-09-24")
    }
}
