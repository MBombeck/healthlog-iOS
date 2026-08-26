import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable type_body_length

/// Lockt das `MedicationWireDTO`-Schema und das Mapping zur Domain. Vor diesem
/// Fix dekodierte iOS die Server-Response als sein eigenes Domain-`Medication`
/// und brach am ersten Listen-Endpoint mit Zeitfenstern statt diskreten Times
/// (W2a-A2 Audit §2.5).
@Suite("Medication wire shape")
struct MedicationWireTests {
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601WithFractional
        return d
    }()

    @Test("Server-shape decodes with all v1.4.x fields")
    func decodesFullShape() throws {
        // Server emits daysOfWeek as the raw Prisma column value — a STRING
        // (`"0,1,2,3,4,5,6"` legacy days-only, or `"i2;1,2,3"` interval+days).
        // A4-Audit row 2: pre-v0.4.0 iOS expected [Int]? and decoded typeMismatch.
        let json = Data(#"""
        {
            "id": "med_1",
            "name": "Ozempic",
            "dose": "0.5 mg",
            "treatmentClass": "GLP1",
            "dosesPerUnit": 4,
            "category": "HORMONE",
            "active": true,
            "notificationsEnabled": true,
            "schedules": [{
                "windowStart": "08:00",
                "windowEnd": "10:00",
                "label": "Morning",
                "dose": null,
                "daysOfWeek": "0,1,2,3,4,5,6"
            }],
            "lastTakenAt": "2026-05-13T07:42:18.000Z",
            "todayEventCount": 1
        }
        """#.utf8)
        let wire = try decoder.decode(MedicationWireDTO.self, from: json)
        #expect(wire.name == "Ozempic")
        #expect(wire.treatmentClass == "GLP1")
        #expect(wire.dosesPerUnit == 4)
        #expect(wire.category == "HORMONE")
        #expect(wire.todayEventCount == 1)
        #expect(wire.schedules?.first?.windowStart == "08:00")
        #expect(wire.schedules?.first?.daysOfWeek == "0,1,2,3,4,5,6")
    }

    @Test("Wire → domain flattens schedules into times + weekdays")
    func wireToDomain() throws {
        let json = Data(#"""
        {
            "id": "med_2",
            "name": "Bisoprolol",
            "dose": "5 mg",
            "active": true,
            "schedules": [
                {"windowStart": "07:30", "daysOfWeek": "1,2,3,4,5"},
                {"windowStart": "21:00", "daysOfWeek": "1,2,3,4,5"}
            ]
        }
        """#.utf8)
        let wire = try decoder.decode(MedicationWireDTO.self, from: json)
        let domain = wire.toDomain()
        #expect(domain.id == "med_2")
        #expect(domain.schedule.times.count == 2)
        #expect(domain.schedule.times[0] == TimeOfDay(hour: 7, minute: 30))
        #expect(domain.schedule.times[1] == TimeOfDay(hour: 21, minute: 0))
        // Mon-Fri: server convention 1=Mon … 5=Fri.
        #expect(domain.schedule.weekdays == Set([.mon, .tue, .wed, .thu, .fri]))
        #expect(domain.schedule.intervalWeeks == 1)
        #expect(domain.active == true)
        // notificationsEnabled defaults to true when the server omits the field.
        #expect(domain.notificationsEnabled == true)
    }

    @Test("Wire → domain parses iN;1,2 interval-prefix encoding")
    func wireToDomainIntervalPrefix() throws {
        // Trulicity / weekly GLP-1: server stores `iN;` prefix for every-Nth-week.
        let json = Data(#"""
        {
            "id": "med_4",
            "name": "Trulicity",
            "dose": "5 mg",
            "active": true,
            "schedules": [
                {"windowStart": "08:00", "daysOfWeek": "i2;1"}
            ]
        }
        """#.utf8)
        let wire = try decoder.decode(MedicationWireDTO.self, from: json)
        let domain = wire.toDomain()
        #expect(domain.schedule.intervalWeeks == 2)
        #expect(domain.schedule.weekdays == Set([.mon]))
    }

    @Test("MedicationScheduleRecurrence.parse covers all server-encoded shapes")
    func parserCoverage() {
        // Legacy comma-list.
        let legacy = MedicationScheduleRecurrence.parse("1,2,3,4,5")
        #expect(legacy.daysOfWeek == [1, 2, 3, 4, 5])
        #expect(legacy.intervalWeeks == 1)
        // Interval-prefix.
        let bi = MedicationScheduleRecurrence.parse("i2;0,6")
        #expect(bi.daysOfWeek == [0, 6])
        #expect(bi.intervalWeeks == 2)
        // Nil / empty → defaults.
        #expect(MedicationScheduleRecurrence.parse(nil) == .init(daysOfWeek: [], intervalWeeks: 1))
        #expect(MedicationScheduleRecurrence.parse("") == .init(daysOfWeek: [], intervalWeeks: 1))
        // Out-of-range interval → falls back to legacy parsing (the encoded
        // prefix becomes garbage from the legacy parser's perspective).
        let bad = MedicationScheduleRecurrence.parse("i9;1,2")
        #expect(bad.intervalWeeks == 1)
        // Garbage day tokens are skipped.
        let mixed = MedicationScheduleRecurrence.parse("1,99,2,-1,3")
        #expect(mixed.daysOfWeek == [1, 2, 3])
    }

    @Test("Domain Medication carries the new server-only fields")
    func domainCarriesServerFields() throws {
        let json = Data(#"""
        {
            "id": "med_3",
            "name": "Trulicity",
            "dose": "5 mg",
            "treatmentClass": "GLP1",
            "dosesPerUnit": 4,
            "category": "HORMONE",
            "active": true,
            "lastTakenAt": "2026-05-12T06:00:00.000Z",
            "todayEventCount": 0,
            "schedules": []
        }
        """#.utf8)
        let domain = try decoder.decode(MedicationWireDTO.self, from: json).toDomain()
        #expect(domain.treatmentClass == "GLP1")
        #expect(domain.dosesPerUnit == 4)
        #expect(domain.category == "HORMONE")
        #expect(domain.lastTakenAt != nil)
        #expect(domain.todayEventCount == 0)
        #expect(domain.schedule.times.isEmpty)
        #expect(domain.schedule.weekdays == nil)
    }

    @Test("Domain decodes v1.7.0 nextDueAt + delivery booleans")
    func domainDecodesV170Fields() throws {
        let json = Data(#"""
        {
            "id": "med_v170",
            "name": "Ozempic",
            "dose": "1 mg",
            "active": true,
            "nextDueAt": "2026-06-08T06:00:00.000Z",
            "liveActivityEnabled": true,
            "criticalAlarmEnabled": false,
            "schedules": [{ "windowStart": "08:00", "rollingIntervalDays": 7 }]
        }
        """#.utf8)
        let domain = try decoder.decode(MedicationWireDTO.self, from: json).toDomain()
        #expect(domain.nextDueAt == ISO8601DateFormatter.fractional.date(from: "2026-06-08T06:00:00.000Z"))
        #expect(domain.liveActivityEnabled == true)
        #expect(domain.criticalAlarmEnabled == false)
    }

    @Test("Domain: absent v1.7.0 fields decode as nil (graceful)")
    func domainV170FieldsGracefulAbsence() throws {
        let json = Data(#"""
        {
            "id": "med_old",
            "name": "Lisinopril",
            "dose": "5 mg",
            "active": true,
            "schedules": [{ "windowStart": "08:00", "rrule": "FREQ=DAILY" }]
        }
        """#.utf8)
        let domain = try decoder.decode(MedicationWireDTO.self, from: json).toDomain()
        #expect(domain.nextDueAt == nil)
        #expect(domain.liveActivityEnabled == nil)
        #expect(domain.criticalAlarmEnabled == nil)
    }

    @Test("IntakeStatus decodes every today-ledger server value")
    func intakeStatusEnumLocked() throws {
        // Round-trip every server value.
        for raw in ["pending", "taken", "skipped", "snoozed", "missed"] {
            let data = Data("\"\(raw)\"".utf8)
            let decoded = try JSONDecoder().decode(IntakeStatus.self, from: data)
            let encoded = try JSONEncoder().encode(decoded)
            #expect(String(data: encoded, encoding: .utf8) == "\"\(raw)\"")
        }
        #expect(IntakeStatus.missed.isReadOnlyTerminal)
        #expect(!IntakeStatus.pending.isReadOnlyTerminal)
    }

    @Test("TimeOfDay parser tolerates only valid HH:mm")
    func timeOfDayParser() {
        #expect(TimeOfDay.parse("08:00") == TimeOfDay(hour: 8, minute: 0))
        #expect(TimeOfDay.parse("23:59") == TimeOfDay(hour: 23, minute: 59))
        #expect(TimeOfDay.parse("8:00") == TimeOfDay(hour: 8, minute: 0))
        #expect(TimeOfDay.parse("24:00") == nil)
        #expect(TimeOfDay.parse("garbage") == nil)
        #expect(TimeOfDay.parse("08-00") == nil)
    }

    // MARK: - v0.10 R1 — v1.5/v1.6 field decode

    @Test("Schedule DTO decodes timesOfDay / rrule / rollingIntervalDays / grace")
    func decodesV15ScheduleFields() throws {
        let json = Data(#"""
        {
            "id": "med_5",
            "name": "Trulicity",
            "dose": "5 mg",
            "active": true,
            "oneShot": false,
            "startsOn": "2026-06-01",
            "endsOn": null,
            "deliveryForm": "INJECTION",
            "createdAt": "2026-05-01T00:00:00.000Z",
            "schedules": [{
                "windowStart": "08:00",
                "windowEnd": "09:00",
                "timesOfDay": ["08:00"],
                "rrule": "FREQ=WEEKLY;INTERVAL=2;BYDAY=WE",
                "rollingIntervalDays": null,
                "reminderGraceMinutes": 90
            }]
        }
        """#.utf8)
        let wire = try decoder.decode(MedicationWireDTO.self, from: json)
        let schedule = try #require(wire.schedules?.first)
        #expect(schedule.timesOfDay == ["08:00"])
        #expect(schedule.rrule == "FREQ=WEEKLY;INTERVAL=2;BYDAY=WE")
        #expect(schedule.rollingIntervalDays == nil)
        #expect(schedule.reminderGraceMinutes == 90)
        #expect(wire.deliveryForm == "INJECTION")
        #expect(wire.startsOn == "2026-06-01")
    }

    @Test("toDomain maps everyNWeeks RRULE into a non-lossy ScheduleEntry")
    func toDomainEveryNWeeksEntry() throws {
        let json = Data(#"""
        {
            "id": "med_6",
            "name": "Trulicity",
            "dose": "5 mg",
            "active": true,
            "startsOn": "2026-06-01",
            "schedules": [{
                "windowStart": "08:00",
                "timesOfDay": ["08:00"],
                "rrule": "FREQ=WEEKLY;INTERVAL=6;BYDAY=MO"
            }]
        }
        """#.utf8)
        let domain = try decoder.decode(MedicationWireDTO.self, from: json).toDomain()
        let entry = try #require(domain.schedule.entries.first)
        #expect(entry.cadence == .everyNWeeks(interval: 6, days: [.mon]))
        #expect(entry.timesOfDay == [TimeOfDay(hour: 8, minute: 0)])
        #expect(domain.startsOn != nil)
    }

    @Test("toDomain maps rollingIntervalDays into a rolling cadence")
    func toDomainRollingEntry() throws {
        let json = Data(#"""
        {
            "id": "med_7",
            "name": "Vitamin D Depot",
            "dose": "20000 IE",
            "active": true,
            "schedules": [{
                "windowStart": "09:00",
                "timesOfDay": ["09:00"],
                "rollingIntervalDays": 30
            }]
        }
        """#.utf8)
        let domain = try decoder.decode(MedicationWireDTO.self, from: json).toDomain()
        let entry = try #require(domain.schedule.entries.first)
        #expect(entry.cadence == .rolling(intervalDays: 30))
    }

    @Test("toDomain maps medication oneShot into a oneShot cadence")
    func toDomainOneShotEntry() throws {
        let json = Data(#"""
        {
            "id": "med_8",
            "name": "Grippeimpfung",
            "dose": "1 Dosis",
            "active": true,
            "oneShot": true,
            "startsOn": "2026-10-01",
            "endsOn": "2026-10-01",
            "schedules": [{ "windowStart": "10:00", "timesOfDay": ["10:00"] }]
        }
        """#.utf8)
        let domain = try decoder.decode(MedicationWireDTO.self, from: json).toDomain()
        #expect(domain.oneShot == true)
        #expect(domain.schedule.entries.first?.cadence == .oneShot)
        #expect(domain.endsOn != nil)
    }

    /// **09-14 — inverted.** This case used to send a schedule-level
    /// `"asNeeded": true` and assert it produced a PRN cadence. No such key is
    /// published: `MedicationScheduleOutput` is `additionalProperties: false`
    /// and does not declare it, and `MedicationScheduleInput` does not accept
    /// it. The case therefore asserted a shape the server can never send. It now
    /// asserts the two things that are true of that payload against the accepted
    /// contract: an undeclared `asNeeded` key is ignored, and the row's real
    /// cadence comes from its `rrule`.
    @Test("a schedule-level asNeeded key is not a cadence input")
    func toDomainAsNeededEntry() throws {
        let json = Data(#"""
        {
            "id": "med_prn",
            "name": "Naproxen",
            "dose": "400 mg",
            "active": true,
            "schedules": [{
                "windowStart": "08:00",
                "timesOfDay": ["08:00"],
                "asNeeded": true,
                "rrule": "FREQ=DAILY"
            }]
        }
        """#.utf8)
        let domain = try decoder.decode(MedicationWireDTO.self, from: json).toDomain()
        #expect(domain.schedule.entries.first?.cadence == .daily)
    }

    /// **09-14 — inverted.** This case used to send `cycleWeeksOn` /
    /// `cycleWeeksOff` / `cycleAnchor` and require a non-nil anchor. All three
    /// strings occur **zero** times in the published contract, so it pinned a
    /// payload the server cannot produce — which is exactly why the real defect
    /// survived a green suite. It now sends the published key names and asserts
    /// the field-presence fallback still reads them without a tag.
    @Test("toDomain maps the published cyclic on/off-week fields into a cyclic cadence")
    func toDomainCyclicEntry() throws {
        let json = Data(#"""
        {
            "id": "med_cyclic",
            "name": "HRT",
            "dose": "1 Tablette",
            "active": true,
            "schedules": [{
                "windowStart": "08:00",
                "timesOfDay": ["08:00"],
                "cyclicOnWeeks": 3,
                "cyclicOffWeeks": 1
            }]
        }
        """#.utf8)
        let domain = try decoder.decode(MedicationWireDTO.self, from: json).toDomain()
        let entry = try #require(domain.schedule.entries.first)
        #expect(entry.cadence == .cyclic(weeksOn: 3, weeksOff: 1))
    }

    @Test("scheduleType=PRN is the authoritative switch (no asNeeded flag needed)")
    func toDomainScheduleTypePrnAuthoritative() throws {
        // v1.7.0 LIVE: the server tags PRN via scheduleType. The cadence must
        // resolve to .asNeeded from the tag alone, even though `asNeeded` is
        // absent and a stale daily rrule is present.
        let json = Data(#"""
        {
            "id": "med_prn_typed",
            "name": "Naproxen",
            "dose": "400 mg",
            "active": true,
            "schedules": [{
                "windowStart": "08:00",
                "timesOfDay": ["08:00"],
                "scheduleType": "PRN",
                "rrule": "FREQ=DAILY"
            }]
        }
        """#.utf8)
        let domain = try decoder.decode(MedicationWireDTO.self, from: json).toDomain()
        #expect(domain.schedule.entries.first?.cadence == .asNeeded)
    }

    /// **09-14 — inverted for the same reason as `toDomainCyclicEntry`.** The
    /// payload now carries the published key names; the cadence carries no
    /// anchor because the contract publishes none.
    @Test("scheduleType=CYCLIC switches to the cyclic pair")
    func toDomainScheduleTypeCyclicAuthoritative() throws {
        let json = Data(#"""
        {
            "id": "med_cyclic_typed",
            "name": "HRT",
            "dose": "1 Tablette",
            "active": true,
            "schedules": [{
                "windowStart": "08:00",
                "timesOfDay": ["08:00"],
                "scheduleType": "CYCLIC",
                "cyclicOnWeeks": 3,
                "cyclicOffWeeks": 1
            }]
        }
        """#.utf8)
        let domain = try decoder.decode(MedicationWireDTO.self, from: json).toDomain()
        let entry = try #require(domain.schedule.entries.first)
        #expect(entry.cadence == .cyclic(weeksOn: 3, weeksOff: 1))
    }

    @Test("scheduleType=SCHEDULED with a daily rrule resolves to .daily")
    func toDomainScheduleTypeScheduled() throws {
        let json = Data(#"""
        {
            "id": "med_scheduled_typed",
            "name": "Lisinopril",
            "dose": "5 mg",
            "active": true,
            "schedules": [{
                "windowStart": "08:00",
                "timesOfDay": ["08:00"],
                "scheduleType": "SCHEDULED",
                "rrule": "FREQ=DAILY"
            }]
        }
        """#.utf8)
        let domain = try decoder.decode(MedicationWireDTO.self, from: json).toDomain()
        #expect(domain.schedule.entries.first?.cadence == .daily)
    }

    @Test("unknown scheduleType decodes gracefully (forward-compat → SCHEDULED)")
    func toDomainScheduleTypeUnknownGraceful() throws {
        // A future server enum value must not break the decode; it collapses to
        // SCHEDULED so the field-presence dispatch still applies.
        let json = Data(#"""
        {
            "id": "med_future_typed",
            "name": "Future",
            "dose": "1 mg",
            "active": true,
            "schedules": [{
                "windowStart": "08:00",
                "timesOfDay": ["08:00"],
                "scheduleType": "TITRATION",
                "rrule": "FREQ=DAILY"
            }]
        }
        """#.utf8)
        let dto = try decoder.decode(MedicationWireDTO.self, from: json)
        #expect(dto.schedules?.first?.scheduleType == .scheduled)
        #expect(dto.toDomain().schedule.entries.first?.cadence == .daily)
    }

    @Test("toDomain: absent cyclic fields leave the cadence unchanged")
    func toDomainNoPrnCyclicGraceful() throws {
        // A SCHEDULED row carries null cyclic fields — decode must be graceful
        // and the cadence falls through to the daily rrule as before.
        let json = Data(#"""
        {
            "id": "med_plain",
            "name": "Lisinopril",
            "dose": "5 mg",
            "active": true,
            "schedules": [{ "windowStart": "08:00", "timesOfDay": ["08:00"], "rrule": "FREQ=DAILY" }]
        }
        """#.utf8)
        let domain = try decoder.decode(MedicationWireDTO.self, from: json).toDomain()
        #expect(domain.schedule.entries.first?.cadence == .daily)
    }

    @Test("DailyComplianceBucket decodes v1.7.0 due/expectedCount + capability flag")
    func complianceBucketDecodesV170Signal() throws {
        let json = Data(#"""
        {
            "compliance7": { "totalExpected": 1, "taken": 1, "skipped": 0, "missed": 0, "rate": 100, "streak": 1 },
            "compliance30": { "totalExpected": 1, "taken": 1, "skipped": 0, "missed": 0, "rate": 100, "streak": 1 },
            "dailyCompliance": {
                "2026-05-13": {
                    "expected": 1, "taken": 1, "skipped": 0, "onTime": 1, "late": 0, "veryLate": 0,
                    "due": true, "expectedCount": 1
                }
            }
        }
        """#.utf8)
        let payload = try JSONDecoder().decode(MedicationCompliancePayload.self, from: json)
        let bucket = try #require(payload.dailyCompliance["2026-05-13"])
        #expect(bucket.due == true)
        #expect(bucket.expectedCount == 1)
        #expect(bucket.wasDue)
        #expect(payload.isV170Capable)
    }

    @Test("DailyComplianceBucket: absent due/expectedCount → not capable, wasDue falls back")
    func complianceBucketGracefulAbsence() throws {
        let json = Data(#"""
        {
            "compliance7": { "totalExpected": 1, "taken": 1, "skipped": 0, "missed": 0, "rate": 100, "streak": 1 },
            "compliance30": { "totalExpected": 1, "taken": 1, "skipped": 0, "missed": 0, "rate": 100, "streak": 1 },
            "dailyCompliance": {
                "2026-05-13": { "expected": 1, "taken": 1, "skipped": 0, "onTime": 1, "late": 0, "veryLate": 0 }
            }
        }
        """#.utf8)
        let payload = try JSONDecoder().decode(MedicationCompliancePayload.self, from: json)
        let bucket = try #require(payload.dailyCompliance["2026-05-13"])
        #expect(bucket.due == nil)
        #expect(bucket.expectedCount == nil)
        #expect(bucket.wasDue) // falls back to expected > 0
        #expect(!payload.isV170Capable)
    }

    @Test("MedicationPatch carries the v1.7.0 delivery booleans + RMW-safe schedules")
    func patchCarriesDeliveryBooleans() throws {
        // A non-schedule edit (toggle Live Activity) must leave schedules nil so
        // the server replace never drops an unchanged rrule (R1 risk 5).
        let patch = MedicationsRepository.MedicationPatch(
            liveActivityEnabled: true,
            criticalAlarmEnabled: false
        )
        #expect(patch.schedules == nil)
        let data = try JSONEncoder().encode(patch)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["liveActivityEnabled"] as? Bool == true)
        #expect(obj["criticalAlarmEnabled"] as? Bool == false)
        // nextDueAt is read-only — never present in a PUT body.
        #expect(obj["nextDueAt"] == nil)
    }

    @Test("MedicationCreate carries the v1.7.0 delivery booleans")
    func createCarriesDeliveryBooleans() throws {
        let body = MedicationsRepository.MedicationCreate(
            name: "Ozempic",
            dose: "1 mg",
            liveActivityEnabled: true,
            criticalAlarmEnabled: true
        )
        let data = try JSONEncoder().encode(body)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["liveActivityEnabled"] as? Bool == true)
        #expect(obj["criticalAlarmEnabled"] as? Bool == true)
    }

    @Test("Schedule DTO encodes the v1.5 write-path fields")
    func encodesV15ScheduleFields() throws {
        // The write path (MedicationCreate/Patch nest [MedicationScheduleDTO]).
        // Verify a schedule carrying rrule + grace survives an encode round-trip
        // so a server rrule is never dropped (R1 risk 5).
        let dto = MedicationScheduleDTO(
            windowStart: "08:00",
            timesOfDay: ["08:00"],
            rrule: "FREQ=WEEKLY;INTERVAL=2;BYDAY=WE",
            reminderGraceMinutes: 90
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(dto)
        let roundTripped = try JSONDecoder().decode(MedicationScheduleDTO.self, from: data)
        #expect(roundTripped.rrule == "FREQ=WEEKLY;INTERVAL=2;BYDAY=WE")
        #expect(roundTripped.timesOfDay == ["08:00"])
        #expect(roundTripped.reminderGraceMinutes == 90)
        #expect(roundTripped.rollingIntervalDays == nil)
    }

    @Test("RRULE parser round-trips the wizard subset")
    func rruleRoundTrip() {
        #expect(RRULE.parseCadence("FREQ=DAILY") == .daily)
        #expect(RRULE.parseCadence("FREQ=WEEKLY;BYDAY=MO,WE,FR") == .weekdays([.mon, .wed, .fri]))
        #expect(RRULE.parseCadence("FREQ=MONTHLY;BYMONTHDAY=15") == .monthly(day: 15))
        #expect(RRULE.parseCadence("FREQ=MONTHLY;INTERVAL=3;BYMONTHDAY=1") == .everyNMonths(interval: 3, day: 1))
        #expect(RRULE.parseCadence("FREQ=YEARLY;BYMONTH=1;BYMONTHDAY=1") == .yearly(month: 1, day: 1))
        #expect(RRULE.parseCadence("not-an-rrule") == nil)
        // Encode mirrors the wizard ordering (Mon→Sun).
        #expect(RRULE.encode(.weekdays([.fri, .mon, .wed])) == "FREQ=WEEKLY;BYDAY=MO,WE,FR")
        #expect(RRULE.encode(.everyNWeeks(interval: 2, days: [.wed])) == "FREQ=WEEKLY;INTERVAL=2;BYDAY=WE")
        #expect(RRULE.encode(.rolling(intervalDays: 30)) == nil)
    }
}
