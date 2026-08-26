import Foundation
@testable import HealthLog
import ModelsR4
import Testing

/// A2-L4 — locks the non-throwing FHIR date/time construction that replaced the
/// `try! DateTime(date:…)` / `try! Instant(date:…)` on runtime dates in the FHIR
/// export path. The converter must never throw and must round-trip the wall-
/// clock components for the supplied timezone.
@Suite("FHIRDateConverter (A2-L4 safe-encode)")
struct FHIRDateConverterTests {
    private let utc = TimeZone.gmt

    @Test("DateTime carries the correct UTC components")
    func dateTimeComponentsUTC() {
        // 2023-11-14T22:13:20Z (epoch 1_700_000_000).
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let dt = FHIRDateConverter.dateTime(from: date, timeZone: utc)

        #expect(dt.date.year == 2023)
        #expect(dt.date.month == 11)
        #expect(dt.date.day == 14)
        #expect(dt.time?.hour == 22)
        #expect(dt.time?.minute == 13)
        #expect(dt.time?.second == Decimal(20))
        #expect(dt.timeZone == utc)
    }

    @Test("Instant carries the correct UTC components")
    func instantComponentsUTC() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let inst = FHIRDateConverter.instant(from: date, timeZone: utc)

        #expect(inst.date.year == 2023)
        #expect(inst.date.month == 11)
        #expect(inst.date.day == 14)
        #expect(inst.time.hour == 22)
        #expect(inst.time.minute == 13)
        #expect(inst.time.second == Decimal(20))
    }

    @Test("Honours a non-UTC timezone offset")
    func honoursTimeZone() throws {
        // Same instant rendered in a +14:00 zone rolls to the next day.
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let tz = try #require(TimeZone(secondsFromGMT: 14 * 3600))
        let dt = FHIRDateConverter.dateTime(from: date, timeZone: tz)

        #expect(dt.date.day == 15)
        #expect(dt.time?.hour == 12)
    }

    @Test("Does not crash on edge dates (epoch, distant past/future)")
    func edgeDatesDoNotCrash() {
        // The whole point of A2-L4: no `try!` crash on any runtime date.
        let epoch = FHIRDateConverter.dateTime(from: Date(timeIntervalSince1970: 0), timeZone: utc)
        #expect(epoch.date.year == 1970)

        let distantFuture = FHIRDateConverter.instant(from: Date(timeIntervalSince1970: 4_102_444_800), timeZone: utc)
        #expect(distantFuture.date.year == 2100)

        let leapDay = FHIRDateConverter.dateTime(
            from: Date(timeIntervalSince1970: 1_582_934_400), // 2020-02-29T00:00:00Z
            timeZone: utc
        )
        #expect(leapDay.date.month == 2)
        #expect(leapDay.date.day == 29)
    }
}
