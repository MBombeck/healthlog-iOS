import Foundation
@testable import HealthLog
import Testing

/// **Build 6.4 — the Vorsorge cadence editor's wire contract.**
///
/// `MeasurementReminderRow.editingPatch(…)` and `MeasurementReminderCreate` are
/// pure functions so the exact omitted/null/set semantics against
/// `PATCH /api/measurement-reminders/{id}` are testable end-to-end through the
/// encoder — the trap that once let the RRULE-preserving rule be documented for
/// months without ever being implemented.
///
/// The server (v1.32.1, #62) recomputes `nextDueAt` keyed off
/// `Object.hasOwn(updateData, …)`, so an OMITTED cadence field truly means
/// "leave it alone" while an explicit `null` clears — the two must never
/// collapse. These tests pin that distinction on the wire (absent vs `null` vs
/// value) for cadence switching, the `anchorDate` null-out, and the clearable
/// `location` / `measurementType`.
@Suite("MeasurementReminderUpdate — tri-state cadence editor")
struct MeasurementReminderPatchTests {
    // MARK: - Fixtures

    private func row(
        intervalDays: Int? = nil,
        rrule: String? = nil,
        measurementType: String? = nil,
        anchorDate: Date? = nil,
        location: String? = nil
    ) -> MeasurementReminderRow {
        MeasurementReminderRow(
            id: "rem-1",
            label: "Zahnarzt",
            measurementType: measurementType,
            intervalDays: intervalDays,
            rrule: rrule,
            endsOn: nil,
            origin: .vorsorge,
            notifyHour: 9,
            location: location,
            nextDueAt: nil,
            lastSatisfiedAt: nil,
            enabled: true,
            anchorDate: anchorDate
        )
    }

    /// Encode a patch and return its top-level JSON object so a test can tell
    /// an ABSENT key (`obj[key] == nil`) from an explicit `null`
    /// (`obj[key] is NSNull`) from a set value.
    private func encoded(_ patch: MeasurementReminderUpdate) throws -> [String: Any] {
        let data = try JSONEncoder.hlDefault.encode(patch)
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try #require(object as? [String: Any])
    }

    private func isNull(_ json: [String: Any], _ key: String) -> Bool {
        json[key] is NSNull
    }

    private func isAbsent(_ json: [String: Any], _ key: String) -> Bool {
        json[key] == nil
    }

    // MARK: - Cadence exclusivity + switching

    /// The original regression: an rrule reminder edited for its label only must
    /// NOT carry `intervalDays` (that clobbered the schedule). On the RRULE path
    /// the interval is omitted; the rule is sent explicitly (the form can now
    /// edit it), which is what carries an edit or a switch onto a schedule.
    @Test("RRULE reminder, label-only edit: interval absent, rrule set")
    func rruleLabelEditOmitsInterval() throws {
        let patch = MeasurementReminderRow.editingPatch(
            for: row(rrule: "FREQ=YEARLY;BYMONTH=3"),
            label: "Zahnarzt (neu)",
            measurementType: nil,
            cadence: .rrule("FREQ=YEARLY;BYMONTH=3"),
            anchorDate: nil,
            notifyHour: 9,
            location: nil,
            enabled: true
        )
        let json = try encoded(patch)
        #expect(isAbsent(json, "intervalDays"), "interval must be omitted so the server's exclusivity clears it")
        #expect(json["rrule"] as? String == "FREQ=YEARLY;BYMONTH=3")
        #expect(json["label"] as? String == "Zahnarzt (neu)")
    }

    @Test("Interval reminder carries its interval, omits rrule")
    func intervalReminderCarriesInterval() throws {
        let patch = MeasurementReminderRow.editingPatch(
            for: row(intervalDays: 90),
            label: "Blutdruck messen",
            measurementType: "BLOOD_PRESSURE_SYS",
            cadence: .interval(120),
            anchorDate: nil,
            notifyHour: 8,
            location: nil,
            enabled: true
        )
        let json = try encoded(patch)
        #expect(json["intervalDays"] as? Int == 120)
        #expect(isAbsent(json, "rrule"), "the server clears rrule when interval is set + rrule omitted")
        #expect(json["measurementType"] as? String == "BLOOD_PRESSURE_SYS")
        #expect(json["notifyHour"] as? Int == 8)
    }

