import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **MED (c), (d), (f) — `autoRecorded`, the carry-over caveat and the update path.**
@Suite("MED — automatically recorded doses (c)")
struct MedicationAutoRecordedTests {
    private static func ledgerRow(_ intake: String) throws -> MedicationDoseHistoryRow {
        let json = """
        {"kind":"slot","at":"2026-10-25T19:00:00.000Z","timeOfDay":"20:00","status":"taken_on_time","intake":\(intake)}
        """
        return try JSONDecoder.hlDefault.decode(MedicationDoseHistoryRow.self, from: Data(json.utf8))
    }

    @Test("autoRecorded true on a taken dose is labelled; false, absent and skipped are not")
    func ledgerFlag() throws {
        let base = #""id":"i-1","scheduledFor":"2026-10-25T19:00:00.000Z","takenAt":"2026-10-25T19:00:00.000Z","#
        let auto = try Self.ledgerRow("{" + base + #""skipped":false,"autoRecorded":true}"#)
        let manual = try Self.ledgerRow("{" + base + #""skipped":false,"autoRecorded":false}"#)
        let older = try Self.ledgerRow("{" + base + #""skipped":false}"#)
        let skipped = try Self
            .ledgerRow(#"{"id":"i-2","scheduledFor":"2026-10-25T19:00:00.000Z","takenAt":null,"skipped":true,"autoRecorded":true}"#)
        #expect(auto.intake?.isAutoRecordedTake == true)
        #expect(manual.intake?.isAutoRecordedTake == false)
        #expect(older.intake?.autoRecorded == nil)
        #expect(older.intake?.isAutoRecordedTake == false)
        #expect(skipped.intake?.isAutoRecordedTake == false)
    }

    @Test("The paginated intake list reads the flag too")
    func paginatedFlag() throws {
        let json = #"{"id":"e-1","takenAt":"2026-10-25T19:00:00.000Z","skipped":false,"scheduledFor":"2026-10-25T19:00:00.000Z","autoRecorded":true}"#
        let event = try JSONDecoder.hlDefault.decode(PaginatedIntakeEvent.self, from: Data(json.utf8))
        #expect(event.isAutoRecordedTake)
        let old = try JSONDecoder.hlDefault.decode(
            PaginatedIntakeEvent.self,
            from: Data(#"{"id":"e-2","takenAt":null,"skipped":false,"scheduledFor":"2026-10-25T19:00:00.000Z"}"#.utf8)
        )
        #expect(!old.isAutoRecordedTake)
    }

    @Test("The caption is a catalog text in German and English")
    func captionCopy() throws {
        let entry = try CatalogProbe.entry("med.history.auto_recorded")
        #expect(entry["de"] == "Automatisch erfasst")
        #expect(entry["en"] == "Recorded automatically")
    }

    @Test("autoMarkTakenSince is decoded")
    func autoMarkTakenSince() throws {
        let json = #"{"id":"m","name":"Vitamin D","dose":"1","autoMarkTaken":true,"autoMarkTakenSince":"2026-10-01T06:00:00.000Z"}"#
        let med = try JSONDecoder.hlDefault.decode(MedicationWireDTO.self, from: Data(json.utf8)).toDomain()
        #expect(med.autoMarkTakenSince == ISO8601DateFormatter().date(from: "2026-10-01T06:00:00Z"))
        #expect(med.remindersActive == false, "auto-recorded medications never remind")
    }
}

@Suite("MED — carry-over caveat on the effect card (d)")
struct MedicationEfficacyCaveatTests {
    private static func target(_ segmented: String?) throws -> MedicationEfficacyDTO.Target {
        var json = #"{"kind":"metric","key":"BLOOD_PRESSURE_SYS","label":"Systolisch","unit":"mmHg","primary":true,"#
            + #""series":[],"beforeAfter":{"present":false,"reason":"no_data"},"levelShift":null"#
        if let segmented { json += #","segmented":"# + segmented }
        json += "}"
        return try JSONDecoder.hlDefault.decode(MedicationEfficacyDTO.Target.self, from: Data(json.utf8))
    }

    private static let fit = #"{"n":60,"df":56,"rSquared":0.4,"residualAutocorrelation":0.7,"hacLag":7,"autocorrelationCaveat":"#

    @Test("Line only when the server says true")
    func onlyTrue() throws {
        let yes = try Self.target(#"{"present":true,"fit":"# + Self.fit + "true}}")
        let no = try Self.target(#"{"present":true,"fit":"# + Self.fit + "false}}")
        #expect(yes.showsAutocorrelationCaveat)
        #expect(yes.autocorrelationCaveatText == String(localized: "med.wirkung.autocorrelationCaveat"))
        #expect(!no.showsAutocorrelationCaveat)
        #expect(no.autocorrelationCaveatText == nil)
    }

    @Test("Older server (no segmented), null fit and an odd shape: no line, card still decodes")
    func absentAndOdd() throws {
        #expect(try !Self.target(nil).showsAutocorrelationCaveat)
        #expect(try !Self.target("null").showsAutocorrelationCaveat)
        #expect(try !Self.target(#"{"present":false,"reason":"no_start","fit":null}"#).showsAutocorrelationCaveat)
        #expect(try !Self.target(#"{"fit":"broken"}"#).showsAutocorrelationCaveat)
    }

    @Test("The caveat text exists in German and English")
    func copy() throws {
        let entry = try CatalogProbe.entry("med.wirkung.autocorrelationCaveat")
        #expect(entry["de"]?.isEmpty == false)
        #expect(entry["en"]?.isEmpty == false)
    }
}

/// **(f) Update path (rule 11)** — the medication list is cached as encoded
/// `[Medication]` (SWR `.medicationsList`). A 1.4.1 blob has none of the new
/// keys; it must decode and behave like 1.4: End via PUT, no Start, reminders
/// as before.
@Suite("MED — 1.4.1 cache and server without fields (f)")
struct MedicationMEDUpdatePathTests {
    /// A cached row in the shape 1.4.1 wrote: every key its `Medication` had,
    /// none of the course-action keys (they are optional and encoded only when
    /// set, so a row without them encodes byte-for-byte like 1.4.1's).
    static var cachedBlob: String {
        var row = Medication(
            id: "med-1",
            name: "Lisinopril",
            dose: "5 mg",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 20, minute: 0)]),
            courseStatus: .current,
            intakeActionable: true
        )
        row.remindersActive = true
        let data = (try? JSONEncoder.hlDefault.encode([row])) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    @Test("The 1.4.1-shaped blob carries none of the new keys")
    func blobHasNoNewKeys() throws {
        let rows = try JSONSerialization.jsonObject(with: Data(Self.cachedBlob.utf8)) as? [[String: Any]] ?? []
        let keys = Set(rows.first?.keys.map(\.self) ?? [])
        #expect(keys.contains("remindersActive"))
        #expect(keys.isDisjoint(with: ["endedAt", "canEndCourse", "canStartCourse", "autoMarkTakenSince"]))
    }

    @Test("A 1.4.1 cache blob decodes with every new field nil")
    func cacheBlobDecodes() throws {
        let rows = try JSONDecoder.hlDefault.decode([Medication].self, from: Data(Self.cachedBlob.utf8))
        let row = try #require(rows.first)
        #expect(row.endedAt == nil)
        #expect(row.canEndCourse == nil)
        #expect(row.canStartCourse == nil)
        #expect(row.autoMarkTakenSince == nil)
        #expect(!row.serverEndsCourseNow)
        #expect(row.offersEndCourse)
        #expect(!row.offersCourseStart)
        #expect(MedicationReminderDeliveryPolicy.plansLocalReminder(for: row))
    }

    @Test("Round trip keeps the new fields, and an empty encode adds no new keys")
    func roundTrip() throws {
        var row = try JSONDecoder.hlDefault.decode([Medication].self, from: Data(Self.cachedBlob.utf8))[0]
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder.hlDefault.encode(row)) as? [String: Any] ?? [:]
        for key in ["endedAt", "canEndCourse", "canStartCourse", "autoMarkTakenSince"] {
            #expect(plain[key] == nil, "\(key) stays out of an old row's cache")
        }
        row.canEndCourse = true
        row.canStartCourse = false
        let back = try JSONDecoder.hlDefault.decode(Medication.self, from: JSONEncoder.hlDefault.encode(row))
        #expect(back.canEndCourse == true)
        #expect(back.canStartCourse == false)
    }

    @Test("A 1.45 server row (no fields) decodes and keeps 1.4 behaviour")
    func serverWithoutFields() throws {
        let row = try MedicationCourseEndTests.wireRow(canEndCourse: nil)
        #expect(row.canEndCourse == nil && row.endedAt == nil)
        #expect(!row.serverEndsCourseNow)
    }

    @Test("Copies keep the new fields (schedule swap, Apple Health stamp)")
    func copiesKeepFields() throws {
        var row = try MedicationCourseEndTests.wireRow(canEndCourse: true, canStartCourse: false)
        row.autoMarkTakenSince = Date(timeIntervalSince1970: 1_790_000_000)
        let swapped = row.replacingSchedule(MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)]))
        #expect(swapped.canEndCourse == true && swapped.canStartCourse == false)
        #expect(swapped.autoMarkTakenSince == row.autoMarkTakenSince)
        #expect(swapped.schedule.times == [TimeOfDay(hour: 8, minute: 0)])
        let stamped = row.withAppleHealthProvenance(externalId: "hk-1")
        #expect(stamped.canEndCourse == true && stamped.externalId == "hk-1")
        #expect(stamped.isAppleHealthMirrored)
    }
}

/// Reads the app's string catalog from the source tree (no bundle lookup, so
/// the result does not depend on the test language).
enum CatalogProbe {
    static func entry(_ key: String) throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HealthLog/Resources/Localizable.xcstrings")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = root?["strings"] as? [String: Any]
        let locs = (strings?[key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
        var out: [String: String] = [:]
        for (lang, value) in locs {
            if let unit = (value as? [String: Any])?["stringUnit"] as? [String: Any], let text = unit["value"] as? String {
                out[lang] = text
            }
        }
        return out
    }
}

// swiftlint:enable force_unwrapping
