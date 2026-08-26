import Foundation

// MARK: - v1.7.0 schedule-type discriminator (W10-PIN)

/// Server's authoritative cadence discriminator (v1.7.0 `scheduleType`).
/// `SCHEDULED` (calendar/rolling/legacy), `PRN` (as-needed), `CYCLIC`
/// (on/off-weeks). Forward-compatible: an unrecognised raw value collapses to
/// `.scheduled` so the remaining field-presence dispatch still applies and a
/// future server enum addition never breaks the decode. Required and
/// non-nullable on the published output schema.
public enum ScheduleType: String, Codable, Sendable, Hashable {
    /// Calendar / rolling / legacy cadences (rrule, rollingIntervalDays,
    /// daysOfWeek). The default when a server omits the tag.
    case scheduled = "SCHEDULED"
    /// As-needed — no expected-count, no occurrence projection, intakes still
    /// loggable. This is the row-level PRN tag. A whole-medication PRN is the
    /// MEDICATION-level `asNeeded` flag with an empty `schedules` array; the two
    /// spellings are both published and mean different things.
    case prn = "PRN"
    /// On/off-week dosing. Pairs with `cyclicOnWeeks`/`cyclicOffWeeks`; the
    /// phase anchor is the medication's `startsOn ?? createdAt`, not a
    /// per-schedule field.
    case cyclic = "CYCLIC"

    /// Lenient decode — an unrecognised string collapses to `.scheduled` instead
    /// of throwing, so the caller falls back to field-presence dispatch.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ScheduleType(rawValue: raw) ?? .scheduled
    }
}

// MARK: - v1.5 Cadence model (R1 §3.1)

/// Mirror of the server's 8 wizard cadence kinds
/// (`src/components/medications/scheduling/types.ts` + `CadencePicker.tsx`).
/// The recurrence engine (`MedicationRecurrenceEngine`) dispatches on this in
/// the same strict priority order the server uses: one-shot → rolling → rrule
/// → legacy. `Cadence` carries only the recurrence shape; times-of-day, grace,
/// and labels live on the parent ``ScheduleEntry``.
public enum Cadence: Sendable, Hashable, Codable {
    /// Every day. `rrule = "FREQ=DAILY"`.
    case daily
    /// A weekday subset. `rrule = "FREQ=WEEKLY;BYDAY=…"`.
    case weekdays(Set<Weekday>)
    /// Every N weeks on the given weekday set. `INTERVAL` up to 52
    /// (supersedes the legacy 1..4 clamp).
    case everyNWeeks(interval: Int, days: Set<Weekday>)
    /// Monthly on day-of-month D. `rrule = "FREQ=MONTHLY;BYMONTHDAY=D"`.
    case monthly(day: Int)
    /// Every N months on day-of-month D.
    case everyNMonths(interval: Int, day: Int)
    /// Annual on month M / day D. `rrule = "FREQ=YEARLY;BYMONTH=M;BYMONTHDAY=D"`.
    case yearly(month: Int, day: Int)
    /// Flexible rolling interval — re-anchors on each logged intake.
    case rolling(intervalDays: Int)
    /// Single administration (medication-level `oneShot = true`).
    case oneShot
    /// **v0.10 W-Meds-A2 (v1.7.0 SB-SCHED-5) — PRN / as-needed.** A row tagged
    /// `scheduleType: PRN`. Excluded from expected-count + reminder/occurrence
    /// projection (produces NO occurrences, NO nextOccurrence; `nextDueAt` is
    /// null) — but intakes remain loggable. Mirrors the server's PRN semantics
    /// (handover §6).
    case asNeeded
    /// **v0.10 W-Meds-A2 (v1.7.0 SB-SCHED-5) — cyclic on/off-weeks.** N weeks on
    /// / M weeks off. Within on-weeks the entry's `timesOfDay` fire every day;
    /// off-weeks are silent. Compliance + nextOccurrence honour the off-weeks.
    ///
    /// **09-14 — there is no anchor here, and that is the fix.** The phase is
    /// counted from the MEDICATION's `startsOn ?? createdAt`, snapped to the
    /// Sunday-rooted week — the server's own rule
    /// (`src/lib/medications/scheduling/recurrence.ts:246`), which iOS's engine
    /// already computes for every other phase-bearing cadence. The old
    /// `anchor: Date?` was read from a `cycleAnchor` wire key that appears zero
    /// times in the published contract, so it was always nil in practice and
    /// silently preferred over the anchor that is actually authoritative.
    case cyclic(weeksOn: Int, weeksOff: Int)
    /// Pre-v1.5 fallback decoded from the `daysOfWeek` string. `days == nil`
    /// (or empty) means every day.
    case legacy(days: Set<Weekday>?, intervalWeeks: Int)

