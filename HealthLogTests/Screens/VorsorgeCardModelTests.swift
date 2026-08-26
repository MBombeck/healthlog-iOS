import Foundation
@testable import HealthLog
import Testing

/// **W-VORSORGE-CARDS (v0.15.1 web-parity) — pins the pure presentation logic
/// behind the preventive-care reminder cards.**
///
/// The card view (`VorsorgeReminderCardView`) stays a thin renderer over the
/// verified `VorsorgeCard` decisions: the relative due bucket (web
/// `relativeDueKey` mirror), the primary-action branch (measure vs mark-done),
/// the 7-day strip derivation (web `VorsorgeTrendStrip` normalisation), the
/// cadence chip, and the empty-state self-suppression.
@Suite("Vorsorge card model")
struct VorsorgeCardModelTests {
    private static func row(
        type: String? = nil,
        intervalDays: Int? = 30,
        rrule: String? = nil,
        nextDueAt: Date? = nil,
        lastSatisfiedAt: Date? = nil
    ) -> MeasurementReminderRow {
        MeasurementReminderRow(
            id: "r1",
            label: "Blood pressure",
            measurementType: type,
            intervalDays: intervalDays,
            rrule: rrule,
            endsOn: nil,
            origin: .vorsorge,
            notifyHour: 9,
            location: nil,
            nextDueAt: nextDueAt,
            lastSatisfiedAt: lastSatisfiedAt,
            enabled: true
        )
    }

    // MARK: - Due bucket (relativeDueKey mirror)

