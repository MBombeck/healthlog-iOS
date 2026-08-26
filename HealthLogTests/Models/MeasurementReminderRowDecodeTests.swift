import Foundation
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// W-REMINDERS (#23 v1.18.1) — pins the `MeasurementReminderDTO` decode contract.
///
/// The DTO is render-only-authoritative: `origin`/`endsOn`/`nextDueAt`/
/// `lastSatisfiedAt` come straight from the server and are never recomputed.
/// These tests pin the additive fields (`origin`, `endsOn`), the forward-compat
/// posture (`measurementType` stays a tolerant `String?`; unknown `origin` →
/// `.unknown`), and missing/null tolerance on every optional.
@Suite("MeasurementReminderRow decode")
struct MeasurementReminderRowDecodeTests {
    private func decode(_ json: String) throws -> MeasurementReminderRow {
        try JSONDecoder.hlDefault.decode(MeasurementReminderRow.self, from: Data(json.utf8))
    }

    @Test("Full VORSORGE row with endsOn decodes every field")
    func fullVorsorge() throws {
        let row = try decode("""
        {
          "id": "r1",
          "label": "Annual blood test",
          "measurementType": "WEIGHT",
          "intervalDays": 30,
          "rrule": null,
          "anchorDate": "2026-01-01T09:00:00.000Z",
          "endsOn": "2026-12-31T09:00:00.000Z",
          "origin": "VORSORGE",
          "notifyHour": 9,
          "location": "Clinic A",
          "nextDueAt": "2026-07-01T09:00:00.000Z",
          "lastSatisfiedAt": "2026-06-01T09:00:00.000Z",
          "enabled": true,
          "createdAt": "2026-01-01T09:00:00.000Z",
          "updatedAt": "2026-06-01T09:00:00.000Z"
        }
        """)
        #expect(row.id == "r1")
        #expect(row.label == "Annual blood test")
        #expect(row.measurementType == "WEIGHT")
        #expect(row.intervalDays == 30)
        #expect(row.rrule == nil)
        #expect(row.anchorDate != nil) // Build 6.4 — anchorDate is now decoded
        #expect(row.origin == .vorsorge)
        #expect(row.endsOn != nil)
        #expect(row.nextDueAt != nil)
        #expect(row.lastSatisfiedAt != nil)
        #expect(row.notifyHour == 9)
        #expect(row.location == "Clinic A")
        #expect(row.enabled)
    }

    @Test("COACH origin decodes")
    func coachOrigin() throws {
        let row = try decode("""
        {"id":"r2","label":"Daily weight","measurementType":"WEIGHT","intervalDays":1,
         "rrule":null,"anchorDate":null,"endsOn":null,"origin":"COACH","notifyHour":8,
         "location":null,"nextDueAt":null,"lastSatisfiedAt":null,"enabled":true,
         "createdAt":"2026-06-01T09:00:00.000Z","updatedAt":"2026-06-01T09:00:00.000Z"}
        """)
        #expect(row.origin == .coach)
        #expect(row.endsOn == nil) // open-ended course
    }

    @Test("Unknown future origin decodes to .unknown (forward-compat, row survives)")
    func unknownOrigin() throws {
        let row = try decode("""
        {"id":"r3","label":"X","measurementType":"FUTURE_METRIC","intervalDays":7,
         "rrule":null,"anchorDate":null,"endsOn":null,"origin":"SOME_NEW_SOURCE",
         "notifyHour":9,"location":null,"nextDueAt":null,"lastSatisfiedAt":null,
         "enabled":true,"createdAt":"2026-06-01T09:00:00.000Z","updatedAt":"2026-06-01T09:00:00.000Z"}
        """)
        #expect(row.origin == .unknown)
        // measurementType stays a tolerant String? — a widened server enum value
        // the client doesn't know must not break the decode.
        #expect(row.measurementType == "FUTURE_METRIC")
    }

    @Test("Free-text reminder: measurementType null tolerated")
    func freeText() throws {
        let row = try decode("""
        {"id":"r4","label":"Eye exam","measurementType":null,"intervalDays":null,
         "rrule":"FREQ=YEARLY","anchorDate":null,"endsOn":null,"origin":"VORSORGE",
         "notifyHour":9,"location":null,"nextDueAt":"2027-01-01T09:00:00.000Z",
         "lastSatisfiedAt":null,"enabled":true,"createdAt":"2026-06-01T09:00:00.000Z",
         "updatedAt":"2026-06-01T09:00:00.000Z"}
        """)
        #expect(row.measurementType == nil)
        #expect(row.rrule == "FREQ=YEARLY")
        #expect(row.intervalDays == nil)
        #expect(row.origin == .vorsorge)
    }