    /// `true` when the cadence does not fire on every calendar day. Used by
    /// the medication card + detail glyph track so the two surfaces never
    /// drift (Cross-screen Consistency Check, R5).
    public var isWeeklyOrLowerFrequency: Bool {
        switch self {
        case .daily:
            false
        case let .legacy(days, intervalWeeks):
            // W42 — a full 7-day legacy set fires every calendar day (daily),
            // mirror `MedicationSchedule.isWeeklyCadence`: weekly needs a PROPER
            // subset (1..6) or a multi-week interval.
            intervalWeeks > 1 || ((days.map { !$0.isEmpty && $0.count < 7 }) ?? false)
        case .weekdays, .everyNWeeks, .monthly, .everyNMonths, .yearly,
             .rolling, .oneShot, .asNeeded, .cyclic:
            true
        }
    }
}

/// A minimal RFC-5545 RRULE subset parser/encoder — exactly the shape the
/// web wizard mints (`FREQ`, `INTERVAL`, `BYDAY`, `BYMONTHDAY`, `BYMONTH`,
/// plus `COUNT` / `UNTIL` pass-through). Mirrors the `RRULE_PROPS` regex in
/// `src/lib/validations/medication.ts`. Decode for the read path; encode for
/// the write path (W-Meds-B).
public enum RRULE {
    /// RFC-5545 BYDAY weekday tokens, indexed by our `Weekday` raw value
    /// (Sun = 0 … Sat = 6).
    static let weekdayTokens: [Weekday: String] = [
        .sun: "SU", .mon: "MO", .tue: "TU", .wed: "WE",
        .thu: "TH", .fri: "FR", .sat: "SA"
    ]

    private static let tokenToWeekday: [String: Weekday] = Dictionary(
        uniqueKeysWithValues: weekdayTokens.map { ($0.value, $0.key) }
    )

    /// Parse an RRULE string into the canonical `Cadence`. Returns `nil` for
    /// unrecognised / malformed shapes so the caller falls back to legacy.
    public static func parseCadence(_ rrule: String) -> Cadence? {
        let props = parseProps(rrule)
        guard let freq = props["FREQ"] else { return nil }
        let interval = props["INTERVAL"].flatMap { Int($0) } ?? 1
        switch freq {
        case "DAILY":
            return .daily
        case "WEEKLY":
            let days = parseByDay(props["BYDAY"])
            if interval > 1 {
                return .everyNWeeks(interval: max(1, interval), days: days)
            }
            // INTERVAL=1 with a BYDAY subset is a weekday cadence; an empty
            // BYDAY collapses to plain daily-equivalent weekly → treat as daily.
            return days.isEmpty ? .daily : .weekdays(days)
        case "MONTHLY":
            let day = props["BYMONTHDAY"].flatMap { Int($0.split(separator: ",").first.map(String.init) ?? "") } ?? 1
            if interval > 1 {
                return .everyNMonths(interval: max(1, interval), day: clampDayOfMonth(day))
            }
            return .monthly(day: clampDayOfMonth(day))
        case "YEARLY":
            let month = props["BYMONTH"].flatMap { Int($0.split(separator: ",").first.map(String.init) ?? "") } ?? 1
            let day = props["BYMONTHDAY"].flatMap { Int($0.split(separator: ",").first.map(String.init) ?? "") } ?? 1
            return .yearly(month: max(1, min(12, month)), day: clampDayOfMonth(day))
        default:
            return nil
        }
    }

