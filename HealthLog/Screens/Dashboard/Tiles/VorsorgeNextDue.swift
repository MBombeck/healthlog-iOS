import Foundation

/// **v0.15 W-FRONTDOORS — pure next-due selection + capture-prefill mapping for
/// the Home Vorsorge tile.**
///
/// Split out of the view so the two decisions the tile rests on are unit-tested
/// without a SwiftUI host:
///
/// 1. **Which reminder leads the tile** (`nextDueNow(from:)`). The server already
///    sorts `GET /api/measurement-reminders` by `nextDueAt` ascending, but the
///    tile must pick the soonest *enabled* reminder that is **actually due now**
///    (today or overdue per the server-stamped `nextDueAt`) — a disabled
///    reminder, a free-text one whose `nextDueAt` is still `nil`, or one merely
///    *upcoming* (due in the future) must NOT become the lead (operator b198
///    walkthrough V1: the Home card shows only when something must be done now).
///    The selection is render-only — it NEVER recomputes a due date, it only
///    filters on the due-bucket the server's `nextDueAt` falls into and picks the
///    minimum. (`nextDue(from:)` — the prior has-a-date variant — is retained for
///    callers that legitimately want the soonest upcoming item.)
/// 2. **Which `MetricKind` the "jetzt messen" button prefills**
///    (`prefillKind(forServerType:)`). The reminder's `measurementType` is the
///    server's UPPER_SNAKE wire value (e.g. `BLOOD_PRESSURE_SYS`, `WEIGHT`,
///    `PULSE`); the capture sheet speaks `MetricKind`. A free-text reminder
///    (`measurementType == nil`) or a type the manual-capture sheet can't record
///    maps to `nil`, in which case the tile offers a plain "open Vorsorge" tap
///    rather than a dead prefilled button.
///
/// Empty-tile doctrine: `nextDueNow(from:)` returning `nil` is the signal the
/// tile self-suppresses (no reminders, or none DUE now) — never a dead/empty
/// tile.
enum VorsorgeNextDue {
    /// The soonest enabled reminder that carries a server `nextDueAt`. `nil` when
    /// the list is empty or no enabled reminder has a due date yet.
    static func nextDue(from reminders: [MeasurementReminderRow]) -> MeasurementReminderRow? {
        reminders
            .compactMap { row -> (Date, MeasurementReminderRow)? in
                guard row.enabled, let due = row.nextDueAt else { return nil }
                return (due, row)
            }
            .min { $0.0 < $1.0 }
            .map(\.1)
    }

    /// **V1 (v0.15.2 felt-wave) — the soonest enabled reminder that is actually
    /// DUE now (today or overdue), or `nil` when nothing is due.**
    ///
    /// The Home tile must surface a reminder ONLY when it must be done now — an
    /// upcoming-but-not-yet-due reminder no longer leads the Home card (operator
    /// b198 walkthrough V1). "Due" is server-authoritative: it reuses
    /// `VorsorgeCard.dueBucket` (the web `relativeDueKey` mirror) over the
    /// server-stamped `nextDueAt` and treats only `.today` / `.overdue`
    /// (`DueBucket.isDue`) as due — never a client cadence recompute. Among the
    /// due reminders the soonest `nextDueAt` leads (overdue items sort first,
    /// being the smallest dates). `nil` ⇒ the tile self-suppresses (no dead/empty
    /// slab), exactly as before — just gated on due-now instead of has-a-date.
    static func nextDueNow(
        from reminders: [MeasurementReminderRow],
        now: Date = .now
    ) -> MeasurementReminderRow? {
        reminders
            .compactMap { row -> (Date, MeasurementReminderRow)? in
                guard row.enabled, let due = row.nextDueAt else { return nil }
                guard VorsorgeCard.dueBucket(nextDueAt: due, now: now).isDue else { return nil }
                return (due, row)
            }
            .min { $0.0 < $1.0 }
            .map(\.1)
    }

    /// Maps a server reminder `measurementType` (UPPER_SNAKE) onto the
    /// `MetricKind` the manual-capture `MeasureSheetView` can prefill. Returns
    /// `nil` for a free-text reminder (`nil` type) or a type the capture sheet
    /// does not support (so the tile won't offer a prefilled button that dies).
    static func prefillKind(forServerType serverType: String?) -> MetricKind? {
        guard let serverType, !serverType.isEmpty else { return nil }
        return serverTypeToKind[serverType]
    }

    /// Server UPPER_SNAKE `measurementType` → manual-capturable `MetricKind`.
    /// Deliberately limited to the intersection of the create-sheet catalog
    /// (`MeasurementReminderType`) AND `MeasureSheetView.supportedKinds` — the
    /// kinds the manual-capture sheet can actually record. A reminder whose type
    /// is outside this set (e.g. `MUSCLE_MASS`, only derivable from a scale)
    /// returns `nil`, so the tile offers a plain "open Vorsorge" tap rather than
    /// a prefilled button that would land the user on the wrong (fallback) kind.
    /// `BLOOD_PRESSURE_SYS` is the reminder's BP wire value (BP is two rows
    /// server-side; the SYS reminder represents "measure blood pressure").
    private static let serverTypeToKind: [String: MetricKind] = [
        "WEIGHT": .weight,
        "BLOOD_PRESSURE_SYS": .bloodPressure,
        "PULSE": .pulse,
        "BLOOD_GLUCOSE": .glucose,
        "OXYGEN_SATURATION": .spo2,
        "BODY_TEMPERATURE": .bodyTemperature,
        "BODY_FAT": .bodyFat,
        "TOTAL_BODY_WATER": .bodyWater,
        "BONE_MASS": .boneMass,
        "WAIST_CIRCUMFERENCE": .waistCircumference
        // Build 1 / item 1.4a — `BODY_MASS_INDEX` → `.bmi` was dropped here in
        // lockstep with `.bmi` leaving `MeasureSheetView.supportedKinds`. The
        // sheet ignores an unsupported prefill and falls back to the last-used
        // kind, so keeping the mapping would have produced exactly the
        // "prefilled button that lands the user on the wrong kind" this map
        // exists to prevent. A BMI reminder now offers the plain "open Vorsorge"
        // tap until manual BMI entry (weight + height) is designed.
    ]
}
