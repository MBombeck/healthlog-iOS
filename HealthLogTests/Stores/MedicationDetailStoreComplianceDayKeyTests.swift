import Foundation
@testable import HealthLog
import Testing

/// **Audit B-6 — one day-key zone for the `dailyCompliance` overlay.**
///
/// `MedicationDetailStore.verlaufGlyphs()` reads the server's per-day
/// `dailyCompliance` map to suppress / mark days that carry no loaded intake.
/// The lookup used to try the profile-zone key FIRST and then fall back to a
/// UTC-formatted key. For every user east of UTC the UTC key of a profile-day
/// midnight is the PREVIOUS calendar date, so the fallback silently answered a
/// day with its NEIGHBOUR's bucket — a "due" marker one day off, exactly the
/// drift the server (`compliance-payload.ts`, bucketing by the profile zone)
/// never produces.
///
/// These tests pin the seam with fixed instants: the profile-day key must be
/// honoured, and the neighbouring UTC key must NOT be consulted.
@MainActor
@Suite("MedicationDetailStore — B-6 dailyCompliance day-key zone")
struct MedicationDetailStoreComplianceDayKeyTests {
    /// 2023-11-21T09:00:00Z → Berlin (CET, UTC+1) 2023-11-21 10:00.
    private let now = Date(timeIntervalSince1970: 1_700_557_200)

    private func berlin() throws -> TimeZone {
        try #require(TimeZone(identifier: "Europe/Berlin"))
    }

    private func bucket(due: Bool) -> DailyComplianceBucket {
        DailyComplianceBucket(
            expected: due ? 1 : 0,
            taken: 0,
            skipped: 0,
            onTime: 0,
            late: 0,
            veryLate: 0,
            due: due,
            expectedCount: due ? 1 : 0
        )
    }

    private func payload(_ daily: [String: DailyComplianceBucket]) -> MedicationCompliancePayload {
        let window = ComplianceWindowResult(totalExpected: 0, taken: 0, skipped: 0, missed: 0, rate: 0, streak: 0)
        return MedicationCompliancePayload(
            compliance7: window,
            compliance30: window,
            dailyCompliance: daily
        )
    }

    private func makeStore(
        daily: [String: DailyComplianceBucket],
        zone: TimeZone
    ) throws -> MedicationDetailStore {
        let medication = Medication(
            id: "med-1",
            name: "Lisinopril",
            dose: "5 mg",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 22, minute: 0)])
        )
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationDetailStore(
            medication: medication,
            repo: repo,
            profileTimeZoneProvider: { zone }
        )
        store._testInject(intakes: [], compliance: payload(daily))
        return store
    }

    /// The window is `[Nov 18, Nov 19, Nov 20, Nov 21]` in Berlin days.
    ///
    /// The payload carries exactly ONE bucket, keyed `2023-11-19` with
    /// `due == true`. That key is the profile-day key for Berlin Nov 19 — and
    /// simultaneously the UTC-formatted key of Berlin Nov 20's midnight
    /// (2023-11-19T23:00Z). Pre-fix the UTC fallback therefore painted BOTH days
    /// `.missed`; only Nov 19 is the server's actual verdict.
    @Test("the profile-day bucket is honoured, the UTC neighbour key is not")
    func utcNeighbourKeyIsNotConsulted() throws {
        let store = try makeStore(daily: ["2023-11-19": bucket(due: true)], zone: berlin())
        let glyphs = store.verlaufGlyphs(days: 4, now: now)

        #expect(glyphs.count == 4)
        #expect(glyphs[1] == .missed, "Berlin Nov 19 must read its own profile-day bucket")
        #expect(
            glyphs[2] == .noSchedule,
            "Berlin Nov 20 has no bucket — the UTC key of its midnight (2023-11-19) must not answer for it"
        )
    }

    /// Control for the same window: a `due == false` bucket on the profile day
    /// keeps that day suppressed, so the lookup itself still works after the
    /// fallback is gone.
    @Test("a due == false profile-day bucket still suppresses its own day")
    func profileDayBucketStillResolves() throws {
        let store = try makeStore(
            daily: ["2023-11-19": bucket(due: false), "2023-11-20": bucket(due: true)],
            zone: berlin()
        )
        let glyphs = store.verlaufGlyphs(days: 4, now: now)

        #expect(glyphs[1] == .noSchedule, "Berlin Nov 19 is not due")
        #expect(glyphs[2] == .missed, "Berlin Nov 20 is due and carries no intake")
    }
}