    /// Encode a `Cadence` back into its RRULE string. Returns `nil` for the
    /// non-RRULE kinds (`rolling`, `oneShot`, `legacy`) — those are carried
    /// by `rollingIntervalDays` / `oneShot` / `daysOfWeek` respectively.
    public static func encode(_ cadence: Cadence) -> String? {
        switch cadence {
        case .daily:
            return "FREQ=DAILY"
        case let .weekdays(days):
            return "FREQ=WEEKLY;BYDAY=\(encodeByDay(days))"
        case let .everyNWeeks(interval, days):
            let base = "FREQ=WEEKLY;INTERVAL=\(max(1, interval))"
            return days.isEmpty ? base : "\(base);BYDAY=\(encodeByDay(days))"
        case let .monthly(day):
            return "FREQ=MONTHLY;BYMONTHDAY=\(clampDayOfMonth(day))"
        case let .everyNMonths(interval, day):
            return "FREQ=MONTHLY;INTERVAL=\(max(1, interval));BYMONTHDAY=\(clampDayOfMonth(day))"
        case let .yearly(month, day):
            return "FREQ=YEARLY;BYMONTH=\(max(1, min(12, month)));BYMONTHDAY=\(clampDayOfMonth(day))"
        case .rolling, .oneShot, .legacy, .asNeeded, .cyclic:
            // Carried by `rollingIntervalDays` / med-level `oneShot` /
            // `daysOfWeek` / `scheduleType: PRN` / the cyclic pair
            // respectively — not an RRULE.
            return nil
        }
    }

    // MARK: - Internal parsing helpers

    /// Split an RRULE body into its `KEY=VALUE` props. Tolerates an optional
    /// `RRULE:` prefix and surrounding whitespace.
    static func parseProps(_ rrule: String) -> [String: String] {
        var body = rrule.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = body.firstIndex(of: ":"), body.hasPrefix("RRULE:") {
            body = String(body[body.index(after: colon)...])
        }
        var result: [String: String] = [:]
        for pair in body.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            result[String(kv[0]).uppercased()] = String(kv[1])
        }
        return result
    }

    static func parseByDay(_ value: String?) -> Set<Weekday> {
        guard let value, !value.isEmpty else { return [] }
        var days: Set<Weekday> = []
        for token in value.split(separator: ",") {
            if let weekday = tokenToWeekday[String(token).uppercased()] {
                days.insert(weekday)
            }
        }
        return days
    }

    /// Encode a weekday set into a BYDAY token list, ordered Mon→Sun to match
    /// the wizard's canonical ordering.
    static func encodeByDay(_ days: Set<Weekday>) -> String {
        let order: [Weekday] = [.mon, .tue, .wed, .thu, .fri, .sat, .sun]
        return order
            .filter { days.contains($0) }
            .compactMap { weekdayTokens[$0] }
            .joined(separator: ",")
    }

    private static func clampDayOfMonth(_ day: Int) -> Int {
        max(1, min(31, day))
    }
}

