import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **Server v1.39.2 — check-ups stay due after their reminder.**
///
/// Until v1.39.2 the reminder tick moved `nextDueAt` a whole cycle on after
/// every delivered reminder, and `PATCH /api/measurement-reminders/{id}`
/// recomputed it from now on every edit. v1.39.2 keeps a check-up on a cycle
/// longer than seven days due, then overdue, until it is satisfied, skipped or
/// snoozed (`holdsOpenAfterReminder`), and the PATCH recomputes only when the
/// cadence changes. An older server still recomputes on any PATCH, so the app
/// sends only the fields the person changed.
///
/// Fixture rows follow `MeasurementReminderDtoShape`
/// (`src/lib/measurement-reminders/dto.ts` at `v1.39.2`): a yearly dentist
/// check-up whose reminder went out yesterday at 09:00 Berlin and which the
/// server kept on that slot. The PATCH answer is the route's own
/// `toMeasurementReminderDto(updated)` for a label-only edit, which leaves
/// `nextDueAt` and `snoozedUntil` alone.
@Suite("v1.39.2 — check-ups stay due", .serialized, .mockURLSession)
@MainActor
struct CheckupStaysDueV1392Tests {
    // MARK: - Fixtures

    private nonisolated static let berlin = TimeZone(identifier: "Europe/Berlin")!
    /// 2026-09-26 10:00 Berlin — the morning after the reminder went out.
    private static let now = ISO8601DateFormatter().date(from: "2026-09-26T08:00:00Z")!

    private nonisolated static func rowJSON(
        label: String = "Zahnarzt",
        rrule: String = "FREQ=YEARLY",
        nextDueAt: String = "2026-09-25T07:00:00.000Z"
    ) -> String {
        """
        {"id":"rem-dentist","label":"\(label)","measurementType":null,"intervalDays":null,
         "rrule":"\(rrule)","anchorDate":"2025-09-25T07:00:00.000Z","endsOn":null,
         "origin":"VORSORGE","notifyHour":9,"location":"Praxis Dr. Weber",
         "nextDueAt":"\(nextDueAt)","lastSatisfiedAt":"2025-09-25T08:10:00.000Z",
         "snoozedUntil":null,"lastSkippedAt":null,"skipCount":0,"enabled":true,
         "createdAt":"2025-09-01T10:00:00.000Z","updatedAt":"2026-09-25T07:00:05.000Z"}
        """
    }

    private static func row(_ json: String = rowJSON()) throws -> MeasurementReminderRow {
        try JSONDecoder.hlDefault.decode(MeasurementReminderRow.self, from: Data(json.utf8))
    }

    private static func calendar(_ zone: TimeZone) -> Calendar {
        ProfileDay.calendar(in: zone)
    }

    /// Exactly what `MeasurementReminderCreateSheet.prefillIfNeeded` seeds the
    /// form with, so a patch built from it is the patch an untouched save sends.
    private struct Form {
        var label: String
        var measurementType: String?
        var cadence: ReminderCadence
        var anchorDate: Date?
        var notifyHour: Int
        var location: String?
        var enabled: Bool

        init(prefilledFrom row: MeasurementReminderRow) {
            label = row.label
            measurementType = row.measurementType
            if row.isRRuleScheduled, let rule = row.rrule {
                let preset = RRulePreset(wire: rule)
                cadence = .rrule(preset.wire ?? rule.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                cadence = .interval(row.intervalDays ?? 30)
            }
            anchorDate = row.anchorDate
            notifyHour = row.notifyHour ?? 9
            location = row.location ?? ""
            enabled = row.enabled
        }

        func patch(for row: MeasurementReminderRow) -> MeasurementReminderUpdate {
            MeasurementReminderRow.editingPatch(
                for: row,
                label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                measurementType: measurementType,
                cadence: cadence,
                anchorDate: anchorDate,
                notifyHour: notifyHour,
                location: location,
                enabled: enabled,
                timeZone: CheckupStaysDueV1392Tests.berlin
            )
        }
    }

    private struct Call {
        let method: String
        let path: String
        let body: Data
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [Call] = []
        func record(_ request: URLRequest) {
            lock.lock()
            defer { lock.unlock() }
            calls.append(Call(method: request.httpMethod ?? "?", path: request.url?.path ?? "", body: Self.body(of: request)))
        }

        var snapshot: [Call] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }

        /// URLProtocol moves `httpBody` onto `httpBodyStream`; read either.
        private static func body(of request: URLRequest) -> Data {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open()
            defer { stream.close() }
            var data = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
    }

