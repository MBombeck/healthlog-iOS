import Foundation

public struct MedicationScheduleDTO: Codable, Sendable, Hashable {
    /// `HH:mm` (24h, server-side validated).
    public let windowStart: String
    public let windowEnd: String?
    public let label: String?
    public let dose: String?

    // MARK: - v1.37.10 / v1.37.19 per-slot inventory dose (#219)

    /// **v1.37.10 `unitsPerDose` — the user's RAW per-slot override.**
    /// `number | null`, and the `null` is a value in its own right: it means
    /// "this slot inherits the medication-level `unitsPerDose`". Kept raw so an
    /// edit surface can tell an explicit choice from inheritance. This is the
    /// half that legitimately travels on a write; plan 08-21 owns the edit /
    /// read-modify-write consumers and the tri-state clearing question.
    public let unitsPerDose: Double?
    /// **v1.37.19 `resolvedUnitsPerDose` — the server-EFFECTIVE per-slot dose.**
    /// `schedule.unitsPerDose ?? medication.unitsPerDose`, resolved server-side
    /// by the same resolver the intake consumption path uses. The published
    /// schema marks it **required** and non-nullable; it is optional here only
    /// so a legacy cache blob and a pre-v1.37.19 self-hosted server still
    /// decode. Read-only in the strong sense — ``encode(to:)`` below drops it,
    /// so it cannot enter a create or update body through any caller.
    public let resolvedUnitsPerDose: Double?

    /// Server emits `daysOfWeek` as the raw Prisma column value — a
    /// **String** like `"1,2,3"` (legacy days-only) or `"i2;1,2,3"`
    /// (interval-prefix encoding `iN;` + days, mirrors
    /// `src/lib/medication-schedule.ts` `parseScheduleRecurrence`).
    ///
    /// Pre-v0.4.0 iOS expected `[Int]?` and decoded `typeMismatch`
    /// on every medication that had a non-null schedule (A4-Audit
    /// row 2). Parsing happens client-side via `Domain.toDomain()`.
    public let daysOfWeek: String?

    // MARK: - v1.5 first-class schedule fields (R1 §3.1)

    /// First-class points-in-time the dose is taken (`HH:mm`, user local).
    /// Up to 8 entries. Empty / absent falls back to `[windowStart]`.
    public let timesOfDay: [String]?
    /// RFC-5545 RRULE subset for calendar-anchored cadences. Mutually
    /// exclusive with `rollingIntervalDays`.
    public let rrule: String?
    /// Flexible-rolling interval in days, counted forward from the latest
    /// non-skipped intake. Mutually exclusive with `rrule`. Range 1..365.
    public let rollingIntervalDays: Int?
    /// Reminder grace window in minutes (1..1440). `nil` falls back to the
    /// legacy `windowEnd - windowStart` span.
    public let reminderGraceMinutes: Int?

    // MARK: - v1.7.0 PRN + cyclic schedule fields (W-Meds-A2, SB-SCHED-5)

    /// **Cyclic ON-week count (`cyclicOnWeeks`).** N weeks on, 1…52 on the
    /// input schema, `integer | null` and **required** on the output schema
    /// (null unless `scheduleType` is CYCLIC).
    ///
    /// **09-14 — this used to be spelled `cycleWeeksOn` and no such key exists.**
    /// `cycleWeeksOn`, `cycleWeeksOff` and `cycleAnchor` occur **zero** times in
    /// the accepted v1.37.24 contract, so the decode guard could never hold and
    /// every CYCLIC schedule fell through to rolling/rrule/legacy, while every
    /// cyclic write was Zod-stripped into a plain SCHEDULED row.
    public let cyclicOnWeeks: Int?
    /// **Cyclic OFF-week count (`cyclicOffWeeks`).** M weeks off, 0…52.
    ///
    /// There is deliberately **no anchor beside these two.** The server anchors
    /// the on/off phase on the MEDICATION's `startsOn ?? createdAt`, snapped to
    /// the Sunday-rooted UTC week; it publishes no per-schedule anchor and has
    /// nowhere to store one. The absence is structural rather than a nullable
    /// field that happens to always be nil, because a nullable field that is
    /// always nil is an invitation to repopulate it.
    public let cyclicOffWeeks: Int?
    /// **Authoritative cadence discriminator (`scheduleType`, v1.7.0).**
    /// `SCHEDULED|PRN|CYCLIC`. **Required and non-nullable on the output
    /// schema**, so on a read it is the only dispatch input needed — the old
    /// field-presence fallbacks were dead against a schema that always sends it.
    /// On the input schema it is optional with a documented `SCHEDULED` default,
    /// and it must still be sent for CYCLIC: the two week counts are explicitly
    /// "ignored otherwise". Optional here only so a legacy cache blob decodes.
    public let scheduleType: ScheduleType?