/// One schedule row on a medication, decoded non-lossily from a
/// `MedicationScheduleDTO`. Replaces the old single-flattened `times` list:
/// every server schedule row maps to exactly one `ScheduleEntry`, carrying
/// its own cadence, times-of-day, grace, and label/dose overrides.
public struct ScheduleEntry: Sendable, Hashable, Codable {
    public let cadence: Cadence
    public let timesOfDay: [TimeOfDay]
    public let reminderGraceMinutes: Int?
    public let label: String?
    public let dose: String?
    /// Preserved legacy window bounds — fed to the engine's grace fallback
    /// (`windowEnd - windowStart`) when `reminderGraceMinutes` is nil.
    public let windowStart: TimeOfDay
    public let windowEnd: TimeOfDay?
    /// v1.15.18 per-dose on-time windows (W3-MEDCONTRACT, v0.14.8) —
    /// carried non-lossily so the schedule-edit RMW path can echo them
    /// back on a `schedules` REPLACE (the server resets omitted windows to
    /// NULL) and so the detail Plan section can display the band. `nil` →
    /// server default (±1 h derivation).
    public let doseWindows: [MedicationDoseWindowDTO]?
    /// **v1.37.10 (#219) — the user's RAW per-slot inventory-units override.**
    /// `nil` means "inherit the medication-level `unitsPerDose`", and that is a
    /// choice in its own right: an edit surface that rebuilds this from the
    /// resolved figure below would promote inheritance into an explicit
    /// override the user never made. Edit / read-modify-write paths read THIS
    /// one (plan 08-21 owns those consumers).
    public let unitsPerDose: Double?
    /// **v1.37.19 — the server-EFFECTIVE units one dose of this slot consumes.**
    /// Resolved server-side as `schedule.unitsPerDose ?? medication.unitsPerDose`
    /// by the same resolver the intake consumption path uses, so no client ever
    /// re-derives the inheritance rule. Display and supply consumers read this
    /// one (plan 08-20 owns those).
    ///
    /// It rides a decode and it survives the on-device cache — `ScheduleEntry`
    /// is a domain type, not a write body — but it can never leave the device,
    /// because `MedicationScheduleDTO.encode(to:)` drops the wire key.
    /// `nil` only at a legacy-cache or pre-v1.37.19 self-hosted boundary; the
    /// published schema marks the field required.
    public let resolvedUnitsPerDose: Double?

    public init(
        cadence: Cadence,
        timesOfDay: [TimeOfDay],
        reminderGraceMinutes: Int? = nil,
        label: String? = nil,
        dose: String? = nil,
        windowStart: TimeOfDay,
        windowEnd: TimeOfDay? = nil,
        doseWindows: [MedicationDoseWindowDTO]? = nil,
        unitsPerDose: Double? = nil,
        resolvedUnitsPerDose: Double? = nil
    ) {
        self.cadence = cadence
        self.timesOfDay = timesOfDay
        self.reminderGraceMinutes = reminderGraceMinutes
        self.label = label
        self.dose = dose
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.doseWindows = doseWindows
        self.unitsPerDose = unitsPerDose
        self.resolvedUnitsPerDose = resolvedUnitsPerDose
    }

    /// Effective times-of-day applied per matched day — falls back to
    /// `[windowStart]` when `timesOfDay` is empty (mirrors the engine's
    /// `effectiveTimesOfDay`).
    public var effectiveTimes: [TimeOfDay] {
        timesOfDay.isEmpty ? [windowStart] : timesOfDay
    }