    @Test("Missing optional fields tolerated (only required id/label present)")
    func minimalRow() throws {
        // origin missing → defensive .unknown; enabled missing → defaults true.
        let row = try decode(#"{"id":"r5","label":"Minimal"}"#)
        #expect(row.id == "r5")
        #expect(row.origin == .unknown)
        #expect(row.enabled)
        #expect(row.nextDueAt == nil)
        #expect(row.endsOn == nil)
    }

    @Test("Codable round-trip preserves fields (SWR cache fidelity)")
    func roundTrip() throws {
        let original = try decode("""
        {"id":"r6","label":"BP","measurementType":"BLOOD_PRESSURE_SYS","intervalDays":14,
         "rrule":null,"anchorDate":null,"endsOn":"2026-09-01T09:00:00.000Z","origin":"COACH",
         "notifyHour":7,"location":null,"nextDueAt":"2026-07-15T09:00:00.000Z",
         "lastSatisfiedAt":null,"enabled":false,"createdAt":"2026-06-01T09:00:00.000Z",
         "updatedAt":"2026-06-01T09:00:00.000Z"}
        """)
        let data = try JSONEncoder.hlDefault.encode(original)
        let decoded = try JSONDecoder.hlDefault.decode(MeasurementReminderRow.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - The accepted v1.37.20 ledger fields (ROUTE-07)

    // The payloads come from Plan 08-18's frozen fixture, read through that
    // plan's own loader, so nothing here is a second transcription of the
    // accepted bytes. What is asserted is the decode: exact nullability, the
    // required-integer default that keeps a stale cache readable, and the two
    // open enums of the ledger row.

    private static func instant(_ iso: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: iso))
    }

    @Test("The three additive fields decode with the exact nullability the schema publishes")
    func additiveLedgerFieldsDecode() throws {
        let pristine = try MeasurementReminderV13720ContractTests.reminder("reminderPristine")
        #expect(pristine.snoozedUntil == nil)
        #expect(pristine.lastSkippedAt == nil)
        #expect(pristine.skipCount == 0)

        let snoozed = try MeasurementReminderV13720ContractTests.reminder("reminderSnoozed")
        let snoozeInstant = try Self.instant("2026-08-24T06:00:00Z")
        #expect(snoozed.snoozedUntil == snoozeInstant)
        #expect(snoozed.lastSkippedAt == nil, "a snooze is not a skip")
        #expect(snoozed.skipCount == 0)
        #expect(snoozed.snoozedUntil == snoozed.nextDueAt, "both are the same server-resolved instant")

        let skipped = try MeasurementReminderV13720ContractTests.reminder("reminderSkipped")
        let skipInstant = try Self.instant("2026-08-15T11:20:00Z")
        #expect(skipped.snoozedUntil == nil, "a skip clears any snooze")
        #expect(skipped.lastSkippedAt == skipInstant)
        #expect(skipped.skipCount == 3)
        // A skipped cycle is `lastSkippedAt > lastSatisfiedAt` — a clock
        // comparison the server told clients to make, never a recomputed cadence.
        let lastSatisfied = try #require(skipped.lastSatisfiedAt)
        let lastSkipped = try #require(skipped.lastSkippedAt)
        #expect(lastSkipped > lastSatisfied)
    }

    @Test("A pre-v1.37.20 cached row reads as never snoozed and never skipped")
    func legacyRowWithoutLedgerFields() throws {
        // The shape every SWR cache blob written before the fields existed still
        // has: the three keys are absent, not null.
        let legacy = try MeasurementReminderV13720ContractTests.reminder("legacyReminderWithoutLedgerFields")
        #expect(legacy.snoozedUntil == nil)
        #expect(legacy.lastSkippedAt == nil)
        #expect(legacy.skipCount == 0, "a required integer that predates the field reads zero, not a decode failure")
        #expect(legacy.id == "rem_legacy_0004")
        #expect(legacy.origin == .coach)
    }

    @Test("Explicit nulls decode like absent values, and an explicit zero survives")
    func explicitNullLedgerFields() throws {
        let row = try decode("""
        {"id":"r7","label":"Vorsorge","measurementType":null,"intervalDays":90,
         "rrule":null,"anchorDate":null,"endsOn":null,"origin":"VORSORGE","notifyHour":9,
         "location":null,"nextDueAt":"2026-11-01T08:00:00.000Z","lastSatisfiedAt":null,
         "snoozedUntil":null,"lastSkippedAt":null,"skipCount":0,"enabled":true,
         "createdAt":"2026-06-01T09:00:00.000Z","updatedAt":"2026-06-01T09:00:00.000Z"}
        """)
        #expect(row.snoozedUntil == nil)
        #expect(row.lastSkippedAt == nil)
        #expect(row.skipCount == 0)
    }

    @Test("The SWR cache round-trip preserves the ledger fields")
    func ledgerFieldsSurviveTheCacheRoundTrip() throws {
        let original = try MeasurementReminderV13720ContractTests.reminder("reminderSkipped")
        let data = try JSONEncoder.hlDefault.encode(original)
        let serialized = try JSONSerialization.jsonObject(with: data)
        let asJSON = try #require(serialized as? [String: Any])
        #expect(asJSON["skipCount"] as? Int == 3, "a required field must be re-emitted, not dropped")
        #expect(asJSON["lastSkippedAt"] != nil)
        #expect(asJSON["snoozedUntil"] == nil, "a nil instant drops from the wire, as every other optional does")

        let decoded = try JSONDecoder.hlDefault.decode(MeasurementReminderRow.self, from: data)
        #expect(decoded == original)
        #expect(decoded.skipCount == 3)
        #expect(decoded.lastSkippedAt == original.lastSkippedAt)
    }

    // MARK: - The ledger row and page

    private func decodePage(_ json: String) throws -> MeasurementReminderHistoryPage {
        try JSONDecoder.hlDefault.decode(MeasurementReminderHistoryPage.self, from: Data(json.utf8))
    }

    @Test("A ledger page decodes every published field, in the order the server sent")
    func ledgerPageDecodes() throws {
        let fixture = try MeasurementReminderV13720ContractTests.fixture()
        let envelope = try #require(fixture["historyFirstPage"] as? [String: Any])
        let pageObject = try #require(envelope["data"])
        let pageBytes = try JSONSerialization.data(withJSONObject: pageObject)
        let page = try JSONDecoder.hlDefault.decode(MeasurementReminderHistoryPage.self, from: pageBytes)

        #expect(page.meta == MeasurementReminderHistoryPage.Meta(total: 3, limit: 50, offset: 0))
        #expect(page.events.count == 3)
        let newest = try #require(page.events.first)
        let occurred = try Self.instant("2026-08-15T11:20:00Z")
        #expect(newest.id == "evt_0003")
        #expect(newest.kind == .skipped)
        #expect(newest.source == .skip)
        #expect(newest.onTime == false, "onTime is server-derived at write time; iOS never re-derives it")
        #expect(newest.occurredAt == occurred)
        #expect(newest.createdAt == newest.occurredAt)
        #expect(page.events.map(\.occurredAt) == page.events.map(\.occurredAt).sorted(by: >))
    }

    @Test("Unknown future ledger enum values keep the row and their raw string")
    func ledgerToleratesFutureEnumValues() throws {
        let page = try decodePage("""
        {"events":[{"id":"evt_x","kind":"POSTPONED","occurredAt":"2026-08-15T11:20:00Z",
          "onTime":true,"source":"pharmacy_sync","createdAt":"2026-08-15T11:20:00Z"}],
         "meta":{"total":1,"limit":50,"offset":0}}
        """)
        let event = try #require(page.events.first)
        #expect(event.kind == .unknown("POSTPONED"))
        #expect(event.source == .unknown("pharmacy_sync"))

        // A cache round-trip must not launder the raw value into a known one.
        let data = try JSONEncoder.hlDefault.encode(page)
        let restored = try JSONDecoder.hlDefault.decode(MeasurementReminderHistoryPage.self, from: data)
        #expect(restored == page)
        let serialized = try JSONSerialization.jsonObject(with: data)
        let asJSON = try #require(serialized as? [String: Any])
        let events = try #require(asJSON["events"] as? [[String: Any]])
        #expect(events.first?["kind"] as? String == "POSTPONED")
        #expect(events.first?["source"] as? String == "pharmacy_sync")
    }

    @Test("Every published source value maps to its own case")
    func everyPublishedSourceMaps() {
        let published = [
            "manual", "auto_measurement", "auto_lab", "telegram", "vaccination", "encounter", "skip"
        ]
        let mapped = published.map(MeasurementReminderEventSource.init(wire:))
        #expect(mapped == [.manual, .autoMeasurement, .autoLab, .telegram, .vaccination, .encounter, .skip])
        #expect(mapped.map(\.wireValue) == published, "the wire spelling round-trips exactly")
        #expect(["SATISFIED", "SKIPPED"].map(MeasurementReminderEventKind.init(wire:)) == [.satisfied, .skipped])
    }

    // MARK: - The snooze body is a calendar day, not an instant

    @Test("The snooze body encodes a YYYY-MM-DD day in the caller's timezone")
    func snoozeBodyIsACalendarDay() throws {
        let instant = try Self.instant("2026-08-24T22:30:00Z")
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        let utc = try #require(TimeZone(identifier: "UTC"))
        // Same instant, two zones, two calendar days — which is exactly why the
        // published field is a day rather than a moment.
        #expect(MeasurementReminderSnooze.day(instant, in: berlin) == "2026-08-25")
        #expect(MeasurementReminderSnooze.day(instant, in: utc) == "2026-08-24")

        let body = MeasurementReminderSnooze(day: instant, in: utc)
        let data = try JSONEncoder.hlDefault.encode(body)
        let serialized = try JSONSerialization.jsonObject(with: data)
        let asJSON = try #require(serialized as? [String: Any])
        #expect(Set(asJSON.keys) == ["until"])
        let until = try #require(asJSON["until"] as? String)
        #expect(until == "2026-08-24")
        // The published pattern is date-only; an ISO-8601 instant would fail it.
        #expect(until.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil)
        #expect(until == MeasurementReminderSnooze(until: "2026-08-24").until)
    }
}
