import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// M1 — the allergy onset date must not smear by a day across timezones. The
/// editor encodes a picked calendar day as noon UTC of that LOCAL day, so the
/// stored DATE is stable everywhere (the old local-midnight→UTC path rolled the
/// day back for users west of UTC).
@Suite("Records onset date encoding (M1)")
struct RecordsDateFormatTests {
    @Test("onsetInstant anchors a picked day at noon UTC — no day smear")
    func onsetInstantNoonAnchored() throws {
        let cal = Calendar(identifier: .gregorian) // local timezone
        let day = try #require(cal.date(from: DateComponents(year: 2026, month: 6, day: 10)))
        // The picked LOCAL day (June 10) anchors to noon UTC of that calendar day.
        #expect(RecordsDateFormat.onsetInstant(forDay: day) == "2026-06-10T12:00:00Z")
    }

    @Test("isSameOnsetDay recognises an unchanged onset (skips a needless .set)")
    func isSameOnsetDayRoundTrips() throws {
        let cal = Calendar(identifier: .gregorian)
        let day = try #require(cal.date(from: DateComponents(year: 2026, month: 6, day: 10)))
        #expect(RecordsDateFormat.isSameOnsetDay(storedInstant: "2026-06-10T12:00:00Z", asPickedDay: day))
        // A different day is NOT the same.
        let other = try #require(cal.date(from: DateComponents(year: 2026, month: 6, day: 11)))
        #expect(!RecordsDateFormat.isSameOnsetDay(storedInstant: "2026-06-10T12:00:00Z", asPickedDay: other))
        // An unparseable instant is treated as "not the same" (emits a fresh .set).
        #expect(!RecordsDateFormat.isSameOnsetDay(storedInstant: "garbage", asPickedDay: day))
    }
}
