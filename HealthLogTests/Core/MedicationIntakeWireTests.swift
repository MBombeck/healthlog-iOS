import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Locks the wire shape of `POST /api/medications/intake` against
/// server v1.4.26 (`src/app/api/medications/intake/route.ts:204` —
/// raw Prisma row `MedicationIntakeEvent` without synthesised `status`,
/// field name `scheduledFor` not `scheduledAt`).
///
/// Pre-v0.4.0 iOS decoded the response into `MedicationIntake` directly,
/// hitting `keyNotFound("scheduledAt")` after the write succeeded.
/// Optimistic store updates were masked by the fake error.
/// A4-Audit row 4.
@Suite("MedicationIntake POST wire shape")
struct MedicationIntakeWireTests {
    @Test("Raw Prisma row decodes via MedicationIntakeWireDTO")
    func rawRowDecodes() throws {
        let json = Data(#"""
        {
            "id": "intake_1",
            "userId": "u_1",
            "medicationId": "med_1",
            "scheduledFor": "2026-05-15T08:00:00.000Z",
            "takenAt": "2026-05-15T08:14:18.000Z",
            "skipped": false,
            "source": "MANUAL",
            "idempotencyKey": null,
            "createdAt": "2026-05-15T08:14:18.500Z",
            "injectionSite": null
        }
        """#.utf8)
        let wire = try JSONDecoder.hlDefault.decode(MedicationIntakeWireDTO.self, from: json)
        #expect(wire.id == "intake_1")
        #expect(wire.medicationId == "med_1")
        #expect(wire.takenAt != nil)
        #expect(wire.skipped == false)
    }

    @Test("toDomain synthesises status from skipped + takenAt flags")
    func statusSynthesis() {
        let base = MedicationIntakeWireDTO(
            id: "i",
            medicationId: "m",
            scheduledFor: Date(timeIntervalSince1970: 0),
            takenAt: nil,
            skipped: false,
            snoozedUntil: nil
        )
        #expect(base.toDomain().status == .pending)

        let taken = MedicationIntakeWireDTO(
            id: "i", medicationId: "m",
            scheduledFor: Date(timeIntervalSince1970: 0),
            takenAt: Date(timeIntervalSince1970: 60),
            skipped: false, snoozedUntil: nil
        )
        #expect(taken.toDomain().status == .taken)

        let skipped = MedicationIntakeWireDTO(
            id: "i", medicationId: "m",
            scheduledFor: Date(timeIntervalSince1970: 0),
            takenAt: nil, skipped: true, snoozedUntil: nil
        )
        #expect(skipped.toDomain().status == .skipped)

        let future = Date(timeIntervalSinceNow: 600)
        let snoozed = MedicationIntakeWireDTO(
            id: "i", medicationId: "m",
            scheduledFor: Date(timeIntervalSince1970: 0),
            takenAt: nil, skipped: false, snoozedUntil: future
        )
        #expect(snoozed.toDomain().status == .snoozed)
    }

    @Test("toDomain maps scheduledFor → scheduledAt without truncating")
    func scheduledForMapping() {
        let when = Date(timeIntervalSince1970: 1_715_000_000)
        let wire = MedicationIntakeWireDTO(
            id: "i", medicationId: "m",
            scheduledFor: when, takenAt: nil, skipped: false
        )
        #expect(wire.toDomain().scheduledAt == when)
    }
}

/// Locks `GET /api/medications/intake?scope=compliance` shape.
/// Server src/app/api/medications/intake/route.ts:131-135 emits
/// `{ date: "YYYY-MM-DD", scheduled: Int, taken: Int }` — `date` is a
/// **day-key string**, not an ISO timestamp.
///
/// Pre-v0.4.0 iOS used `ISO8601DateFormatter` which rejected `"2026-05-15"`
/// (no T...Z) → whole compliance heatmap was broken. A4-Audit row 30.
/// Fixed in v0.4.0 by the unified `JSONDecoder.hlDefault` accepting
/// day-keys + parsing them as midnight UTC.
@Suite("ComplianceDay day-key parsing")
struct ComplianceDayDecodingTests {
    @Test("Day-key string decodes via JSONDecoder.hlDefault")
    func dayKeyDecodes() throws {
        let json = Data(#"""
        {
            "date": "2026-05-15",
            "scheduled": 3,
            "taken": 2
        }
        """#.utf8)
        let day = try JSONDecoder.hlDefault.decode(ComplianceDay.self, from: json)
        let components = try Calendar(identifier: .iso8601).dateComponents(
            in: #require(TimeZone(identifier: "UTC")),
            from: day.date
        )
        #expect(components.year == 2026)
        #expect(components.month == 5)
        #expect(components.day == 15)
        #expect(day.scheduled == 3)
        #expect(day.taken == 2)
        #expect(abs(day.rate - 2.0 / 3.0) < 0.001)
    }

    @Test("Full compliance-array fixture round-trips")
    func arrayDecodes() throws {
        let json = Data(#"""
        [
            {"date": "2026-05-13", "scheduled": 3, "taken": 3},
            {"date": "2026-05-14", "scheduled": 3, "taken": 2},
            {"date": "2026-05-15", "scheduled": 3, "taken": 0}
        ]
        """#.utf8)
        let days = try JSONDecoder.hlDefault.decode([ComplianceDay].self, from: json)
        #expect(days.count == 3)
        #expect(days[0].rate == 1.0)
        #expect(days[2].rate == 0.0)
    }
}