    /// Switching an interval reminder ONTO an RRULE schedule: rrule set, interval
    /// omitted. The server's mutual-exclusivity nulls the (now stale) interval,
    /// and the #62 fix recomputes `nextDueAt` off the RRULE, not the old interval.
    @Test("Switch interval → RRULE: rrule set, interval omitted")
    func switchIntervalToRRule() throws {
        let patch = MeasurementReminderRow.editingPatch(
            for: row(intervalDays: 30),
            label: "Zahnarzt",
            measurementType: nil,
            cadence: .rrule("FREQ=MONTHLY;INTERVAL=6"),
            anchorDate: nil,
            notifyHour: 9,
            location: nil,
            enabled: true
        )
        let json = try encoded(patch)
        #expect(json["rrule"] as? String == "FREQ=MONTHLY;INTERVAL=6")
        #expect(isAbsent(json, "intervalDays"))
    }

    /// Switching an RRULE reminder back onto a rolling interval: interval set,
    /// rrule omitted → server clears rrule.
    @Test("Switch RRULE → interval: interval set, rrule omitted")
    func switchRRuleToInterval() throws {
        let patch = MeasurementReminderRow.editingPatch(
            for: row(rrule: "FREQ=YEARLY"),
            label: "Zahnarzt",
            measurementType: nil,
            cadence: .interval(45),
            anchorDate: nil,
            notifyHour: 9,
            location: nil,
            enabled: true
        )
        let json = try encoded(patch)
        #expect(json["intervalDays"] as? Int == 45)
        #expect(isAbsent(json, "rrule"))
    }

    // MARK: - anchorDate tri-state

    @Test("anchorDate cleared: explicit null on the wire, not absent")
    func anchorDateClear() throws {
        let hadAnchor = row(intervalDays: 30, anchorDate: Date(timeIntervalSince1970: 1_700_000_000))
        let patch = MeasurementReminderRow.editingPatch(
            for: hadAnchor,
            label: "Zahnarzt",
            measurementType: nil,
            cadence: .interval(30),
            anchorDate: nil, // user turned the anchor toggle off
            notifyHour: 9,
            location: nil,
            enabled: true
        )
        let json = try encoded(patch)
        #expect(isNull(json, "anchorDate"), "a removed anchor must send explicit null so the server clears it")
        #expect(!isAbsent(json, "anchorDate"))
    }

    @Test("anchorDate set: encoded as an ISO string")
    func anchorDateSet() throws {
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let patch = MeasurementReminderRow.editingPatch(
            for: row(intervalDays: 30),
            label: "Zahnarzt",
            measurementType: nil,
            cadence: .interval(30),
            anchorDate: anchor,
            notifyHour: 9,
            location: nil,
            enabled: true
        )
        let json = try encoded(patch)
        let iso = try #require(json["anchorDate"] as? String)
        #expect(iso.contains("2023-11-14"), "iso8601 encoding of the anchor instant")
    }

    @Test("anchorDate untouched (never had one, none set): omitted")
    func anchorDateUnchanged() throws {
        let patch = MeasurementReminderRow.editingPatch(
            for: row(intervalDays: 30),
            label: "Zahnarzt",
            measurementType: nil,
            cadence: .interval(30),
            anchorDate: nil,
            notifyHour: 9,
            location: nil,
            enabled: true
        )
        let json = try encoded(patch)
        #expect(isAbsent(json, "anchorDate"))
    }

    // MARK: - location + measurementType tri-state