    /// Decode a server schedule DTO into a non-lossy `ScheduleEntry`, applying
    /// the server's dispatch precedence for the cadence: oneShot → asNeeded →
    /// cyclic → rolling → rrule → legacy. (One-shot is medication-level and is
    /// applied by the caller.)
    ///
    /// **v0.10 W-Meds-A2 (v1.7.0):** PRN takes priority over rolling/rrule so a
    /// schedule flagged as-needed never projects, even if it still carries a
    /// stale `rrule`/`rollingIntervalDays`. Cyclic on/off-weeks are the next tier.
    ///
    /// **09-14:** `scheduleType` is **required and non-nullable** on the accepted
    /// `MedicationScheduleOutput`, so on a real read it is the only dispatch
    /// input that exists. The old PRN field-presence fallback read a
    /// schedule-level `asNeeded` the output schema does not publish (and the
    /// input schema does not accept), so it could never fire; it is gone rather
    /// than kept as decoration. The cyclic field-presence arm is kept — the two
    /// week counts ARE published, so a payload that carries them without the tag
    /// is still legible — and it now reads the real key names.
    public static func fromDTO(_ dto: MedicationScheduleDTO, oneShot: Bool) -> ScheduleEntry {
        let windowStart = TimeOfDay.parse(dto.windowStart) ?? TimeOfDay(hour: 8, minute: 0)
        let windowEnd = dto.windowEnd.flatMap { TimeOfDay.parse($0) }
        let times = (dto.timesOfDay ?? []).compactMap { TimeOfDay.parse($0) }

        let cadence: Cadence
        if oneShot {
            cadence = .oneShot
        } else if dto.scheduleType == .prn {
            // PRN: the authoritative tag, which the output schema always sends.
            cadence = .asNeeded
        } else if dto.scheduleType == .cyclic, let cyclic = Self.cyclicCadence(from: dto) {
            // Cyclic via the authoritative tag (degenerate cycle fields fall through).
            cadence = cyclic
        } else if let cyclic = Self.cyclicCadence(from: dto) {
            // Field-presence fallback when the server omits scheduleType.
            cadence = cyclic
        } else if let rolling = dto.rollingIntervalDays, rolling > 0 {
            cadence = .rolling(intervalDays: rolling)
        } else if let rrule = dto.rrule, let parsed = RRULE.parseCadence(rrule) {
            cadence = parsed
        } else {
            let parsed = MedicationScheduleRecurrence.parse(dto.daysOfWeek)
            let days = Set(parsed.daysOfWeek.compactMap { Weekday(rawValue: $0) })
            cadence = .legacy(days: days.isEmpty ? nil : days, intervalWeeks: parsed.intervalWeeks)
        }

        return ScheduleEntry(
            cadence: cadence,
            timesOfDay: times,
            reminderGraceMinutes: dto.reminderGraceMinutes,
            label: dto.label,
            dose: dto.dose,
            windowStart: windowStart,
            windowEnd: windowEnd,
            doseWindows: dto.doseWindows,
            // Raw intent and resolved read truth stay two separate values all
            // the way into the domain — neither is derived from the other here.
            unitsPerDose: dto.unitsPerDose,
            resolvedUnitsPerDose: dto.resolvedUnitsPerDose
        )
    }

    /// Build a `.cyclic` cadence from the DTO's `cyclicOnWeeks`/`cyclicOffWeeks`.
    /// Returns `nil` when the fields are absent or degenerate (`weeksOn ≤ 0`) so
    /// the caller falls through to rolling/rrule/legacy — a schedule with no
    /// on-weeks is not a cyclic schedule. A `weeksOff ≤ 0` collapses to "always
    /// on" but we still model it as cyclic so the engine path is explicit.
    ///
    /// No anchor is read, because none is published. See ``Cadence/cyclic``.
    static func cyclicCadence(from dto: MedicationScheduleDTO) -> Cadence? {
        guard let weeksOn = dto.cyclicOnWeeks, weeksOn > 0 else { return nil }
        let weeksOff = max(0, dto.cyclicOffWeeks ?? 0)
        return .cyclic(weeksOn: weeksOn, weeksOff: weeksOff)
    }
}

public struct MedicationSchedule: Codable, Sendable, Hashable {
    public let times: [TimeOfDay]
    public let weekdays: Set<Weekday>?
    /// Server encodes weekly-interval recurrences (e.g. every-other-week
    /// GLP-1 dosing) as the `iN;` prefix on the `daysOfWeek` string. Range
    /// is 1...4 per `src/lib/medication-schedule.ts`. Default = 1 (every
    /// week).
    public let intervalWeeks: Int

    /// **v0.10 R1 — non-lossy per-schedule entries.** One element per server
    /// `MedicationSchedule` row, each carrying its full cadence (rolling /
    /// RRULE / legacy), times-of-day, grace, and label/dose overrides. The
    /// recurrence engine routes through this; the legacy `times`/`weekdays`/
    /// `intervalWeeks` triple above stays for the pre-v0.10 render surfaces
    /// (flattened from `entries` by `toDomain()`). When constructed via the
    /// legacy initialiser (tests, ad-hoc), a single legacy entry is synthesised
    /// so the engine still has a faithful row to expand.
    public let entries: [ScheduleEntry]

