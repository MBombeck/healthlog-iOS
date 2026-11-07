import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **MED-PLUS (1.5.0, #126 3.11) — "record doses automatically" and
/// `remindersActive`.**
///
/// The switch reads and writes `autoMarkTaken` (server v1.42.2), is offered
/// only where the server knows the field and the caller may change
/// medications, and can only take reminders away: no double and no phantom
/// reminder, also across the clock change and from a 1.4.1 cache.
@MainActor
@Suite("MED-PLUS — automatically taken and reminders", .serialized, .mockURLSession)
struct MedicationAutoMarkTakenTests {
    /// A daily 20:00 medication as the server sends it, plus `extra` fields.
    nonisolated static func row(extra: [String] = []) throws -> Medication {
        let fields = [
            "\"id\":\"med-1\"", "\"name\":\"Vitamin D\"", "\"dose\":\"1000 IE\"", "\"active\":true",
            "\"notificationsEnabled\":true", "\"courseStatus\":\"CURRENT\"", "\"intakeActionable\":true",
            "\"schedules\":[{\"windowStart\":\"20:00\",\"timesOfDay\":[\"20:00\"],\"scheduleType\":\"SCHEDULED\"}]"
        ] + extra
        let json = "{" + fields.joined(separator: ",") + "}"
        return try JSONDecoder.hlDefault.decode(MedicationWireDTO.self, from: Data(json.utf8)).toDomain()
    }

    private final class WriteBox: @unchecked Sendable {
        var sent: [String: Any] = [:]
        var answerOn = true
    }

    private nonisolated static func readStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private static func makeClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil, cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app", appVersion: "0.1.0", buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    // MARK: - Switch: offered, read, written

    @Test("Server without the field: no switch, nothing sent; with it: switch, read as served")
    func withAndWithoutField() throws {
        let old = try Self.row()
        #expect(old.autoMarkTaken == nil)
        #expect(!old.offersAutoMarkTakenSwitch(canManage: true))
        #expect(MedicationAutoMarkTakenFormValue(from: old).write == nil)

        let on = try Self.row(extra: [
            #""autoMarkTaken":true"#, #""autoMarkTakenSince":"2026-11-01T08:00:00.000Z""#, #""remindersActive":false"#
        ])
        #expect(on.autoMarkTaken == true)
        #expect(on.offersAutoMarkTakenSwitch(canManage: true))
        #expect(on.autoMarkTakenSince == ISO8601DateFormatter().date(from: "2026-11-01T08:00:00Z"))
        let value = MedicationAutoMarkTakenFormValue(from: on)
        #expect(value.isOn && value.server == true)
        #expect(MedicationAutoMarkTakenSection.sinceText(value: value, since: on.autoMarkTakenSince) != nil)
    }

    @Test("A delegate without rights, an as-needed and a record-only medication get no switch")
    func noSwitchWithoutRights() throws {
        let row = try Self.row(extra: [#""autoMarkTaken":false"#, #""remindersActive":true"#])
        #expect(!row.offersAutoMarkTakenSwitch(canManage: false))
        let prn = try Self.row(extra: [#""autoMarkTaken":false"#, #""asNeeded":true"#])
        #expect(!prn.offersAutoMarkTakenSwitch(canManage: true))
        let record = try Self.row(extra: [#""autoMarkTaken":false"#, #""trackIntake":false"#])
        #expect(!record.offersAutoMarkTakenSwitch(canManage: true))

        let entries = try JSONDecoder.hlDefault.decode([AccountAccessEntry].self, from: Data(#"""
        [{"accountId":"a-1","username":"reader","level":"read","recordKind":"shared","sections":["medications"],"canWrite":false},
         {"accountId":"a-2","username":"carer","level":"write","recordKind":"shared","sections":["medications"],"canWrite":true},
         {"accountId":"a-3","username":"labs","level":"write","recordKind":"shared","sections":["labs"],"canWrite":true}]
        """#.utf8))
        func access(_ entry: AccountAccessEntry) -> AccountAccess {
            AccountAccess(accounts: entries, active: entry, recordKind: .shared, canSwitch: true)
        }
        #expect(!access(entries[0]).canManageMedications, "read-only delegate")
        #expect(access(entries[1]).canManageMedications)
        #expect(!access(entries[2]).canManageMedications, "grant does not reach medications")
        #expect(AccountAccess.ownerOnly.canManageMedications, "own record")
    }

    @Test("The PUT names autoMarkTaken only when the switch changed")
    func patchNamesOnlyAChange() throws {
        let row = try Self.row(extra: [#""autoMarkTaken":false"#, #""remindersActive":true"#])
        var draft = MedicationEditDraft(prefill: EditMedicationFormState(from: row))
        #expect(draft.patch(for: row).autoMarkTaken == nil)
        draft.autoMarkTaken.isOn = true
        #expect(draft.patch(for: row).autoMarkTaken == true)
        let body = try JSONSerialization.jsonObject(with: JSONEncoder.hlDefault.encode(draft.patch(for: row))) as? [String: Any]
        #expect(body?["autoMarkTaken"] as? Bool == true)
        #expect(body?["schedules"] == nil, "the schedule stays untouched")

        let old = try Self.row()
        let untouched = try JSONSerialization.jsonObject(
            with: JSONEncoder.hlDefault.encode(MedicationEditDraft(prefill: EditMedicationFormState(from: old)).patch(for: old))
        ) as? [String: Any]
        #expect(untouched?["autoMarkTaken"] == nil, "an older server never sees the key")
    }

    @Test("Switching on through the store: PUT carries the flag, the answer stops the reminder; off arms it again")
    func storeWriteStopsAndRestoresReminder() async throws {
        let client = Self.makeClient()
        let store = try MedicationsStore(repo: MedicationsRepository(api: client, outbox: OutboxQueue(inMemory: true)))
        let off = try Self.row(extra: [#""autoMarkTaken":false"#, #""remindersActive":true"#])
        store._testForceSet(medications: [off])
        #expect(MedicationReminderDeliveryPolicy.plansLocalReminder(for: off))

        let box = WriteBox()
        MockURLProtocol.install { req in
            let raw = req.httpBody ?? Self.readStream(req.httpBodyStream) ?? Data()
            box.sent = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
            let flags = box.answerOn
                ? #""autoMarkTaken":true,"autoMarkTakenSince":"2026-11-05T09:00:00.000Z","remindersActive":false"#
                : #""autoMarkTaken":false,"autoMarkTakenSince":null,"remindersActive":true"#
            let payload = #"{"data":{"id":"med-1","name":"Vitamin D","dose":"1000 IE","active":true,"notificationsEnabled":true,"#
                + #""schedules":[{"windowStart":"20:00","timesOfDay":["20:00"],"scheduleType":"SCHEDULED"}],"# + flags + "}}"
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }

        var patch = MedicationsRepository.MedicationPatch()
        patch.autoMarkTaken = true
        #expect(await store.update(id: "med-1", patch: patch) == .success)
        #expect(box.sent["autoMarkTaken"] as? Bool == true)
        let on = try #require(store.medications.first)
        #expect(on.autoMarkTaken == true)
        #expect(!MedicationReminderDeliveryPolicy.plansLocalReminder(for: on), "no reminder while doses are recorded")

        box.answerOn = false
        patch.autoMarkTaken = false
        #expect(await store.update(id: "med-1", patch: patch) == .success)
        let back = try #require(store.medications.first)
        #expect(MedicationReminderDeliveryPolicy.plansLocalReminder(for: back))
    }

    // MARK: - Reminders: no double, no phantom, across the clock change

    /// A daily 20:00 course over the autumn clock change in Berlin (it ends,
    /// so it rides the runway and every armed instant is listed).
    nonisolated static func dstCourse(autoMarkTaken: Bool?) throws -> Medication {
        var extra = [#""startsOn":"2026-10-20""#, #""endsOn":"2026-10-28""#]
        if let autoMarkTaken {
            extra += [#""autoMarkTaken":\#(autoMarkTaken)"#, #""remindersActive":\#(!autoMarkTaken)"#]
        }
        return try row(extra: extra)
    }

    @Test(
        "Across 25.10.2026 (Berlin, 25 hours): one 20:00 reminder per day when off, none when on",
        arguments: [false, true]
    )
    func dstPlan(autoMarkOn: Bool) throws {
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-24T10:00:00Z"))
        let plan = try MedicationReminderRunway.plan(for: [Self.dstCourse(autoMarkTaken: autoMarkOn)], now: now, timeZone: berlin)
        let armed = plan.runways.values.flatMap(\.occurrences)
        if autoMarkOn {
            #expect(plan.armedRequestCount == 0, "no phantom reminder while doses are recorded")
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = berlin
        let days = armed.map { calendar.dateComponents([.month, .day], from: $0) }
        #expect(Set(days).count == armed.count, "no day twice: no double reminder")
        #expect(armed.allSatisfy { calendar.component(.hour, from: $0) == 20 && calendar.component(.minute, from: $0) == 0 })
        let sunday = armed.filter { calendar.component(.day, from: $0) == 25 }
        #expect(sunday.count == 1, "the 25-hour day reminds once")
        #expect(sunday.first == ISO8601DateFormatter().date(from: "2026-10-25T19:00:00Z"), "20:00 CET, not CEST")
        #expect(armed.allSatisfy { $0 > now })
    }

    // MARK: - remindersActive in the dose subtitle

    @Test("'No reminders' joins the dose only when the server says so for a medication that would remind")
    func subtitle() throws {
        let quiet = try Self.row(extra: [#""remindersActive":false"#, #""autoMarkTaken":false"#])
        #expect(quiet.saysNoReminders)
        let text = MedicationHeroSection.subtitle(quiet)
        #expect(text.hasPrefix("1000 IE") && text != "1000 IE")
        #expect(!text.contains("med.hero"))

        #expect(try MedicationHeroSection.subtitle(Self.row()) == "1000 IE", "older server: as before")
        #expect(try MedicationHeroSection.subtitle(Self.row(extra: [#""remindersActive":true"#])) == "1000 IE")
        let ended = try Self.row(extra: [#""remindersActive":false"#, #""endedAt":"2026-10-25T14:00:00.000Z""#])
        #expect(!ended.saysNoReminders, "an ended course says so through its badge")
        let prn = try Self.row(extra: [#""remindersActive":false"#, #""asNeeded":true"#])
        #expect(!prn.saysNoReminders)
        for key in ["med.hero.dose.noReminders %@", "med.edit.autoMarkTaken.label", "med.edit.autoMarkTaken.helper"] {
            let entry = try CatalogProbe.entry(key)
            #expect(entry["de"]?.isEmpty == false && entry["en"]?.isEmpty == false, "\(key) de/en")
        }
    }

    // MARK: - Update path from 1.4.1 (rule 11)

    @Test("A 1.4.1 cache blob decodes without the new fields and plans as before; a folded row stays quiet")
    func updatePath() throws {
        let rows = try JSONDecoder.hlDefault.decode([Medication].self, from: Data(MedicationMEDUpdatePathTests.cachedBlob.utf8))
        let row = try #require(rows.first)
        #expect(row.autoMarkTaken == nil && row.courseCount == nil && row.previousCourseEndedOn == nil)
        #expect(!row.offersAutoMarkTakenSwitch(canManage: true))
        #expect(!row.offersCourseHistory)
        #expect(MedicationReminderDeliveryPolicy.plansLocalReminder(for: row))
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder.hlDefault.encode(row)) as? [String: Any] ?? [:]
        for key in ["autoMarkTaken", "courseCount", "previousCourseEndedOn"] {
            #expect(plain[key] == nil, "\(key) stays out of an old row's cache")
        }

        // 1.4.1 cached a row whose server had auto-recording on as
        // `remindersActive: false` (folded); it stays quiet after the update.
        var folded = row
        folded.remindersActive = false
        let data = try JSONEncoder.hlDefault.encode([folded])
        let decoded = try #require(try JSONDecoder.hlDefault.decode([Medication].self, from: data).first)
        #expect(!MedicationReminderDeliveryPolicy.plansLocalReminder(for: decoded))

        // The new fields survive a round trip through the cache.
        var fresh = try Self.row(extra: [#""autoMarkTaken":true"#, #""courseCount":2"#, #""previousCourseEndedOn":"2026-10-25""#])
        fresh = try JSONDecoder.hlDefault.decode(Medication.self, from: JSONEncoder.hlDefault.encode(fresh))
        #expect(fresh.autoMarkTaken == true && fresh.courseCount == 2 && fresh.previousCourseEndedOn == "2026-10-25")
    }
}

/// **MED-PLUS item 4 — split doses (½ and the other curated fractions).** The
/// editor sends them as `unitsPerDose`; a dose logged by the shortcut names no
/// amount, so the server books the medication's own `unitsPerDose` (½ stays ½).
@Suite("MED-PLUS — split doses in the form and the shortcut")
struct MedicationSplitDoseTests {
    @Test("The edit form sends every curated fraction as unitsPerDose", arguments: MedicationUnitsPerDose.fractions)
    func formSendsFraction(fraction: Double) throws {
        let row = try MedicationAutoMarkTakenTests.row()
        var draft = MedicationEditDraft(prefill: EditMedicationFormState(from: row))
        draft.unitsPerDose = .fraction(fraction)
        let body = try JSONSerialization.jsonObject(with: JSONEncoder.hlDefault.encode(draft.patch(for: row))) as? [String: Any]
        let sent = try #require(body?["unitsPerDose"] as? Double)
        #expect(abs(sent - fraction) < 0.0001)
    }

    @Test("A ½ medication opens on ½ and an untouched save does not rewrite it")
    func halfRoundTrips() throws {
        let row = try MedicationAutoMarkTakenTests.row(extra: [#""unitsPerDose":0.5"#])
        let state = EditMedicationFormState(from: row)
        #expect(state.unitsPerDose == .fraction(0.5))
        #expect(MedicationEditDraft(prefill: state).patch(for: row).unitsPerDose == nil)
    }

    @Test("The shortcut's intake body names no amount, so the medication's ½ applies")
    func shortcutBodyCarriesNoAmount() throws {
        let body = MedicationsRepository.MedicationIdIntakeBody(
            scheduledFor: Date(timeIntervalSince1970: 1_792_958_400), takenAt: nil, skipped: false, idempotencyKey: "k"
        )
        let json = try JSONSerialization.jsonObject(with: JSONEncoder.hlDefault.encode(body)) as? [String: Any] ?? [:]
        #expect(json["unitsPerDose"] == nil && json["doseTaken"] == nil)
    }
}

// swiftlint:enable force_unwrapping