    /// Parity 1.8c — the bucket is a CALENDAR-day delta, so the tests pin a
    /// fixed zone + explicit wall-clock instants. The previous relative-offset
    /// tests ("now + 2 h ⇒ today") were also time-of-day flaky: run after 22:00
    /// they crossed midnight.
    private static let berlin: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        return cal
    }()

    private static func at(_ y: Int, _ m: Int, _ d: Int, _ hh: Int, _ mm: Int = 0) -> Date {
        berlin.date(from: DateComponents(year: y, month: m, day: d, hour: hh, minute: mm))
            ?? .distantPast
    }

    @Test("nil nextDueAt ⇒ .none")
    func dueNone() {
        #expect(VorsorgeCard.dueBucket(nextDueAt: nil) == .none)
    }

    @Test("Past nextDueAt ⇒ .overdue with whole-day count")
    func dueOverdue() {
        let now = Self.at(2026, 3, 10, 12)
        let due = Self.at(2026, 3, 7, 12)
        #expect(
            VorsorgeCard.dueBucket(nextDueAt: due, now: now, calendar: Self.berlin)
                == .overdue(days: 3)
        )
    }

    /// **The C8 regression** (web v1.18.9 / issue #490). A reminder due today
    /// 09:00, read the same evening at 20:00, is 11 h in the past — the old
    /// rolling-24 h round produced `.overdue(days: 1)` while the web said
    /// "Heute fällig". Same calendar day ⇒ `.today`.
    @Test("Due earlier the same calendar day ⇒ .today, not .overdue")
    func dueEarlierSameDayIsToday() {
        let due = Self.at(2026, 3, 10, 9)
        let now = Self.at(2026, 3, 10, 20)
        #expect(VorsorgeCard.dueBucket(nextDueAt: due, now: now, calendar: Self.berlin) == .today)
    }

    /// The mirror image: only ~2 h apart, but across midnight — the rolling
    /// delta rounded to 0 ("heute"), the calendar delta is a full day.
    @Test("Due just after midnight tomorrow ⇒ .tomorrow, not .today")
    func dueAcrossMidnightIsTomorrow() {
        let now = Self.at(2026, 3, 10, 23)
        let due = Self.at(2026, 3, 11, 1)
        #expect(VorsorgeCard.dueBucket(nextDueAt: due, now: now, calendar: Self.berlin) == .tomorrow)
    }

    /// Yesterday late vs today early is under 24 h but a full calendar day —
    /// the rolling delta rounded to 0 and hid a genuinely overdue reminder.
    @Test("Due late yesterday ⇒ .overdue(1), not .today")
    func dueLateYesterdayIsOverdue() {
        let due = Self.at(2026, 3, 9, 23)
        let now = Self.at(2026, 3, 10, 1)
        #expect(
            VorsorgeCard.dueBucket(nextDueAt: due, now: now, calendar: Self.berlin)
                == .overdue(days: 1)
        )
    }

    /// DST robustness: 2026-03-29 is the Europe/Berlin spring-forward, a 23 h
    /// day. Differencing day components between two day starts is exact there;
    /// a fixed 86 400 s divisor only survives it by rounding luck.
    @Test("Spring-forward short day still buckets as one calendar day")
    func dueAcrossDSTBoundary() {
        let now = Self.at(2026, 3, 28, 12)
        let due = Self.at(2026, 3, 29, 12)
        #expect(VorsorgeCard.dueBucket(nextDueAt: due, now: now, calendar: Self.berlin) == .tomorrow)
    }

    @Test("nextDueAt later today ⇒ .today")
    func dueToday() {
        let now = Self.at(2026, 3, 10, 8)
        let due = Self.at(2026, 3, 10, 10)
        #expect(VorsorgeCard.dueBucket(nextDueAt: due, now: now, calendar: Self.berlin) == .today)
    }

    @Test("nextDueAt the next calendar day ⇒ .tomorrow")
    func dueTomorrow() {
        let now = Self.at(2026, 3, 10, 8)
        let due = Self.at(2026, 3, 11, 8)
        #expect(VorsorgeCard.dueBucket(nextDueAt: due, now: now, calendar: Self.berlin) == .tomorrow)
    }

    @Test("nextDueAt several calendar days out ⇒ .inDays(N)")
    func dueInDays() {
        let now = Self.at(2026, 3, 10, 8)
        let due = Self.at(2026, 3, 15, 8)
        #expect(VorsorgeCard.dueBucket(nextDueAt: due, now: now, calendar: Self.berlin) == .inDays(5))
    }

    @Test("isDue is true only for today / overdue")
    func isDueFlag() {
        #expect(VorsorgeCard.DueBucket.today.isDue)
        #expect(VorsorgeCard.DueBucket.overdue(days: 1).isDue)
        #expect(!VorsorgeCard.DueBucket.tomorrow.isDue)
        #expect(!VorsorgeCard.DueBucket.inDays(3).isDue)
        #expect(!VorsorgeCard.DueBucket.none.isDue)
    }

    // MARK: - Primary action branch

    @Test("Capturable measurement type ⇒ .measure(kind)")
    func actionMeasure() {
        #expect(VorsorgeCard.primaryAction(for: Self.row(type: "WEIGHT")) == .measure(.weight))
        #expect(
            VorsorgeCard.primaryAction(for: Self.row(type: "BLOOD_PRESSURE_SYS"))
                == .measure(.bloodPressure)
        )
        #expect(
            VorsorgeCard.primaryAction(for: Self.row(type: "WAIST_CIRCUMFERENCE"))
                == .measure(.waistCircumference)
        )
    }

    @Test("Free-text reminder ⇒ .markDone")
    func actionMarkDoneFreeText() {
        #expect(VorsorgeCard.primaryAction(for: Self.row(type: nil)) == .markDone)
    }

    @Test("Uncapturable / scale-only type ⇒ .markDone")
    func actionMarkDoneUncapturable() {
        // MUSCLE_MASS is in the type catalog but NOT capturable via the manual
        // sheet — it must fall back to mark-done, not a dead prefill.
        #expect(VorsorgeCard.primaryAction(for: Self.row(type: "MUSCLE_MASS")) == .markDone)
    }

    @Test("Mental-health screening type ⇒ .checkIn", arguments: [
        "PHQ9_SCORE", "GAD7_SCORE", "WHO5_SCORE", "SCI_SCORE"
    ])
    func actionCheckInScreening(type: String) {
        // #42 — a screening sum score is server-derived, not hand-entered, so the
        // reminder action opens the mental-health check-in surface rather than a
        // numeric capture form or a silent mark-done.
        #expect(VorsorgeCard.primaryAction(for: Self.row(type: type)) == .checkIn)
        #expect(MeasurementReminderType.isMentalHealthScreening(type))
    }

    @Test("Non-screening types are not routed to the check-in")
    func nonScreeningNotCheckIn() {
        #expect(!MeasurementReminderType.isMentalHealthScreening("WEIGHT"))
        #expect(!MeasurementReminderType.isMentalHealthScreening(nil))
    }

    // MARK: - 7-day strip derivation

    @Test("Fewer than two readings ⇒ nil (no trend)")
    func stripTooThin() {
        #expect(VorsorgeCard.stripHeights(values: []) == nil)
        #expect(VorsorgeCard.stripHeights(values: [70]) == nil)
    }

    @Test("Heights normalise within [0.18, 1.0], min→0.18 max→1.0")
    func stripNormalises() throws {
        let heights = VorsorgeCard.stripHeights(values: [60, 70, 80])
        let unwrapped = try #require(heights)
        #expect(unwrapped.count == 3)
        #expect(try abs(#require(unwrapped.first) - 0.18) < 0.0001) // min floors at 18%
        #expect(try abs(#require(unwrapped.last) - 1.0) < 0.0001) // max tops at 100%
        #expect(unwrapped.allSatisfy { $0 >= 0.18 && $0 <= 1.0 })
    }

    @Test("Flat series still renders bars (no divide-by-zero)")
    func stripFlatSeries() throws {
        let heights = VorsorgeCard.stripHeights(values: [72, 72, 72])
        let unwrapped = try #require(heights)
        #expect(unwrapped.allSatisfy { abs($0 - 0.18) < 0.0001 })
    }

    // MARK: - Cadence chip

    @Test("Interval cadence ⇒ everyNDays key + day arg")
    func cadenceInterval() {
        let result = VorsorgeCard.cadenceKeyAndArg(for: Self.row(intervalDays: 30, rrule: nil))
        #expect(result?.key == "vorsorge.card.cadence.everyNDays")
        #expect(result?.days == 30)
    }

    @Test("RRULE cadence ⇒ custom key, no day arg")
    func cadenceRRule() {
        let result = VorsorgeCard.cadenceKeyAndArg(
            for: Self.row(intervalDays: nil, rrule: "FREQ=MONTHLY")
        )
        #expect(result?.key == "vorsorge.card.cadence.custom")
        #expect(result?.days == nil)
    }

    @Test("Neither interval nor rrule ⇒ no chip")
    func cadenceNone() {
        #expect(VorsorgeCard.cadenceKeyAndArg(for: Self.row(intervalDays: nil, rrule: nil)) == nil)
    }

    // MARK: - Label resolution (parity 1.8b — COACH i18n key)

    private static func labelRow(_ label: String, origin: MeasurementReminderRow.Origin)
        -> MeasurementReminderRow
    {
        MeasurementReminderRow(
            id: "r1",
            label: label,
            measurementType: "BLOOD_PRESSURE_SYS",
            intervalDays: 30,
            rrule: nil,
            endsOn: nil,
            origin: origin,
            notifyHour: 9,
            location: nil,
            nextDueAt: nil,
            lastSatisfiedAt: nil,
            enabled: true
        )
    }

    /// C10 — a COACH reminder stores an i18n KEY in `label`; rendering it
    /// verbatim showed the user `coach.reminderSuggestion.cadence.bp722`.
    @Test("COACH label is resolved through the localization catalog")
    func coachLabelResolves() {
        let row = Self.labelRow("coach.reminderSuggestion.cadence.bp722", origin: .coach)
        let resolved = VorsorgeCard.resolvedLabel(for: row)
        #expect(resolved != nil)
        #expect(resolved != "coach.reminderSuggestion.cadence.bp722")
    }

    /// The web's miss fallback: an unknown key echoes back rather than
    /// rendering blank, so a future catalog addition degrades gracefully.
    @Test("Unknown COACH key falls back to the raw value")
    func coachLabelUnknownKeyEchoes() {
        let raw = "coach.reminderSuggestion.cadence.notInTheCatalogYet"
        #expect(VorsorgeCard.resolvedLabel(for: Self.labelRow(raw, origin: .coach)) == raw)
    }

    @Test("VORSORGE label is user prose and renders verbatim")
    func vorsorgeLabelVerbatim() {
        #expect(
            VorsorgeCard.resolvedLabel(for: Self.labelRow("  Blutdruck  ", origin: .vorsorge))
                == "Blutdruck"
        )
    }

    @Test("Blank label ⇒ nil so the caller falls back to the type label")
    func blankLabelIsNil() {
        #expect(VorsorgeCard.resolvedLabel(for: Self.labelRow("   ", origin: .vorsorge)) == nil)
        #expect(VorsorgeCard.resolvedLabel(for: Self.labelRow("", origin: .coach)) == nil)
    }

    // MARK: - Empty-state suppression

    @Test("Empty reminder list ⇒ show empty state")
    func emptyStateShown() {
        #expect(VorsorgeCard.shouldShowEmptyState(reminders: []))
    }

    @Test("Non-empty list ⇒ no empty state")
    func emptyStateHidden() {
        #expect(!VorsorgeCard.shouldShowEmptyState(reminders: [Self.row(type: "WEIGHT")]))
    }

    // MARK: - Adherence summary — REMOVED with its subject (G1, 2026-08-22)

    // Six cases lived here from b215 (`b84adbe0`) until 2026-08-23, pinning
    // `VorsorgeCard.adherenceSummary(...)`: the empty default, the full ring, the
    // overdue ratio, the exclusions, and 08-22's two snooze-cursor readings.
    //
    // They are gone because their subject is. G1 removes the „4 von 4 im Plan"
    // header on the operator's statement, and the fold behind it went with the
    // surface rather than staying as a tested function with no reader — a
    // documented, green aggregation is an invitation to re-mount the card, and
    // re-mounting it needs a NEW request (he asked for it on 2026-07-07 and
    // withdrew it on 2026-08-22).
    //
    // Nothing else regressed with them: `dueBucket`, `isSnoozed` and
    // `hasSkippedCurrentCycle` are untouched and still pinned above, and the
    // per-reminder completion ledger is pinned by `VorsorgeReminderHistoryTests`.
}