    private func makeStore() -> MeasurementRemindersStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.1.0",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        return MeasurementRemindersStore(repo: MeasurementReminderRepository(api: api))
    }

    private static func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func encoded(_ patch: MeasurementReminderUpdate) throws -> [String: Any] {
        try json(JSONEncoder.hlDefault.encode(patch))
    }

    // MARK: - Held open: Home tile and card wording

    @Test("a check-up the server held open stays on the Home tile, overdue since yesterday")
    func heldOpenStaysDue() throws {
        let row = try Self.row()
        let cal = Self.calendar(Self.berlin)

        #expect(VorsorgeNextDue.nextDueNow(from: [row], now: Self.now, calendar: cal)?.id == "rem-dentist")
        let bucket = VorsorgeCard.dueBucket(nextDueAt: row.nextDueAt, now: Self.now, calendar: cal)
        #expect(bucket == .overdue(days: 1))
        #expect(bucket.isDue)
        #expect(bucket.localizedKey == "vorsorge.card.due.overdueYesterday")
        #expect(bucket.dayArgument == nil, "the one-day phrase carries no count")
    }

    @Test("two days over keeps the counted phrase")
    func twoDaysOverIsCounted() throws {
        let row = try Self.row(Self.rowJSON(nextDueAt: "2026-09-24T07:00:00.000Z"))
        let bucket = VorsorgeCard.dueBucket(nextDueAt: row.nextDueAt, now: Self.now, calendar: Self.calendar(Self.berlin))
        #expect(bucket == .overdue(days: 2))
        #expect(bucket.localizedKey == "vorsorge.card.due.overdue")
        #expect(bucket.dayArgument == 2)
    }

