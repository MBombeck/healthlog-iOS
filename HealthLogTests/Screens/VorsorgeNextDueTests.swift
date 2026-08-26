import Foundation
@testable import HealthLog
import Testing

/// **v0.15 W-FRONTDOORS — pins the pure logic behind the Home Vorsorge tile.**
///
/// Three decisions are unit-tested here so the tile (a SwiftUI view) stays a
/// thin renderer over verified logic:
///
/// 1. `VorsorgeNextDue.nextDue` / `.nextDueNow` — soonest *enabled* reminder
///    selection (the tile lead). `.nextDueNow` additionally gates on the server
///    `nextDueAt` being DUE now (today/overdue) so the Home tile shows ONLY when
///    something must be done now (V1). Drives self-suppression: `nil` ⇒ no tile.
/// 2. `VorsorgeNextDue.prefillKind` — server `measurementType` → capturable
///    `MetricKind` (the "jetzt messen" prefill), `nil` for free-text / uncapturable.
/// 3. `MeasurementRemindersStore.clearOnLogout` — PHI hygiene on the promoted
///    app-wide store.
@MainActor
@Suite("Vorsorge front-door logic")
struct VorsorgeNextDueTests {
    private nonisolated static func row(
        id: String,
        type: String?,
        enabled: Bool = true,
        nextDue: Date?
    ) -> MeasurementReminderRow {
        MeasurementReminderRow(
            id: id,
            label: "Reminder \(id)",
            measurementType: type,
            intervalDays: 30,
            rrule: nil,
            endsOn: nil,
            origin: .vorsorge,
            notifyHour: 9,
            location: nil,
            nextDueAt: nextDue,
            lastSatisfiedAt: nil,
            enabled: enabled
        )
    }

    // MARK: - next-due selection (tile lead + suppression)

    @Test("nextDue returns nil for an empty list — tile self-suppresses")
    func nextDueEmpty() {
        #expect(VorsorgeNextDue.nextDue(from: []) == nil)
    }

    @Test("nextDue picks the soonest server nextDueAt among enabled reminders")
    func nextDuePicksSoonest() {
        let soon = Date(timeIntervalSince1970: 1_800_000_000)
        let later = Date(timeIntervalSince1970: 1_900_000_000)
        let rows = [
            Self.row(id: "later", type: "WEIGHT", nextDue: later),
            Self.row(id: "soon", type: "BLOOD_PRESSURE_SYS", nextDue: soon)
        ]
        #expect(VorsorgeNextDue.nextDue(from: rows)?.id == "soon")
    }

    @Test("nextDue skips disabled reminders even when they are due soonest")
    func nextDueSkipsDisabled() {
        let soon = Date(timeIntervalSince1970: 1_800_000_000)
        let later = Date(timeIntervalSince1970: 1_900_000_000)
        let rows = [
            Self.row(id: "disabledSoon", type: "WEIGHT", enabled: false, nextDue: soon),
            Self.row(id: "enabledLater", type: "PULSE", nextDue: later)
        ]
        #expect(VorsorgeNextDue.nextDue(from: rows)?.id == "enabledLater")
    }

    @Test("nextDue skips reminders without a server nextDueAt (free-text not yet anchored)")
    func nextDueSkipsNilDueDate() {
        let later = Date(timeIntervalSince1970: 1_900_000_000)
        let rows = [
            Self.row(id: "noDue", type: nil, nextDue: nil),
            Self.row(id: "due", type: "WEIGHT", nextDue: later)
        ]
        #expect(VorsorgeNextDue.nextDue(from: rows)?.id == "due")
    }

    @Test("nextDue returns nil when every reminder is disabled or undated — tile suppresses")
    func nextDueAllUnusable() {
        let soon = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [
            Self.row(id: "disabled", type: "WEIGHT", enabled: false, nextDue: soon),
            Self.row(id: "undated", type: nil, nextDue: nil)
        ]
        #expect(VorsorgeNextDue.nextDue(from: rows) == nil)
    }

    // MARK: - due-now gating (V1 — Home tile shows ONLY when actually due)

    @Test("nextDueNow returns nil for an empty list — tile self-suppresses")
    func nextDueNowEmpty() {
        #expect(VorsorgeNextDue.nextDueNow(from: []) == nil)
    }

