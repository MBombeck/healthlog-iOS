import Foundation

// MARK: - Cadence form model (R1 §3.7)

/// The cadence kinds the iOS wizard exposes — a superset of the web's eight
/// (`src/components/medications/scheduling/types.ts` `CadenceKind`) plus the
/// two v1.7.0 additions W-Meds-A2 wired into the engine (`asNeeded` / `cyclic`,
/// SB-SCHED-5). The picker renders one row per case in this declaration order.
///
/// `oneShot` is a cadence kind here (it hides the recurrence sub-controls and
/// forces the course window to a single day) even though server-side it is a
/// medication-level boolean — the picker is the single place the user expresses
/// "this is a one-time dose".
enum CadenceKind: String, CaseIterable, Identifiable, Hashable {
    case daily
    case weekdays
    case everyNWeeks
    case monthly
    case everyNMonths
    case yearly
    case rolling
    case cyclic
    case oneShot
    case asNeeded

    var id: String {
        rawValue
    }
}

/// Mutable sub-control state for the cadence picker — mirrors the web's
/// `CadenceSubControls` (`types.ts`) plus the cyclic on/off-week steppers. The
/// picker remembers what the user typed even when they toggle the kind radio
/// back and forth, exactly like the web component.
struct CadenceSubControls: Equatable, Hashable {
    /// Selected weekdays for `weekdays` / `everyNWeeks` (Sunday-anchored 0…6).
    var weekdays: Set<Weekday>
    /// Multi-week interval (1…52) for `everyNWeeks`.
    var intervalWeeks: Int
    /// Day-of-month (1…31) for `monthly` / `everyNMonths`.
    var dayOfMonth: Int
    /// Multi-month interval (1…12) for `everyNMonths`.
    var intervalMonths: Int
    /// Anchor date whose month + day drive `yearly`.
    var yearlyDate: Date
    /// Rolling interval in days (1…365) for `rolling`.
    var rollingDays: Int
    /// Cyclic ON-week count (1…52) for `cyclic`. Named for the wire key the
    /// server actually publishes (`cyclicOnWeeks`) — 09-14 renamed it from
    /// `cycleWeeksOn`, which named a key that does not exist anywhere in the
    /// published contract and was the seam the whole cyclic defect lived in.
    var cyclicOnWeeks: Int
    /// Cyclic OFF-week count (0…52) for `cyclic`.
    ///
    /// **There is no anchor sub-control.** The on/off phase is counted from the
    /// medication's course start (`startsOn`, falling back to its creation day),
    /// which is what the server counts from; the picker's old anchor date field
    /// wrote to a wire key nobody accepts and duplicated the course-start
    /// control the sheets already show.
    var cyclicOffWeeks: Int

    /// Sensible defaults for a brand-new picker (mirrors the web's
    /// `DEFAULT_SUB_CONTROLS` where they overlap; the cyclic + yearly defaults
    /// pick a calm 3-on/1-off pattern and today's date).
    static func makeDefault(now: Date = .now) -> CadenceSubControls {
        CadenceSubControls(
            weekdays: [.mon],
            intervalWeeks: 2,
            dayOfMonth: 1,
            intervalMonths: 3,
            yearlyDate: now,
            rollingDays: 7,
            cyclicOnWeeks: 3,
            cyclicOffWeeks: 1
        )
    }
}

/// The fully-encoded cadence the form holds — the bridge between the picker's
/// `(kind, subControls)` and the wire `MedicationScheduleDTO`. Mirrors the
/// web's `CadenceValue` (`{ kind, rrule, rollingIntervalDays, oneShot }`)
/// extended with the v1.7.0 `asNeeded` flag and the cyclic on/off pair.
struct CadenceValue: Equatable, Hashable {
    let kind: CadenceKind
    /// RRULE for the calendar-anchored kinds; nil otherwise.
    let rrule: String?
    /// Rolling interval in days for `rolling`; nil otherwise.
    let rollingIntervalDays: Int?
    /// Medication-level single-administration flag (`oneShot`).
    let oneShot: Bool
    /// Schedule-level PRN flag (`asNeeded`).
    let asNeeded: Bool
    /// Cyclic ON-week count; nil unless `kind == .cyclic`.
    let cyclicOnWeeks: Int?
    /// Cyclic OFF-week count; nil unless `kind == .cyclic`.
    ///
    /// No anchor rides beside these: the server anchors the phase on the
    /// medication's `startsOn ?? createdAt` and publishes no per-schedule
    /// anchor (09-14).
    let cyclicOffWeeks: Int?
}