    /// Profile zone Pacific/Kiritimati (UTC+14): the slot is 23:00 on the 26th
    /// there and `now` is 01:00 on the 27th, so the account's check-up is one
    /// day over. Every zone from UTC−10 to UTC+12 (any plausible phone) still
    /// calls both instants the 26th, "due today".
    @Test("today and overdue are the account's days, not the phone's")
    func bucketsInProfileZone() throws {
        let kiritimati = try #require(TimeZone(identifier: "Pacific/Kiritimati"))
        let due = try #require(ISO8601DateFormatter().date(from: "2026-09-26T09:00:00Z"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-26T11:00:00Z"))
        let row = MeasurementReminderRow(
            id: "r", label: "PHQ-9", measurementType: "PHQ9_SCORE", intervalDays: 14, rrule: nil,
            endsOn: nil, origin: .vorsorge, notifyHour: 23, location: nil,
            nextDueAt: due, lastSatisfiedAt: nil, enabled: true
        )

        #expect(VorsorgeCard.dueBucket(nextDueAt: due, now: now, calendar: Self.calendar(kiritimati)) == .overdue(days: 1))
        #expect(VorsorgeCard.dueBucket(nextDueAt: due, now: now, calendar: Self.calendar(.gmt)) == .today)
        let front = VorsorgeNextDue.nextDueNow(from: [row], now: now, calendar: Self.calendar(kiritimati))
        #expect(front?.id == "r")
        #expect(
            VorsorgeCard.dueDisplayText(nextDueAt: due, now: now, calendar: Self.calendar(kiritimati))
                == String(localized: "vorsorge.card.due.overdueYesterday")
        )
    }

    /// Profile zone America/Los_Angeles: `now` is 23:30 on the 25th there and
    /// the slot 01:00 on the 26th, so the account's check-up is due tomorrow.
    /// Every phone zone from UTC−6 eastwards calls both instants the 26th and
    /// would put the check-up on the Home tile a day early.
    @Test("a check-up due tomorrow in the account does not lead the Home tile early")
    func notDueEarlyInProfileZone() throws {
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let due = try #require(ISO8601DateFormatter().date(from: "2026-09-26T08:00:00Z"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-26T06:30:00Z"))
        let row = MeasurementReminderRow(
            id: "r", label: "Blutdruck", measurementType: "BLOOD_PRESSURE_SYS", intervalDays: 30, rrule: nil,
            endsOn: nil, origin: .vorsorge, notifyHour: 1, location: nil,
            nextDueAt: due, lastSatisfiedAt: nil, enabled: true
        )

        #expect(VorsorgeCard.dueBucket(nextDueAt: due, now: now, calendar: Self.calendar(losAngeles)) == .tomorrow)
        #expect(VorsorgeNextDue.nextDueNow(from: [row], now: now, calendar: Self.calendar(losAngeles)) == nil)
    }

    // MARK: - PATCH: only what changed

    @Test("a label edit of an overdue check-up sends exactly the label, and it stays due")
    func labelOnlyEditKeepsItDue() async throws {
        let row = try Self.row()
        let recorder = Recorder()
        MockURLProtocol.install { req in
            recorder.record(req)
            let body = req.httpMethod == "PATCH"
                ? "{\"data\":\(Self.rowJSON(label: "Zahnarzt Kontrolle"))}"
                : "{\"data\":[\(Self.rowJSON(label: "Zahnarzt Kontrolle"))]}"
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        var form = Form(prefilledFrom: row)
        form.label = "Zahnarzt Kontrolle"

        let store = makeStore()
        #expect(await store.update(id: row.id, patch: form.patch(for: row)))

        let patch = try #require(recorder.snapshot.first)
        #expect(patch.method == "PATCH")
        #expect(patch.path == "/api/measurement-reminders/rem-dentist")
        let body = try Self.json(patch.body)
        #expect(Set(body.keys) == ["label"], "only the changed field; got \(body.keys.sorted())")
        #expect(body["label"] as? String == "Zahnarzt Kontrolle")
        #expect(store.reminders.first?.nextDueAt == row.nextDueAt, "the server's kept slot is rendered as sent")
    }

    @Test("saving an untouched sheet sends nothing at all")
    func untouchedSaveSendsNothing() async throws {
        let row = try Self.row()
        MockURLProtocol.install { req in
            Issue.record("an untouched save must not reach the server: \(req.httpMethod ?? "?") \(req.url?.path ?? "")")
            return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, nil)
        }
        let patch = Form(prefilledFrom: row).patch(for: row)
        #expect(patch.isEmpty)
        #expect(try Self.encoded(patch).isEmpty)

        let store = makeStore()
        #expect(await store.update(id: row.id, patch: patch))
        #expect(store.error == nil)
    }

    @Test("a stored rule in another spelling is not rewritten by the preset it maps to")
    func lowercaseRuleIsNotRewritten() throws {
        let row = try Self.row(Self.rowJSON(rrule: "freq=yearly"))
        let form = Form(prefilledFrom: row)
        #expect(form.cadence == .rrule("FREQ=YEARLY"), "the sheet shows the yearly preset")
        #expect(form.patch(for: row).isEmpty)
    }

    @Test("an hour-only edit sends only the hour")
    func hourOnlyEdit() throws {
        let row = try Self.row()
        var form = Form(prefilledFrom: row)
        form.notifyHour = 10
        let body = try Self.encoded(form.patch(for: row))
        #expect(Set(body.keys) == ["notifyHour"])
        #expect(body["notifyHour"] as? Int == 10)
    }

    @Test("the anchor re-picked on the same account day is omitted; another day is sent")
    func anchorComparedByAccountDay() throws {
        let row = try Self.row()
        var form = Form(prefilledFrom: row)
        form.anchorDate = row.anchorDate!.addingTimeInterval(5 * 3600) // 14:00 Berlin, same day
        #expect(form.patch(for: row).isEmpty)

        form.anchorDate = row.anchorDate!.addingTimeInterval(24 * 3600)
        let body = try Self.encoded(form.patch(for: row))
        #expect(Set(body.keys) == ["anchorDate"])
    }

    @Test("switching it off sends only enabled; changing the cadence sends only its family")
    func enabledAndCadence() throws {
        let row = try Self.row()
        var off = Form(prefilledFrom: row)
        off.enabled = false
        #expect(try Set(Self.encoded(off.patch(for: row)).keys) == ["enabled"])

        var twoYears = Form(prefilledFrom: row)
        twoYears.cadence = .interval(730)
        let body = try Self.encoded(twoYears.patch(for: row))
        #expect(Set(body.keys) == ["intervalDays"])
        #expect(body["intervalDays"] as? Int == 730)
    }

    // MARK: - Rail routing

    @Test("checkup.view on a preventive_care item leads to the due check-up; on a visit, to the list")
    func railFrontDoor() throws {
        let row = try Self.row()
        let cal = Self.calendar(Self.berlin)
        #expect(
            VorsorgeNextDue.frontDoorReminder(forRailKind: "preventive_care", reminders: [row], now: Self.now, calendar: cal)?
                .id == "rem-dentist"
        )
        #expect(VorsorgeNextDue.frontDoorReminder(forRailKind: "upcoming_visit", reminders: [row], now: Self.now, calendar: cal) == nil)
        #expect(VorsorgeNextDue.frontDoorReminder(forRailKind: "future_kind", reminders: [row], now: Self.now, calendar: cal) == nil)
    }
}