    @Test("location cleared → null; set → value; never-had + empty → absent")
    func locationTriState() throws {
        let cleared = MeasurementReminderRow.editingPatch(
            for: row(intervalDays: 30, location: "Praxis Dr. A"),
            label: "Zahnarzt", measurementType: nil, cadence: .interval(30),
            anchorDate: nil, notifyHour: 9, location: "   ", enabled: true
        )
        #expect(try isNull(encoded(cleared), "location"))

        let set = MeasurementReminderRow.editingPatch(
            for: row(intervalDays: 30),
            label: "Zahnarzt", measurementType: nil, cadence: .interval(30),
            anchorDate: nil, notifyHour: 9, location: "  Praxis Dr. B  ", enabled: true
        )
        #expect(try encoded(set)["location"] as? String == "Praxis Dr. B", "trimmed + set")

        let absent = MeasurementReminderRow.editingPatch(
            for: row(intervalDays: 30),
            label: "Zahnarzt", measurementType: nil, cadence: .interval(30),
            anchorDate: nil, notifyHour: 9, location: "", enabled: true
        )
        #expect(try isAbsent(encoded(absent), "location"))
    }

    @Test("measurementType cleared to free-text sends explicit null")
    func measurementTypeClear() throws {
        let patch = MeasurementReminderRow.editingPatch(
            for: row(intervalDays: 30, measurementType: "WEIGHT"),
            label: "Zahnarzt",
            measurementType: nil, // switched to free-text
            cadence: .interval(30),
            anchorDate: nil,
            notifyHour: 9,
            location: nil,
            enabled: true
        )
        #expect(try isNull(encoded(patch), "measurementType"))
    }

    // MARK: - enabled (per-reminder toggle)

    @Test("enabled is always carried on an edit")
    func enabledCarried() throws {
        let patch = MeasurementReminderRow.editingPatch(
            for: row(intervalDays: 30),
            label: "Zahnarzt", measurementType: nil, cadence: .interval(30),
            anchorDate: nil, notifyHour: 9, location: nil, enabled: false
        )
        #expect(try encoded(patch)["enabled"] as? Bool == false)
    }

    // MARK: - isRRuleScheduled predicate

    @Test("isRRuleScheduled: only a non-empty rule counts")
    func rruleScheduledPredicate() {
        #expect(row(rrule: "FREQ=YEARLY").isRRuleScheduled)
        #expect(!row(intervalDays: 30).isRRuleScheduled)
        #expect(!row(intervalDays: 30, rrule: "").isRRuleScheduled)
    }

    // MARK: - Create body

    @Test("Create with an interval cadence: intervalDays set, rrule absent")
    func createInterval() throws {
        let body = MeasurementReminderCreate(
            label: "Blutdruck",
            measurementType: "BLOOD_PRESSURE_SYS",
            cadence: .interval(7),
            anchorDate: nil,
            notifyHour: 8,
            location: "zu Hause",
            enabled: true
        )
        let data = try JSONEncoder.hlDefault.encode(body)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["intervalDays"] as? Int == 7)
        #expect(json["rrule"] == nil)
        #expect(json["location"] as? String == "zu Hause")
        #expect(json["enabled"] as? Bool == true)
    }

    @Test("Create with an RRULE cadence: rrule set, intervalDays absent, empty location dropped")
    func createRRule() throws {
        let body = MeasurementReminderCreate(
            label: "Krebsvorsorge",
            measurementType: nil,
            cadence: .rrule("FREQ=YEARLY"),
            anchorDate: Date(timeIntervalSince1970: 1_700_000_000),
            notifyHour: 9,
            location: "   ",
            enabled: false
        )
        let data = try JSONEncoder.hlDefault.encode(body)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["rrule"] as? String == "FREQ=YEARLY")
        #expect(json["intervalDays"] == nil)
        #expect(json["location"] == nil, "a whitespace-only location is dropped, not sent")
        #expect((json["anchorDate"] as? String)?.contains("2023-11-14") == true)
        #expect(json["enabled"] as? Bool == false)
    }
}