    public init(times: [TimeOfDay], weekdays: Set<Weekday>? = nil, intervalWeeks: Int = 1) {
        self.times = times
        self.weekdays = weekdays
        self.intervalWeeks = max(1, min(4, intervalWeeks))
        // Synthesise a single legacy entry mirroring the flattened triple so
        // the engine has a row to expand even for legacy-constructed schedules.
        // An empty `times` is the PRN / no-schedule case (e.g. `schedules: []`
        // on the wire) — emit NO entry so the engine synthesises nothing,
        // preserving the prior "no times → no placeholder" contract.
        if times.isEmpty {
            entries = []
        } else {
            let clampedInterval = max(1, min(4, intervalWeeks))
            let cadence: Cadence = if clampedInterval > 1 {
                .legacy(days: (weekdays?.isEmpty == false) ? weekdays : nil, intervalWeeks: clampedInterval)
            } else if let weekdays, !weekdays.isEmpty {
                .weekdays(weekdays)
            } else {
                .daily
            }
            entries = [ScheduleEntry(
                cadence: cadence,
                timesOfDay: times,
                windowStart: times[0]
            )]
        }
    }

    /// Designated initialiser for the non-lossy read path. `times`/`weekdays`/
    /// `intervalWeeks` are derived (flattened) from `entries` for the legacy
    /// render surfaces.
    public init(entries: [ScheduleEntry]) {
        self.entries = entries
        times = entries.flatMap(\.effectiveTimes).sorted()
        var unionedWeekdays: Set<Weekday> = []
        var sawWeekdays = false
        var maxInterval = 1
        for entry in entries {
            switch entry.cadence {
            case let .weekdays(days):
                if !days.isEmpty { sawWeekdays = true
                    unionedWeekdays.formUnion(days)
                }
            case let .everyNWeeks(interval, days):
                if !days.isEmpty { sawWeekdays = true
                    unionedWeekdays.formUnion(days)
                }
                maxInterval = max(maxInterval, min(4, interval))
            case let .legacy(days, interval):
                if let days, !days.isEmpty { sawWeekdays = true
                    unionedWeekdays.formUnion(days)
                }
                maxInterval = max(maxInterval, min(4, interval))
            case .daily, .monthly, .everyNMonths, .yearly, .rolling, .oneShot,
                 .asNeeded, .cyclic:
                break
            }
        }
        weekdays = sawWeekdays ? unionedWeekdays : nil
        intervalWeeks = max(1, min(4, maxInterval))
    }

    // MARK: - Codable (back-compat: `entries` is optional on decode)

    private enum CodingKeys: String, CodingKey {
        case times, weekdays, intervalWeeks, entries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let times = try container.decode([TimeOfDay].self, forKey: .times)
        let weekdays = try container.decodeIfPresent(Set<Weekday>.self, forKey: .weekdays)
        let intervalWeeks = try container.decodeIfPresent(Int.self, forKey: .intervalWeeks) ?? 1
        // `entries` was added in v0.10; older cached payloads omit it. When
        // absent, re-derive a single legacy entry from the flattened triple.
        if let entries = try container.decodeIfPresent([ScheduleEntry].self, forKey: .entries),
           !entries.isEmpty
        {
            self.init(entries: entries)
        } else {
            self.init(times: times, weekdays: weekdays, intervalWeeks: intervalWeeks)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(times, forKey: .times)
        try container.encodeIfPresent(weekdays, forKey: .weekdays)
        try container.encode(intervalWeeks, forKey: .intervalWeeks)
        try container.encode(entries, forKey: .entries)
    }

