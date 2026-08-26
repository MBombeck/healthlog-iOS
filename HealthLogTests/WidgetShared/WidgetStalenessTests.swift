import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **audit-v0162 M3** — pins the widget/watch staleness rule that decides
/// whether a snapshot's `nextDose` / today's-compliance may still be rendered
/// (and, for the next-dose surface, whether the interactive "Genommen" button
/// may fire). The bug: providers rendered the snapshot UNCONDITIONALLY, so when
/// the app hadn't run + iOS granted no BGTask over a weekend the Lock-Screen
/// widget kept showing Friday's dose as "fällig um HH:mm" with a LIVE button
/// recording against a stale slot, and the ring showed Friday's counts as
/// today's. These tests exercise the pure `WidgetTimelinePolicy` cutoff both
/// providers + the watch complication now consult.
///
/// All dates are constructed with an explicit `Europe/Berlin` calendar — never
/// a wall-clock read — so the local-day-rollover assertions are deterministic.
@Suite("Widget staleness — audit-v0162 M3")
struct WidgetStalenessTests {
    /// Fixed, explicit-time-zone calendar for reproducible local-day math.
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return cal
    }

    /// Build a concrete instant in the fixed calendar's time zone.
    private func date(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0
    ) -> Date {
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        c.hour = hour
        c.minute = minute
        return calendar.date(from: c)!
    }

    /// Reference "now": Saturday 2026-07-04 14:00 Berlin — a weekend afternoon,
    /// the classic "app hasn't run since Friday" window.
    private var now: Date {
        date(2026, 7, 4, 14, 0)
    }

    private func sampleDose(scheduledAt: Date) -> WidgetSnapshot.NextDose {
        WidgetSnapshot.NextDose(
            medicationId: "med-1",
            medicationName: "Vitamin D",
            doseText: "1000 IE",
            scheduledAt: scheduledAt
        )
    }

    /// Mirror the provider's dose-gating so the test asserts what actually
    /// ships: the widget surfaces the dose (and, on Home sizes, the interactive
    /// button) exactly when the snapshot is NOT stale.
    private func effectiveDose(for snapshot: WidgetSnapshot, now: Date) -> WidgetSnapshot.NextDose? {
        WidgetTimelinePolicy.isNextDoseStale(generatedAt: snapshot.generatedAt, now: now)
            ? nil
            : snapshot.nextDose
    }

    // MARK: - Next-dose staleness

    @Test("A fresh snapshot renders the dose + is not stale (button armed)")
    func freshNextDoseRendersDose() {
        // Snapshot written 1h ago, dose due at 15:00 today.
        let snapshot = WidgetSnapshot(
            nextDose: sampleDose(scheduledAt: date(2026, 7, 4, 15, 0)),
            compliance: .init(scheduled: 2, taken: 1),
            generatedAt: now.addingTimeInterval(-3600)
        )
        #expect(WidgetTimelinePolicy.isNextDoseStale(generatedAt: snapshot.generatedAt, now: now) == false)
        // The dose (and therefore the "Genommen" button) IS surfaced.
        #expect(effectiveDose(for: snapshot, now: now)?.medicationId == "med-1")
    }

    @Test("A >threshold-old snapshot is stale: dose + action button suppressed")
    func staleNextDoseSuppressesDoseAndButton() {
        // Snapshot last written Friday 18:00 — 20h before Saturday 14:00, past
        // the 16h next-dose cutoff. Its Friday dose must NOT be surfaced, and
        // with no dose the interactive button never renders.
        let snapshot = WidgetSnapshot(
            nextDose: sampleDose(scheduledAt: date(2026, 7, 3, 18, 0)),
            compliance: .init(scheduled: 2, taken: 1),
            generatedAt: date(2026, 7, 3, 18, 0)
        )
        #expect(WidgetTimelinePolicy.isNextDoseStale(generatedAt: snapshot.generatedAt, now: now))
        #expect(effectiveDose(for: snapshot, now: now) == nil)
    }

    @Test("Next-dose staleness cuts strictly past the threshold")
    func nextDoseStalenessBoundary() {
        let threshold = WidgetTimelinePolicy.nextDoseStaleThreshold
        // Exactly at the threshold → still fresh (not strictly greater).
        #expect(WidgetTimelinePolicy.isNextDoseStale(
            generatedAt: now.addingTimeInterval(-threshold), now: now
        ) == false)
        // One second past → stale.
        #expect(WidgetTimelinePolicy.isNextDoseStale(
            generatedAt: now.addingTimeInterval(-threshold - 1), now: now
        ))
    }

    @Test("An overnight-fresh snapshot does not flap stale")
    func overnightSnapshotStaysFresh() {
        // Evening snapshot (22:00) naming tomorrow's 08:00 dose, read the next
        // morning at 08:00 — 10h old, inside the 16h cutoff, still trustworthy.
        let generated = date(2026, 7, 3, 22, 0)
        let morning = date(2026, 7, 4, 8, 0)
        #expect(WidgetTimelinePolicy.isNextDoseStale(generatedAt: generated, now: morning) == false)
    }

    @Test("The placeholder's distantPast generatedAt reads as stale")
    func placeholderIsStale() {
        #expect(WidgetTimelinePolicy.isNextDoseStale(
            generatedAt: WidgetSnapshot.placeholder.generatedAt, now: now
        ))
    }

    // MARK: - Compliance staleness (cut at local-day rollover)

    @Test("Same-local-day compliance is fresh")
    func sameDayComplianceFresh() {
        // Written this morning 09:00, now 14:00 same day.
        #expect(WidgetTimelinePolicy.isComplianceStale(
            generatedAt: date(2026, 7, 4, 9, 0), now: now, calendar: calendar
        ) == false)
    }

    @Test("A snapshot from a previous local day is stale for compliance")
    func previousDayComplianceStale() {
        // Friday 22:00 counts painted on Saturday afternoon would show
        // yesterday's ring as today's — stale even though < 24h in some cases.
        #expect(WidgetTimelinePolicy.isComplianceStale(
            generatedAt: date(2026, 7, 3, 22, 0), now: now, calendar: calendar
        ))
    }

    @Test("Midnight rollover: a prior-day snapshot < 24h old is still stale")
    func midnightRolloverComplianceStale() {
        // Friday 23:30 → Saturday 00:30 is only 1h, but a different local day,
        // so today's counts have rolled over — must be treated as stale.
        let generated = date(2026, 7, 3, 23, 30)
        let justAfterMidnight = date(2026, 7, 4, 0, 30)
        #expect(WidgetTimelinePolicy.isComplianceStale(
            generatedAt: generated, now: justAfterMidnight, calendar: calendar
        ))
    }

    @Test("Compliance staleness honours the supplied time zone for the day cut")
    func complianceDayCutUsesTimeZone() throws {
        // 2026-07-03 23:00 UTC is still 2026-07-04 01:00 in Berlin (UTC+2), so
        // relative to a Berlin `now` of 2026-07-04 it is the SAME local day.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 7
        comps.day = 3
        comps.hour = 23
        let generatedUTC = try #require(utc.date(from: comps))
        // Same Berlin local day (04 July) → fresh under the Berlin calendar.
        #expect(WidgetTimelinePolicy.isComplianceStale(
            generatedAt: generatedUTC, now: date(2026, 7, 4, 6, 0), calendar: calendar
        ) == false)
    }

    @Test("The placeholder's distantPast reads as compliance-stale")
    func placeholderComplianceStale() {
        #expect(WidgetTimelinePolicy.isComplianceStale(
            generatedAt: WidgetSnapshot.placeholder.generatedAt, now: now, calendar: calendar
        ))
    }
}