    // MARK: - v1.15.18 per-dose intake windows (W3-MEDCONTRACT, v0.14.8)

    /// Explicit per-dose on-time windows (`doseWindowEntrySchema`): each
    /// entry keys a `timesOfDay` dose time and carries the `[start, end]`
    /// on-time band (HH:mm, user local). Absent / `nil` → the server's
    /// default ±1 h derivation applies. **RMW caution:** a `schedules`
    /// REPLACE re-creates the rows server-side — a rebuilt schedule that
    /// omits this field resets the user's configured windows to NULL, so
    /// schedule-editing callers must echo the decoded windows for every
    /// surviving dose time (see `MedicationCadenceLogic.buildSchedules`).
    public let doseWindows: [MedicationDoseWindowDTO]?

    public init(
        windowStart: String,
        windowEnd: String? = nil,
        label: String? = nil,
        dose: String? = nil,
        unitsPerDose: Double? = nil,
        resolvedUnitsPerDose: Double? = nil,
        daysOfWeek: String? = nil,
        timesOfDay: [String]? = nil,
        rrule: String? = nil,
        rollingIntervalDays: Int? = nil,
        reminderGraceMinutes: Int? = nil,
        cyclicOnWeeks: Int? = nil,
        cyclicOffWeeks: Int? = nil,
        scheduleType: ScheduleType? = nil,
        doseWindows: [MedicationDoseWindowDTO]? = nil
    ) {
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.label = label
        self.dose = dose
        self.unitsPerDose = unitsPerDose
        self.resolvedUnitsPerDose = resolvedUnitsPerDose
        self.daysOfWeek = daysOfWeek
        self.timesOfDay = timesOfDay
        self.rrule = rrule
        self.rollingIntervalDays = rollingIntervalDays
        self.reminderGraceMinutes = reminderGraceMinutes
        self.cyclicOnWeeks = cyclicOnWeeks
        self.cyclicOffWeeks = cyclicOffWeeks
        self.scheduleType = scheduleType
        self.doseWindows = doseWindows
    }

    /// **09-14 — every key here is declared by `MedicationScheduleInput`, and
    /// every key the output publishes that iOS reads is here.** The three that
    /// used to be listed and are not — `cycleWeeksOn`, `cycleWeeksOff`,
    /// `cycleAnchor` — occur zero times in the accepted contract. A
    /// schedule-level `asNeeded` is gone for the same reason: PRN is spelled
    /// `scheduleType: PRN` on a row, and a whole-medication PRN is the
    /// medication-level `asNeeded` flag with an empty `schedules` array.
    private enum CodingKeys: String, CodingKey {
        case windowStart, windowEnd, label, dose
        case unitsPerDose, resolvedUnitsPerDose
        case daysOfWeek, timesOfDay, rrule, rollingIntervalDays, reminderGraceMinutes
        case cyclicOnWeeks, cyclicOffWeeks, scheduleType
        case doseWindows
    }