    @Test("nextDueNow suppresses an enabled reminder whose nextDueAt is in the future (upcoming, not due)")
    func nextDueNowSuppressesUpcoming() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let upcoming = now.addingTimeInterval(5 * 24 * 60 * 60) // +5 days — not due
        let rows = [Self.row(id: "upcoming", type: "WEIGHT", nextDue: upcoming)]
        #expect(VorsorgeNextDue.nextDueNow(from: rows, now: now) == nil)
    }

    @Test("nextDueNow surfaces a reminder due later the same calendar day")
    func nextDueNowSurfacesToday() {
        // 2026-07-19 (Parity 1.8c): due-buckets now floor to the CALENDAR DAY,
        // mirroring the web v1.18.9 fix, instead of dividing an interval by 24 h.
        // The old fixture (22:13 UTC + 2 h) crossed midnight, so under the new —
        // and correct — rule it is due *tomorrow*, not today. Anchored at midday
        // UTC so the assertion does not depend on the test machine's time zone.
        let now = Date(timeIntervalSince1970: 1_700_049_600) // 2023-11-15 12:00 UTC
        let dueToday = now.addingTimeInterval(2 * 60 * 60) // 14:00 UTC — same calendar day
        let rows = [Self.row(id: "today", type: "WEIGHT", nextDue: dueToday)]
        #expect(VorsorgeNextDue.nextDueNow(from: rows, now: now)?.id == "today")
    }

    @Test("nextDueNow surfaces an overdue reminder")
    func nextDueNowSurfacesOverdue() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let overdue = now.addingTimeInterval(-3 * 24 * 60 * 60) // 3 days overdue
        let rows = [Self.row(id: "overdue", type: "PULSE", nextDue: overdue)]
        #expect(VorsorgeNextDue.nextDueNow(from: rows, now: now)?.id == "overdue")
    }

    @Test("nextDueNow picks the soonest among due reminders, ignoring upcoming ones")
    func nextDueNowPicksSoonestDue() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let overdueMore = now.addingTimeInterval(-5 * 24 * 60 * 60)
        let overdueLess = now.addingTimeInterval(-1 * 24 * 60 * 60)
        let upcoming = now.addingTimeInterval(10 * 24 * 60 * 60)
        let rows = [
            Self.row(id: "upcoming", type: "WEIGHT", nextDue: upcoming),
            Self.row(id: "overdueLess", type: "PULSE", nextDue: overdueLess),
            Self.row(id: "overdueMore", type: "BLOOD_PRESSURE_SYS", nextDue: overdueMore)
        ]
        // Soonest nextDueAt = the most overdue (smallest date).
        #expect(VorsorgeNextDue.nextDueNow(from: rows, now: now)?.id == "overdueMore")
    }

    @Test("nextDueNow skips a disabled reminder even when overdue")
    func nextDueNowSkipsDisabled() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let overdue = now.addingTimeInterval(-2 * 24 * 60 * 60)
        let rows = [Self.row(id: "disabledOverdue", type: "WEIGHT", enabled: false, nextDue: overdue)]
        #expect(VorsorgeNextDue.nextDueNow(from: rows, now: now) == nil)
    }

    @Test("nextDueNow skips a reminder without a server nextDueAt")
    func nextDueNowSkipsNilDue() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = [Self.row(id: "noDue", type: nil, nextDue: nil)]
        #expect(VorsorgeNextDue.nextDueNow(from: rows, now: now) == nil)
    }

    // MARK: - V2 — a capturable due reminder routes the Home card to measure

    @Test("a capturable due reminder yields a prefill kind (card-tap → measure), free-text yields nil (→ open surface)")
    func dueReminderRoutesToMeasureWhenCapturable() {
        // V2: the Home card-body tap routes to `router.requestMeasure(prefill:)`
        // exactly when the due reminder maps to a capturable MetricKind; a
        // free-text reminder has no prefill, so the card falls back to opening
        // the Vorsorge surface (mark-done). The routing branch is `prefillKind !=
        // nil`, pinned here as the testable seam behind `VorsorgeTile.cardTap`.
        #expect(VorsorgeNextDue.prefillKind(forServerType: "BLOOD_PRESSURE_SYS") != nil)
        #expect(VorsorgeNextDue.prefillKind(forServerType: nil) == nil)
    }

    // MARK: - prefill kind mapping

    @Test("prefillKind maps BLOOD_PRESSURE_SYS to .bloodPressure (the literal 'measure BP' ask)")
    func prefillBloodPressure() {
        #expect(VorsorgeNextDue.prefillKind(forServerType: "BLOOD_PRESSURE_SYS") == .bloodPressure)
    }

    @Test("prefillKind maps the core capturable vitals")
    func prefillCoreVitals() {
        #expect(VorsorgeNextDue.prefillKind(forServerType: "WEIGHT") == .weight)
        #expect(VorsorgeNextDue.prefillKind(forServerType: "PULSE") == .pulse)
        #expect(VorsorgeNextDue.prefillKind(forServerType: "BLOOD_GLUCOSE") == .glucose)
    }

    @Test("prefillKind maps waist circumference to the manual waist field")
    func prefillWaistCircumference() {
        #expect(
            VorsorgeNextDue.prefillKind(forServerType: "WAIST_CIRCUMFERENCE")
                == .waistCircumference
        )
    }

    @Test("prefillKind is nil for a free-text reminder (no type)")
    func prefillFreeText() {
        #expect(VorsorgeNextDue.prefillKind(forServerType: nil) == nil)
        #expect(VorsorgeNextDue.prefillKind(forServerType: "") == nil)
    }

    @Test("prefillKind is nil for a type the manual-capture sheet cannot record (scale-only)")
    func prefillUncapturable() {
        // MUSCLE_MASS is in the reminder catalog but not in MeasureSheetView's
        // manual-capture set, so it must NOT yield a prefill (would land on the
        // wrong fallback kind).
        #expect(VorsorgeNextDue.prefillKind(forServerType: "MUSCLE_MASS") == nil)
        #expect(VorsorgeNextDue.prefillKind(forServerType: "SOME_FUTURE_TYPE") == nil)
    }

    // MARK: - store PHI hygiene

    @Test("clearOnLogout drops the in-memory reminder PHI")
    func clearOnLogoutWipesReminders() async {
        let api = StubAPIClient()
        await api.setHandler { _ in [Self.row(id: "r1", type: "WEIGHT", nextDue: Date())] }
        let store = MeasurementRemindersStore(repo: MeasurementReminderRepository(api: api))
        await store.load()
        #expect(!store.reminders.isEmpty)

        await store.clearOnLogout()
        #expect(store.reminders.isEmpty)
        #expect(store.error == nil)
    }
}