    /// Whether the schedule would fire any dose on `day`. Honours
    /// both `weekdays` (Sun=0..Sat=6) and `intervalWeeks` (`iN;`
    /// recurrence anchored on ISO week-of-year modulo). When neither
    /// constraint is set the schedule fires every day.
    ///
    /// **Why local to the model:** the server's `calculateCompliance`
    /// (src/lib/analytics/compliance.ts) ignores `daysOfWeek` +
    /// `intervalWeeks` when it builds `totalExpected = schedules.length
    /// * effectiveDays`, so a weekly Trulicity reads `totalExpected = 30`
    /// in the v0.6.2.3 B1 payload. The detail-screen KPI consumes
    /// server `taken`/`skipped` (correct — only generated for actual
    /// scheduled instants) but recomputes the denominator from this
    /// helper so the bar reflects the real cadence. Mirrors the
    /// existing `MedicationsStore+DerivedIntakes.medicationFiresToday`
    /// algorithm; kept on the model so any compliance surface can
    /// reach for it without store coupling.
    public func fires(on day: Date, calendar: Calendar = .current) -> Bool {
        let startOfDay = calendar.startOfDay(for: day)
        if let weekdays, !weekdays.isEmpty {
            let weekdayIndex = calendar.component(.weekday, from: startOfDay) - 1
            guard let weekday = Weekday(rawValue: weekdayIndex),
                  weekdays.contains(weekday) else { return false }
        }
        guard intervalWeeks > 1 else { return true }
        var isoCal = Calendar(identifier: .iso8601)
        isoCal.timeZone = calendar.timeZone
        let weekOfYear = isoCal.component(.weekOfYear, from: startOfDay)
        return weekOfYear % intervalWeeks == 0
    }

    /// Total expected doses across the half-open range `[start, end)`.
    /// Sums `times.count` for every day in the range that the schedule
    /// fires on. Returns 0 when no times are configured.
    public func expectedDoses(
        from start: Date,
        to end: Date,
        calendar: Calendar = .current
    ) -> Int {
        guard !times.isEmpty, start < end else { return 0 }
        let dayStart = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        var cursor = dayStart
        var firingDays = 0
        while cursor < endDay {
            if fires(on: cursor, calendar: calendar) {
                firingDays += 1
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return firingDays * times.count
    }

    /// **v0.10 R1 §3.9 — cadence-correct expected-dose count via the engine.**
    ///
    /// The legacy `expectedDoses(from:to:)` above counts `times.count` per
    /// firing day using `fires(on:)`, which only understands weekday +
    /// intervalWeeks — wrong for rolling / monthly / yearly. This overload
    /// routes through `MedicationRecurrenceEngine`, so the denominator is the
    /// actual occurrence count the schedule predicts over `[start, end]` in the
    /// user timezone. Prefer this on every compliance surface that has a
    /// `MedicationRecurrenceEngine.Context`.
    public func expectedDoses(
        from start: Date,
        to end: Date,
        context: MedicationRecurrenceEngine.Context
    ) -> Int {
        guard start < end, !entries.isEmpty else { return 0 }
        var total = 0
        for entry in entries {
            total += MedicationRecurrenceEngine.occurrences(
                in: start ... end,
                entry: entry,
                context: context
            ).count
        }
        return total
    }

    /// v0.10 R5 — shared cadence predicate. `true` when the schedule does not
    /// fire on every calendar day (interval > 1 week, or a PROPER weekday subset
    /// is configured). Single source of truth for both the med card
    /// (`ActiveMedicationRow`) and the detail glyph track (`VerlaufGlyphTrack`)
    /// so the two surfaces never drift (Cross-screen Consistency Check).
    ///
    /// **W42 (v0.11) fix:** a weekday set covering ALL seven days encodes "every
    /// calendar day" (some server rows serialise a daily med as
    /// `daysOfWeek = "0,1,2,3,4,5,6"`). That is a DAILY cadence, not a weekly
    /// one — the prior `(weekdays?.count ?? 0) > 0` flagged it weekly, collapsing
    /// a twice-daily Lisinopril's Verlauf glyph track to the degenerate due-count
    /// strip. Weekly now requires a *proper* subset (1..6 weekdays); a full
    /// 7-day set reads daily. The `intervalWeeks > 1` arm still drives weekly for
    /// multi-week interval schedules regardless of the weekday set.
    public var isWeeklyCadence: Bool {
        if intervalWeeks > 1 { return true }
        guard let weekdays else { return false }
        return !weekdays.isEmpty && weekdays.count < 7
    }
}