    /// **The one place `resolvedUnitsPerDose` is kept out of a write.**
    ///
    /// This type is both the read row and the payload of every `schedules`
    /// REPLACE (`MedicationsRepository.MedicationCreate` / `.MedicationPatch`
    /// carry `[MedicationScheduleDTO]` verbatim), so a schedule edit is a
    /// read-modify-write over decoded server rows. A synthesised encoder would
    /// therefore echo the server's own resolved figure straight back as if the
    /// user had chosen it — promoting inheritance into an explicit per-slot
    /// override nobody asked for, and doing it silently. Excluding the key here
    /// rather than at each call site means no future caller can reintroduce it.
    ///
    /// Every other key keeps the synthesised behaviour exactly: `encodeIfPresent`
    /// for the optionals, so an omitted field stays omitted rather than becoming
    /// an explicit `null`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(windowStart, forKey: .windowStart)
        try container.encodeIfPresent(windowEnd, forKey: .windowEnd)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(dose, forKey: .dose)
        try container.encodeIfPresent(unitsPerDose, forKey: .unitsPerDose)
        // `resolvedUnitsPerDose` is deliberately absent — read-only truth.
        try container.encodeIfPresent(daysOfWeek, forKey: .daysOfWeek)
        try container.encodeIfPresent(timesOfDay, forKey: .timesOfDay)
        try container.encodeIfPresent(rrule, forKey: .rrule)
        try container.encodeIfPresent(rollingIntervalDays, forKey: .rollingIntervalDays)
        try container.encodeIfPresent(reminderGraceMinutes, forKey: .reminderGraceMinutes)
        try container.encodeIfPresent(cyclicOnWeeks, forKey: .cyclicOnWeeks)
        try container.encodeIfPresent(cyclicOffWeeks, forKey: .cyclicOffWeeks)
        // Audit B-4 — the sentinel is dropped here rather than refused: this
        // encoder also writes the SWR cache blob, and a cached medication whose
        // schedule carried an unnameable tag must not fail the cache write. The
        // key simply goes missing, which is what it meant on the way in.
        try container.encodeIfPresent(scheduleType == .unknown ? nil : scheduleType, forKey: .scheduleType)
        try container.encodeIfPresent(doseWindows, forKey: .doseWindows)
    }
}

/// One explicit per-dose on-time intake window (server v1.15.18,
/// `doseWindowEntrySchema`). `timeOfDay` matches a schedule dose time;
/// `[start, end]` (HH:mm, user local, `start <= end` same-day) is the
/// on-time band. Outside it the cadence-derived late tail applies.
public struct MedicationDoseWindowDTO: Codable, Sendable, Hashable {
    /// The dose time this window applies to (`HH:mm`, matches a
    /// `timesOfDay` entry — server-validated).
    public let timeOfDay: String
    /// On-time band lower bound (`HH:mm`, user local).
    public let start: String
    /// On-time band upper bound (`HH:mm`, user local, `>= start`).
    public let end: String

    public init(timeOfDay: String, start: String, end: String) {
        self.timeOfDay = timeOfDay
        self.start = start
        self.end = end
    }
}

/// Mirror of `src/lib/medication-schedule.ts` `parseScheduleRecurrence`.
/// Decodes the server's serialised schedule string into weekday-set +
/// interval. Stable forward-compat: unknown patterns fall back to
/// `(daysOfWeek: [], intervalWeeks: 1)`.
public enum MedicationScheduleRecurrence {
    /// Result tuple — same field semantics as the server interface.
    public struct Parsed: Sendable, Equatable {
        public let daysOfWeek: [Int]
        public let intervalWeeks: Int
    }

    public static func parse(_ value: String?) -> Parsed {
        guard let raw = value, !raw.isEmpty else {
            return Parsed(daysOfWeek: [], intervalWeeks: 1)
        }
        // Encoded format: `iN;1,2,3` where N ∈ 1..4.
        if let encoded = parseEncoded(raw) {
            return encoded
        }
        // Legacy format: `1,2,3` — interval defaults to 1.
        let days = normalizeDays(raw.split(separator: ",").compactMap { Int($0) })
        return Parsed(daysOfWeek: days, intervalWeeks: 1)
    }

    private static func parseEncoded(_ raw: String) -> Parsed? {
        guard raw.hasPrefix("i"),
              let semicolonIndex = raw.firstIndex(of: ";") else { return nil }
        let intervalString = raw[raw.index(after: raw.startIndex) ..< semicolonIndex]
        guard let interval = Int(intervalString), (1 ... 4).contains(interval) else {
            return nil
        }
        let daysSubstring = raw[raw.index(after: semicolonIndex)...]
        let days = normalizeDays(daysSubstring.split(separator: ",").compactMap { Int($0) })
        return Parsed(daysOfWeek: days, intervalWeeks: interval)
    }

    private static func normalizeDays(_ days: [Int]) -> [Int] {
        Array(Set(days.filter { (0 ... 6).contains($0) })).sorted()
    }
}
