import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable type_body_length

/// **v0.6.1.2 Y4 — MedicationDetailStore compliance + verlauf tests.**
///
/// `complianceSummary()` and `verlaufGlyphs()` are the per-detail-
/// screen analogues of `MedicationsStore.complianceSnapshot`. Both
/// derive purely from `intakes`; this suite asserts the in-time
/// counting + glyph bucketing semantics.
@MainActor
@Suite("MedicationDetailStore — compliance + Verlauf")
struct MedicationDetailStoreComplianceTests {
    @Test("Verlauf produces 14 glyphs, oldest first")
    func verlaufLength() {
        let store = makeStore(intakes: [])
        let glyphs = store.verlaufGlyphs()
        #expect(glyphs.count == 14)
    }

    @Test("Verlauf — day with on-time taken intake renders onTime")
    func verlaufOnTime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let twoDaysAgoNoon = calendar.startOfDay(
            for: now.addingTimeInterval(-2 * 24 * 60 * 60)
        ).addingTimeInterval(12 * 60 * 60)
        let event = PaginatedIntakeEvent(
            id: "i-1",
            takenAt: twoDaysAgoNoon,
            skipped: false,
            scheduledFor: twoDaysAgoNoon,
            injectionSite: nil
        )
        let store = makeStore(intakes: [event])
        let glyphs = store.verlaufGlyphs(now: now)
        // Index 11 = 2 days ago (oldest-first ordering, 14 days back ... today).
        #expect(glyphs[11] == .onTime)
    }

    @Test("Verlauf — day with missed past-due intake renders missed")
    func verlaufMissed() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let threeDaysAgoNoon = calendar.startOfDay(
            for: now.addingTimeInterval(-3 * 24 * 60 * 60)
        ).addingTimeInterval(12 * 60 * 60)
        let event = PaginatedIntakeEvent(
            id: "i-1",
            takenAt: nil,
            skipped: false,
            scheduledFor: threeDaysAgoNoon,
            injectionSite: nil
        )
        let store = makeStore(intakes: [event])
        let glyphs = store.verlaufGlyphs(now: now)
        #expect(glyphs[10] == .missed)
    }

    @Test("Verlauf — day with no scheduled intake renders noSchedule")
    func verlaufNoSchedule() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore(intakes: [])
        let glyphs = store.verlaufGlyphs(now: now)
        #expect(glyphs[0] == .noSchedule)
    }

    // MARK: - v0.6.2.3 B1 — server-canonical payload consumption

    @Test("W45 — Verlauf glyphs are derived from loaded intakes (table parity)")
    func verlaufFromLoadedIntakes() throws {
        // W45 doctrine: the glyph track mirrors the same `intakes` the intake
        // TABLE renders. A taken-on-time day reads `.onTime`, a past-due day
        // with an unactioned slot reads `.missed`, a late day reads `.late`.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        func noon(_ daysAgo: Int) throws -> Date {
            let day = try #require(calendar.date(byAdding: .day, value: -daysAgo, to: today))
            return day.addingTimeInterval(12 * 60 * 60)
        }
        let twoNoon = try noon(2)
        let threeNoon = try noon(3)
        let fourNoon = try noon(4)
        let intakes: [PaginatedIntakeEvent] = [
            // Two days ago: taken on-time → .onTime.
            PaginatedIntakeEvent(
                id: "a",
                takenAt: twoNoon,
                skipped: false,
                scheduledFor: twoNoon,
                injectionSite: nil
            ),
            // Three days ago: past-due, never taken → .missed.
            PaginatedIntakeEvent(
                id: "b",
                takenAt: nil,
                skipped: false,
                scheduledFor: threeNoon,
                injectionSite: nil
            ),
            // Four days ago: taken 2h late → .late.
            PaginatedIntakeEvent(
                id: "c",
                takenAt: fourNoon.addingTimeInterval(2 * 60 * 60),
                skipped: false,
                scheduledFor: fourNoon,
                injectionSite: nil
            )
        ]
        let store = makeStore(intakes: intakes)
        let glyphs = store.verlaufGlyphs(now: now)
        // Oldest-first, 14 entries → today is glyphs[13].
        #expect(glyphs[11] == .onTime)
        #expect(glyphs[10] == .missed)
        #expect(glyphs[9] == .late)
        // A day with no loaded intake reads `.noSchedule` (no row in the table
        // either) — the track only paints from slots that actually exist.
        #expect(glyphs[0] == .noSchedule)
    }

    @Test("W45 — server due=false suppresses an empty (no-intake) day to noSchedule")
    func verlaufServerDueFalseSuppressesEmptyDay() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let oneDayAgo = try #require(calendar.date(byAdding: .day, value: -1, to: today))
        let payload = MedicationCompliancePayload(
            compliance7: ComplianceWindowResult(
                totalExpected: 0, taken: 0, skipped: 0, missed: 0, rate: 100, streak: 0
            ),
            compliance30: ComplianceWindowResult(
                totalExpected: 0, taken: 0, skipped: 0, missed: 0, rate: 100, streak: 0
            ),
            dailyCompliance: [
                formatter.string(from: oneDayAgo): DailyComplianceBucket(
                    expected: 0, taken: 0, skipped: 0, onTime: 0, late: 0, veryLate: 0,
                    due: false, expectedCount: 0
                )
            ]
        )
        #expect(payload.isV170Capable)
        // No intakes loaded for that day → the v1.7.0 `due == false` overlay
        // suppresses the otherwise-daily med's day to `.noSchedule`.
        let store = makeStore(intakes: [], compliance: payload)
        let glyphs = store.verlaufGlyphs(now: now)
        #expect(glyphs[12] == .noSchedule)
    }

    // MARK: - v0.6.2.8 — weekly cadence guard against server totalExpected bug

    // MARK: - v0.10 W-Meds-A2 — v1.7.0 SB-SCHED-2 capability gate

    @Test("W45 — server due=false suppresses an off-day even when the local schedule fires daily")
    func v170VerlaufSuppressesNonDue() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let twoDaysAgo = try #require(calendar.date(byAdding: .day, value: -2, to: today))
        let twoNoon = twoDaysAgo.addingTimeInterval(12 * 60 * 60)
        let threeDaysAgo = try #require(calendar.date(byAdding: .day, value: -3, to: today))
        let payload = MedicationCompliancePayload(
            compliance7: ComplianceWindowResult(
                totalExpected: 1, taken: 1, skipped: 0, missed: 0, rate: 100, streak: 1
            ),
            compliance30: ComplianceWindowResult(
                totalExpected: 1, taken: 1, skipped: 0, missed: 0, rate: 100, streak: 1
            ),
            dailyCompliance: [
                // NOT due (off-week) but the server still emitted a bucket — the
                // overlay must suppress an EMPTY (no-intake) day to .noSchedule,
                // NOT paint .missed, even though the local daily schedule fires.
                formatter.string(from: threeDaysAgo): DailyComplianceBucket(
                    expected: 0, taken: 0, skipped: 0, onTime: 0, late: 0, veryLate: 0,
                    due: false, expectedCount: 0
                )
            ]
        )
        #expect(payload.isV170Capable)
        // Two days ago carries a real loaded intake → renders from it (.onTime),
        // proving the table's truth wins on days that HAVE intakes.
        let intakes = [
            PaginatedIntakeEvent(
                id: "a",
                takenAt: twoNoon,
                skipped: false,
                scheduledFor: twoNoon,
                injectionSite: nil
            )
        ]
        let store = makeStore(intakes: intakes, compliance: payload)
        let glyphs = store.verlaufGlyphs(now: now)
        #expect(glyphs[11] == .onTime) // two days ago (loaded intake wins)
        #expect(glyphs[10] == .noSchedule) // three days ago (empty + due=false → suppressed)
    }

    // MARK: - B15 — user-tz day-key (Berlin) must resolve, not dash

    @Test("B15 — Berlin user: taken day resolves to .onTime, not a UTC-off-by-one dash")
    func berlinDayKeyResolves() throws {
        // Repro of the v0.10.0 B15 dashes bug. The server (v1.7.0) keys
        // `dailyCompliance` by `userDayKey(dayStart, "Europe/Berlin")` — the
        // user-tz local day. Before the fix iOS read it back with a hard-coded
        // UTC formatter over `Calendar.current` local-midnight day starts, so
        // for a Berlin user (UTC+2 in May) the local midnight formatted in UTC
        // resolved to the PREVIOUS calendar day → every bucket lookup missed →
        // `.noSchedule` everywhere. With the fix the formatter tracks the
        // caller's calendar timezone, so the iOS key == the server key.
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = berlin

        // 2026-05-30 08:00 Berlin (a morning — well past local midnight).
        var comps = DateComponents()
        comps.timeZone = berlin
        comps.year = 2026
        comps.month = 5
        comps.day = 30
        comps.hour = 8
        comps.minute = 0
        let now = try #require(calendar.date(from: comps))

        // Server bucket keyed exactly as `userDayKey(dayStart, "Europe/Berlin")`
        // would: the Berlin-local calendar day → "2026-05-30".
        let serverKeyFormatter = DateFormatter()
        serverKeyFormatter.calendar = Calendar(identifier: .gregorian)
        serverKeyFormatter.locale = Locale(identifier: "en_US_POSIX")
        serverKeyFormatter.timeZone = berlin
        serverKeyFormatter.dateFormat = "yyyy-MM-dd"
        let todayKey = serverKeyFormatter.string(from: now)
        #expect(todayKey == "2026-05-30")

        let payload = MedicationCompliancePayload(
            compliance7: ComplianceWindowResult(
                totalExpected: 1, taken: 1, skipped: 0, missed: 0, rate: 100, streak: 1
            ),
            compliance30: ComplianceWindowResult(
                totalExpected: 1, taken: 1, skipped: 0, missed: 0, rate: 100, streak: 1
            ),
            dailyCompliance: [
                todayKey: DailyComplianceBucket(
                    expected: 1, taken: 1, skipped: 0, onTime: 1, late: 0, veryLate: 0,
                    due: true, expectedCount: 1
                )
            ]
        )
        #expect(payload.isV170Capable)

        // W45 — the glyph comes from the loaded intake (the table's truth), not
        // the server bucket. A taken-today intake renders `.onTime`; the Berlin
        // tz still matters because the day-bucketing of the intake must land on
        // the same local day the track iterates.
        let todayNoon = try #require(calendar.date(from: {
            var c = comps
            c.hour = 12
            return c
        }()))
        let intakes = [
            PaginatedIntakeEvent(
                id: "a",
                takenAt: todayNoon,
                skipped: false,
                scheduledFor: todayNoon,
                injectionSite: nil
            )
        ]
        let store = makeStore(intakes: intakes, compliance: payload)
        let glyphs = store.verlaufGlyphs(now: now, calendar: calendar)
        // Last glyph = today (2026-05-30 Berlin). The taken intake → .onTime.
        #expect(glyphs.last == .onTime)
    }

    // MARK: - W10 M5 — engine-0 must not fall back to the inflated server grid

    // MARK: - W42 — degenerate server window must not clobber the loaded history

    // MARK: - Helpers

    private func makeStore(
        medication: Medication? = nil,
        intakes: [PaginatedIntakeEvent],
        compliance: MedicationCompliancePayload? = nil
    ) -> MedicationDetailStore {
        let resolved = medication ?? Medication(
            id: "med-1",
            name: "Lisinopril",
            dose: "5 mg",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 12, minute: 0)])
        )
        let stub = MedicationDetailComplianceStubAPIClient()
        // swiftlint:disable:next force_try
        let outbox = try! OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: stub, outbox: outbox)
        let store = MedicationDetailStore(medication: resolved, repo: repo)
        store._testInject(intakes: intakes, compliance: compliance)
        return store
    }

    /// Build N day-spaced intake events, each taken `deltaSeconds` from
    /// the scheduled time.
    private func makeWindow(days: Int, deltaSeconds: TimeInterval, now: Date) -> [PaginatedIntakeEvent] {
        (0 ..< days).map { offset in
            let scheduled = now.addingTimeInterval(Double(-offset) * 24 * 60 * 60)
            return PaginatedIntakeEvent(
                id: "i-\(offset)",
                takenAt: scheduled.addingTimeInterval(deltaSeconds),
                skipped: false,
                scheduledFor: scheduled,
                injectionSite: nil
            )
        }
    }
}

private final class MedicationDetailComplianceStubAPIClient: APIClientProtocol, @unchecked Sendable {
    func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
        throw HLError.canceled
    }

    func sendVoid(_: APIRequest<EmptyPayload>) async throws {
        throw HLError.canceled
    }

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.canceled
    }
}
