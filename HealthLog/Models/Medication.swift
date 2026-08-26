import Foundation

/// Server-True wire shape für `GET /api/medications` (siehe
/// `src/app/api/medications/route.ts:83-95` + `03-api-contracts §Medications`).
/// Felder, die der Server seit v1.4.x liefert: `treatmentClass`, `dosesPerUnit`,
/// `category`, `notificationsEnabled`, `lastTakenAt`, `todayEventCount`, sowie
/// das Schedule-**Array** `schedules` mit `windowStart`/`windowEnd` (HH:mm),
/// `daysOfWeek` (0-6, 0=Sonntag), optionalem `label`/`dose`.
public struct MedicationWireDTO: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let dose: String
    public let treatmentClass: String?
    public let dosesPerUnit: Int?
    /// **v1.16.10/.12 `unitsPerDose`.** Inventory units one dose consumes —
    /// a whole number 1–100 (two 2 mg tablets = one 4 mg dose) OR a curated
    /// split-pill fraction (¼ ⅓ ½ ⅔ ¾). Distinct from `dosesPerUnit` (which
    /// is units-in-a-container metadata). The supply runway divides remaining
    /// units by this factor. `nil` against ≤v1.16.9 payloads → treated as 1.0.
    public let unitsPerDose: Double?
    public let category: String?
    public let active: Bool?
    public let notificationsEnabled: Bool?
    public let schedules: [MedicationScheduleDTO]?
    public let lastTakenAt: Date?
    public let todayEventCount: Int?

    // MARK: - v1.37.19 slot-aware supply truth (#25)

    /// **`stockDosesRemaining` (`integer | null`, required since v1.37.19).**
    /// Whole doses the usable stock still covers. Slot-aware: the divisor is the
    /// schedule-weighted average of each slot's `resolvedUnitsPerDose`, not a
    /// single medication-level factor.
    ///
    /// `nil` and `0` are different answers and must stay different. `nil` =
    /// inventory tracking is off (no container was ever registered) → the honest
    /// display is "—". `0` = tracking is on and the supply ran out → the display
    /// is a real zero. An absent key (a pre-v1.37.19 self-hosted server, or a
    /// stale cache blob) also decodes to `nil`, which is the same "we do not
    /// know" and never a fabricated zero.
    public let stockDosesRemaining: Int?
    /// **`runwayDays` (`integer | null`, required since v1.37.19).** Projected
    /// whole days the usable stock covers under the same slot-aware burn rate
    /// the low-stock notification engine runs — which is the point: the wire and
    /// the push cannot disagree, and neither can a client-side re-derivation
    /// because there is not supposed to be one.
    ///
    /// `nil` = tracking off, or no consuming cadence is derivable (PRN,
    /// one-shot). `0` = tracked and exhausted. Same nil-versus-zero rule as
    /// ``stockDosesRemaining``.
    public let runwayDays: Int?

    // MARK: - v1.5 / v1.6 medication-level fields (R1 §3.1)

    /// Single-administration medication. Auto-deactivates server-side after
    /// the first non-skipped intake (`createMedicationSchema.oneShot`).
    public let oneShot: Bool?
    /// **`asNeeded` (v1.16.11, #316) — the MEDICATION-level PRN flag.**
    /// Published **required** on `MedicationListEntry`, `MedicationDetail` and
    /// `Medication`. When true the medication carries ZERO schedules: it is
    /// never due, never reminded and excluded from every compliance
    /// rate/streak, while intakes still log ad-hoc and inventory still
    /// consumes. Mutually exclusive with ``oneShot``.
    ///
    /// **09-14 — iOS read PRN at the wrong level.** It decoded a schedule-level
    /// `asNeeded` the output schema does not publish and ignored this one, which
    /// it does. A correctly-created PRN medication therefore arrived with an
    /// empty `schedules` array and no flag anywhere, and the edit sheet
    /// re-selected it as a plain daily plan. Optional here only so a pre-v1.16.11
    /// self-hosted server and a legacy cache blob still decode; absent reads as
    /// false, which is the schema default.
    public let asNeeded: Bool?
    /// Course-window start (ISO `YYYY-MM-DD`). Anchors RRULE / rolling and
    /// floors every cadence. `nil` = active from creation.
    public let startsOn: String?
    /// Course-window end (ISO `YYYY-MM-DD`). `nil` = chronic.
    public let endsOn: String?
    /// Route of administration (`ORAL | INJECTION | OTHER`).
    public let deliveryForm: String?
    /// Timestamp the medication was paused (`active` flipped to false).
    public let pausedAt: Date?
    /// Snooze-until instant set from a banner action.
    public let snoozedUntil: Date?
    /// Server row creation timestamp — the final rolling/legacy anchor
    /// fallback when neither `lastTakenAt` nor `startsOn` is set
    /// (`lastIntakeAt ?? startsOn ?? createdAt` per the canonical engine).
    public let createdAt: Date?

    // MARK: - v1.7.0 medication-contract additions (W-Meds-A2)

    /// **SB-SCHED-3 `nextDueAt` (LOCKED, read-only, ISO8601).** Server-computed
    /// next scheduled instant. When present + non-null it is the AUTHORITATIVE
    /// next reminder time for the Spezi / AlarmKit / Live-Activity scheduling
    /// consumers (prefer over the local engine's `nextOccurrence`, removing the
    /// two-engine parity risk). `null` for PRN and against the current server →
    /// the local engine is the fallback. The client NEVER sends this on PUT.
    public let nextDueAt: String?
    /// **v1.16.4 `nextDueOverdue` (additive, default false).** `true` when
    /// `nextDueAt` is an OPEN overdue slot: its anchor has passed, `now` is
    /// still inside the slot's catch-up band, and no taken/skipped/auto-missed
    /// row resolves it — the dose is overdue-but-takeable and `nextDueAt`
    /// carries THAT (past) instant instead of jumping to the next future
    /// slot. `false` for a regular future next-due (and when `nextDueAt` is
    /// null). Optional / nil against servers ≤v1.16.3 (GH issue #15).
    public let nextDueOverdue: Bool?
    /// **SB-LA-1 `liveActivityEnabled` (LOCKED, default false).** Per-medication
    /// Lock-Screen / Dynamic-Island dose countdown gate. Optional / nil against
    /// the current server.
    public let liveActivityEnabled: Bool?
    /// **SB-AK-1 `criticalAlarmEnabled` (LOCKED, default false).** Per-medication
    /// AlarmKit break-through alarm gate. Optional / nil against the current
    /// server.
    public let criticalAlarmEnabled: Bool?

    // MARK: - v1.8.5 injection-site tracking (server-to-ios contract)

    /// **`trackInjectionSites` (default false).** When `true` AND
    /// `deliveryForm == "INJECTION"`, intake-writes may carry an
    /// `injectionSite` that the server persists. Default-tolerant: an older
    /// server omits it → decodes as `nil` (treated as `false`).
    public let trackInjectionSites: Bool?
    /// **`allowedInjectionSites` (default []).** Per-medication preferred-site
    /// allow-list (server enum strings). Empty / absent = no restriction (all
    /// eight). The effective set the picker offers is this minus the
    /// user-level global deny-list.
    public let allowedInjectionSites: [String]?

    // MARK: - v1.28 (GH #47) — Apple Health mirror provenance

    /// **`externalSource` (v1.28, additive).** `"APPLE_HEALTH"` when the med is
    /// mirrored from the iOS 26+ HealthKit Medications list; `nil` for
    /// app-managed meds. **Since server v1.32.25 `GET /api/medications` echoes
    /// this**, which is what makes the mirrored-vs-native distinction
    /// server-true instead of guessed from the local mirror registry (CU-10).
    /// Still decode-tolerant / optional — an older server omits it, and the
    /// importer's client-side provenance stamp remains the backstop.
    public let externalSource: String?
    /// **`externalId` (v1.28, additive).** The HK `medicationConceptIdentifier`
    /// the mirror keys on. Present only alongside ``externalSource``.
    public let externalId: String?

    public init(
        id: String,
        name: String,
        dose: String,
        treatmentClass: String? = nil,
        dosesPerUnit: Int? = nil,
        unitsPerDose: Double? = nil,
        category: String? = nil,
        active: Bool? = true,
        notificationsEnabled: Bool? = nil,
        schedules: [MedicationScheduleDTO]? = nil,
        lastTakenAt: Date? = nil,
        todayEventCount: Int? = nil,
        stockDosesRemaining: Int? = nil,
        runwayDays: Int? = nil,
        oneShot: Bool? = nil,
        asNeeded: Bool? = nil,
        startsOn: String? = nil,
        endsOn: String? = nil,
        deliveryForm: String? = nil,
        pausedAt: Date? = nil,
        snoozedUntil: Date? = nil,
        createdAt: Date? = nil,
        nextDueAt: String? = nil,
        nextDueOverdue: Bool? = nil,
        liveActivityEnabled: Bool? = nil,
        criticalAlarmEnabled: Bool? = nil,
        trackInjectionSites: Bool? = nil,
        allowedInjectionSites: [String]? = nil,
        externalSource: String? = nil,
        externalId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.dose = dose
        self.treatmentClass = treatmentClass
        self.dosesPerUnit = dosesPerUnit
        self.unitsPerDose = unitsPerDose
        self.category = category
        self.active = active
        self.notificationsEnabled = notificationsEnabled
        self.schedules = schedules
        self.lastTakenAt = lastTakenAt
        self.todayEventCount = todayEventCount
        self.stockDosesRemaining = stockDosesRemaining
        self.runwayDays = runwayDays
        self.oneShot = oneShot
        self.asNeeded = asNeeded
        self.startsOn = startsOn
        self.endsOn = endsOn
        self.deliveryForm = deliveryForm
        self.pausedAt = pausedAt
        self.snoozedUntil = snoozedUntil
        self.createdAt = createdAt
        self.nextDueAt = nextDueAt
        self.nextDueOverdue = nextDueOverdue
        self.liveActivityEnabled = liveActivityEnabled
        self.criticalAlarmEnabled = criticalAlarmEnabled
        self.trackInjectionSites = trackInjectionSites
        self.allowedInjectionSites = allowedInjectionSites
        self.externalSource = externalSource
        self.externalId = externalId
    }
}

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
        try container.encodeIfPresent(scheduleType, forKey: .scheduleType)
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

/// Domain-Type, den die UI konsumiert. Wird aus `MedicationWireDTO` gebaut —
/// behält das vorher genutzte `schedule.times`/`schedule.weekdays`-Surface,
/// damit die bestehenden Screens (MedicationsScreen, ActiveMedicationsSection)
/// weiter unverändert rendern. Server-`schedules`-Array wird dabei in eine
/// flache `times`-Liste reduziert (Window-Start als Reminder-Zeit).
public struct Medication: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let dose: String
    public let treatmentClass: String?
    public let category: String?
    public let dosesPerUnit: Int?
    /// **v1.16.10/.12 `unitsPerDose`.** Inventory units one dose consumes
    /// (whole 1–100 or a curated split-pill fraction). `nil` → 1.0. See
    /// ``effectiveUnitsPerDose``.
    public let unitsPerDose: Double?
    public let schedule: MedicationSchedule
    public let lastTakenAt: Date?
    public let todayEventCount: Int?
    public let notificationsEnabled: Bool
    public let active: Bool

    // MARK: - T-3 CRUD additions

    /// Client-side timestamp captured when the user archived the medication
    /// (`active: false` via swipe-action). The server's wire schema does NOT
    /// carry an `archivedAt` column — archive is "just" `active = false`.
    /// We stamp this locally at archive-time so the "Archived" filter row
    /// can render `vor 3 Tagen` without a separate server roundtrip. On
    /// list-refresh (server is source-of-truth) the field decodes as nil
    /// for rows the server returns; the store re-applies the last known
    /// optimistic timestamp on top of the refresh (see `MedicationsStore`
    /// `archive(id:)`). Codable-optional → forward/backward compat with
    /// any cached SWR payload predating this field.
    public let archivedAt: Date?

    /// **Build 6.2 — server pause timestamp.** Stamped server-side the moment
    /// `active` flips to `false` (`PUT /api/medications/[id]` derives it) and
    /// cleared when it flips back to `true`. Surfaced in the edit sheet as
    /// "Pausiert seit …" so a temporarily-suspended medication reads as paused
    /// rather than silently archived. Codable-optional → forward/backward compat
    /// with cached SWR payloads predating this field, and nil for an active med.
    public let pausedAt: Date?

    // MARK: - v1.5 course window + delivery (R1 §3.1)

    /// Course-window start as a midnight-anchored `Date` (decoded from the
    /// wire `YYYY-MM-DD`). Anchors RRULE / rolling and floors every cadence.
    public let startsOn: Date?
    /// Course-window end as a midnight-anchored `Date`. `nil` = chronic.
    public let endsOn: Date?
    /// Single-administration medication. The engine surfaces it once and the
    /// server auto-deactivates after the first non-skipped intake.
    public let oneShot: Bool
    /// **As-needed (PRN) medication.** True ⇒ the medication carries zero
    /// schedules and is never due, never reminded and never scored; intakes
    /// still log ad-hoc. See ``MedicationWireDTO/asNeeded``.
    ///
    /// This is the only thing that distinguishes a PRN medication from one whose
    /// plan simply has not been set up yet — both arrive with `schedules: []` —
    /// which is why the edit form reads it before it looks at the entries.
    public let asNeeded: Bool
    /// Route of administration (`ORAL | INJECTION | OTHER`); `nil` when the
    /// server omits it.
    public let deliveryForm: String?
    /// Server row creation timestamp — the rolling/legacy anchor fallback.
    public let createdAt: Date?

    // MARK: - v1.7.0 medication-contract additions (W-Meds-A2)

    /// **SB-SCHED-3 — server-computed next reminder instant** (decoded from the
    /// wire ISO8601 `nextDueAt`). When non-nil it overrides the local engine's
    /// `nextOccurrence` for the Spezi / AlarmKit / Live-Activity consumers. Nil
    /// for PRN + against the current server (engine fallback).
    public let nextDueAt: Date?
    /// **v1.16.4 — server `nextDueOverdue` flag** (additive, GH issue #15).
    /// `true` → ``nextDueAt`` is an OPEN overdue slot (anchor passed, catch-up
    /// band still open, unresolved): the dose is overdue-but-takeable and the
    /// instant may legitimately lie in the PAST. Codable-optional so cached
    /// SWR payloads predating the field keep decoding; prefer the
    /// ``hasOpenOverdueDose`` accessor for render logic.
    public let nextDueOverdue: Bool?
    /// **SB-LA-1 — per-medication Live-Activity gate** (default false). Nil when
    /// the server omits the field; the scheduling consumer only arms a Live
    /// Activity when this resolves true.
    public let liveActivityEnabled: Bool?
    /// **SB-AK-1 — per-medication critical-alarm gate** (default false). Nil
    /// when the server omits the field; the AlarmKit consumer only arms a
    /// critical alarm when this resolves true.
    public let criticalAlarmEnabled: Bool?

    // MARK: - v1.8.5 injection-site tracking

    /// Whether injection-site capture is active for this medication (default
    /// false). Only meaningful when ``isInjection`` is true.
    public let trackInjectionSites: Bool
    /// Per-medication preferred-site allow-list as **local** ``InjectionSite``
    /// cases (decoded from the server enum strings). Empty = no restriction
    /// (all eight). Combined with the user deny-list to form the effective set.
    public let allowedInjectionSites: [InjectionSite]

    // MARK: - v1.28 (GH #47) — Apple Health mirror provenance

    /// `"APPLE_HEALTH"` when this med is a read-only mirror of an iOS 26+
    /// HealthKit medication; `nil` for app-managed meds. Drives the
    /// source-exclusive policy (``isAppleHealthMirrored`` /
    /// ``allowsManualDoseLogging``).
    public let externalSource: String?
    /// The HK `medicationConceptIdentifier` the mirror keys on (present only
    /// alongside ``externalSource``).
    public let externalId: String?

    // MARK: - v1.37.19 slot-aware supply truth (#25)

    /// Server-computed whole doses the usable stock still covers, slot-aware.
    /// See ``MedicationWireDTO/stockDosesRemaining`` — `nil` (tracking off /
    /// unknown) and `0` (tracked and exhausted) are different answers.
    public let stockDosesRemaining: Int?
    /// Server-computed projected days of supply, from the same slot-aware burn
    /// rate the low-stock notification engine uses. See
    /// ``MedicationWireDTO/runwayDays`` — `nil` is not `0`.
    public let runwayDays: Int?

    public init(
        id: String,
        name: String,
        dose: String,
        treatmentClass: String? = nil,
        category: String? = nil,
        dosesPerUnit: Int? = nil,
        unitsPerDose: Double? = nil,
        schedule: MedicationSchedule,
        lastTakenAt: Date? = nil,
        todayEventCount: Int? = nil,
        notificationsEnabled: Bool = true,
        active: Bool = true,
        archivedAt: Date? = nil,
        startsOn: Date? = nil,
        endsOn: Date? = nil,
        oneShot: Bool = false,
        asNeeded: Bool = false,
        deliveryForm: String? = nil,
        createdAt: Date? = nil,
        nextDueAt: Date? = nil,
        nextDueOverdue: Bool? = nil,
        liveActivityEnabled: Bool? = nil,
        criticalAlarmEnabled: Bool? = nil,
        trackInjectionSites: Bool = false,
        allowedInjectionSites: [InjectionSite] = [],
        externalSource: String? = nil,
        externalId: String? = nil,
        pausedAt: Date? = nil,
        stockDosesRemaining: Int? = nil,
        runwayDays: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.dose = dose
        self.treatmentClass = treatmentClass
        self.category = category
        self.dosesPerUnit = dosesPerUnit
        self.unitsPerDose = unitsPerDose
        self.schedule = schedule
        self.lastTakenAt = lastTakenAt
        self.todayEventCount = todayEventCount
        self.notificationsEnabled = notificationsEnabled
        self.active = active
        self.archivedAt = archivedAt
        self.startsOn = startsOn
        self.endsOn = endsOn
        self.oneShot = oneShot
        self.asNeeded = asNeeded
        self.deliveryForm = deliveryForm
        self.createdAt = createdAt
        self.nextDueAt = nextDueAt
        self.nextDueOverdue = nextDueOverdue
        self.liveActivityEnabled = liveActivityEnabled
        self.criticalAlarmEnabled = criticalAlarmEnabled
        self.trackInjectionSites = trackInjectionSites
        self.allowedInjectionSites = allowedInjectionSites
        self.externalSource = externalSource
        self.externalId = externalId
        self.pausedAt = pausedAt
        self.stockDosesRemaining = stockDosesRemaining
        self.runwayDays = runwayDays
    }

    // MARK: - v1.8.5 injection-site convenience

    /// `true` when this medication's route is `INJECTION` (case-insensitive).
    /// The site-picker + tracking toggle are gated on this.
    ///
    /// **W47 (Trulicity):** a GLP-1-class medication is injectable by
    /// definition (subcutaneous pen), yet the server does not always stamp
    /// `deliveryForm = "INJECTION"` for it — the `treatmentClass = "GLP1"`
    /// already implies the route. Treating GLP-1 as an injection here keeps
    /// the capture gate consistent with the catalog-recognition path that
    /// already mounts the body-map on the detail screen.
    public var isInjection: Bool {
        deliveryForm?.uppercased() == "INJECTION" || treatmentClass?.uppercased() == "GLP1"
    }

    /// **v1.16.4 (GH issue #15)** — `true` when the server flagged
    /// ``nextDueAt`` as an OPEN overdue slot that is still takeable.
    /// Requires both the flag AND a non-nil instant so a malformed payload
    /// (`nextDueOverdue: true` with `nextDueAt: null`) never claims overdue.
    ///
    /// **Composition with the b162 dose-safety rule** (`1e9cb915` — a
    /// `.taken` intake with `scheduledAt > now` never renders taken): the
    /// open overdue slot is by definition `<= now`, so presenting it as
    /// takeable can never collide with the future-dose guard. Overdue-open
    /// = takeable; future = not pre-markable.
    public var hasOpenOverdueDose: Bool {
        (nextDueOverdue ?? false) && nextDueAt != nil
    }

    /// `true` when the picker should be offered on a TAKEN write: injection
    /// route AND tracking enabled. Mirrors the server's persist-gate.
    ///
    /// **W47 (Trulicity):** the GLP-1 detail body-map renders unconditionally,
    /// so the take-sheet must capture a site too — otherwise a logged shot
    /// drops it and the history stays empty. A GLP-1 is capture-eligible by
    /// default; the explicit `trackInjectionSites` toggle still gates the
    /// non-GLP-1 injectables (insulin / B12 / methotrexate).
    public var injectionSiteCaptureEnabled: Bool {
        guard isInjection else { return false }
        return treatmentClass?.uppercased() == "GLP1" || trackInjectionSites
    }

    /// **v1.16.10/.12.** Units one dose consumes, defaulting to 1.0 when the
    /// server omits the field (≤v1.16.9) or sends a non-positive value. The
    /// supply runway divides remaining units by this.
    public var effectiveUnitsPerDose: Double {
        guard let unitsPerDose, unitsPerDose > 0 else { return 1.0 }
        return unitsPerDose
    }
}

public struct TimeOfDay: Codable, Sendable, Hashable, Comparable {
    public let hour: Int
    public let minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = max(0, min(23, hour))
        self.minute = max(0, min(59, minute))
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.hour != rhs.hour { return lhs.hour < rhs.hour }
        return lhs.minute < rhs.minute
    }

    /// Parses a server-side `HH:mm` window string. Returns `nil` on malformed input.
    public static func parse(_ raw: String) -> TimeOfDay? {
        let parts = raw.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0 ... 23).contains(hour),
              (0 ... 59).contains(minute) else
        {
            return nil
        }
        return TimeOfDay(hour: hour, minute: minute)
    }
}

public enum Weekday: Int, Codable, Sendable, CaseIterable, Hashable {
    /// Sunday = 0 to match the server's `daysOfWeek` convention.
    case sun = 0, mon, tue, wed, thu, fri, sat
}

public extension MedicationWireDTO {
    /// Build the domain-shape consumed by the UI. **v0.10 R1:** decodes every
    /// server schedule row non-lossily into a ``ScheduleEntry`` (cadence +
    /// times-of-day + grace), applying the server dispatch precedence
    /// (one-shot → rolling → rrule → legacy), and threads the medication-level
    /// course window (`startsOn`/`endsOn`/`oneShot`/`deliveryForm`). The legacy
    /// flattened `times`/`weekdays`/`intervalWeeks` surface is derived from the
    /// entries for the pre-v0.10 render paths.
    func toDomain() -> Medication {
        let isOneShot = oneShot ?? false
        let entries = (schedules ?? []).map { ScheduleEntry.fromDTO($0, oneShot: isOneShot) }
        let schedule: MedicationSchedule = entries.isEmpty
            ? MedicationSchedule(times: [])
            : MedicationSchedule(entries: entries)

        return Medication(
            id: id,
            name: name,
            dose: dose,
            treatmentClass: treatmentClass,
            category: category,
            dosesPerUnit: dosesPerUnit,
            unitsPerDose: unitsPerDose,
            schedule: schedule,
            lastTakenAt: lastTakenAt,
            todayEventCount: todayEventCount,
            notificationsEnabled: notificationsEnabled ?? true,
            active: active ?? true,
            startsOn: Self.parseCourseDate(startsOn),
            endsOn: Self.parseCourseDate(endsOn),
            oneShot: isOneShot,
            asNeeded: asNeeded ?? false,
            deliveryForm: deliveryForm,
            createdAt: createdAt,
            nextDueAt: Self.parseNextDueAt(nextDueAt),
            nextDueOverdue: nextDueOverdue,
            liveActivityEnabled: liveActivityEnabled,
            criticalAlarmEnabled: criticalAlarmEnabled,
            trackInjectionSites: trackInjectionSites ?? false,
            allowedInjectionSites: (allowedInjectionSites ?? []).compactMap(InjectionSite.parse),
            externalSource: externalSource,
            externalId: externalId,
            pausedAt: pausedAt,
            // Propagated verbatim: nil stays nil, 0 stays 0, and nothing here
            // substitutes a derived figure for an absent one.
            stockDosesRemaining: stockDosesRemaining,
            runwayDays: runwayDays
        )
    }

    /// Parse the wire `nextDueAt` ISO8601 timestamp (a full instant, not a
    /// `@db.Date` day boundary) into a `Date`. Accepts fractional + plain
    /// ISO8601. Returns `nil` for absent / malformed values (engine fallback).
    static func parseNextDueAt(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let date = ISO8601DateFormatter.fractional.date(from: raw) {
            return date
        }
        return ISO8601DateFormatter.plain.date(from: raw)
    }

    /// Parse a wire `YYYY-MM-DD` course-window date into a UTC-midnight
    /// `Date`. The engine interprets these as day boundaries, so a fixed UTC
    /// midnight anchor matches the server's `@db.Date` semantics. Returns
    /// `nil` for absent / malformed values.
    static func parseCourseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        // Accept both the bare `YYYY-MM-DD` and a full ISO-8601 timestamp
        // (the server may emit either depending on the serializer).
        if let date = ISO8601DateFormatter.plain.date(from: raw) {
            return date
        }
        let parts = raw.prefix(10).split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else
        {
            return nil
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(from: components)
    }
}

public struct MedicationIntake: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let medicationId: String
    public let scheduledAt: Date
    public let takenAt: Date?
    public let status: IntakeStatus
    public let snoozedUntil: Date?

    public init(
        id: String,
        medicationId: String,
        scheduledAt: Date,
        takenAt: Date? = nil,
        status: IntakeStatus,
        snoozedUntil: Date? = nil
    ) {
        self.id = id
        self.medicationId = medicationId
        self.scheduledAt = scheduledAt
        self.takenAt = takenAt
        self.status = status
        self.snoozedUntil = snoozedUntil
    }
}

/// Wire envelope of `POST /api/medications/intake` (raw Prisma row).
/// Server source: `src/app/api/medications/intake/route.ts:204` —
/// `apiSuccess(updated)` where `updated` is the bare `MedicationIntakeEvent`
/// (no synthesised status, field name `scheduledFor` not `scheduledAt`).
///
/// Pre-v0.4.0 the iOS POST decoded into `MedicationIntake` directly →
/// `keyNotFound("scheduledAt")` after the write succeeded. Optimistic
/// store updates were masked by the fake error (A4-Audit row 4).
///
/// The GET `?scope=today` (route lines 94-108) **does** synthesize
/// `scheduledAt` + `status`, so the today-list decodes cleanly via
/// `MedicationIntake` directly; this wire wrapper is only for the POST
/// reply path.
public struct MedicationIntakeWireDTO: Codable, Sendable {
    public let id: String
    public let medicationId: String
    public let scheduledFor: Date
    public let takenAt: Date?
    public let skipped: Bool
    public let snoozedUntil: Date?

    public init(
        id: String,
        medicationId: String,
        scheduledFor: Date,
        takenAt: Date? = nil,
        skipped: Bool = false,
        snoozedUntil: Date? = nil
    ) {
        self.id = id
        self.medicationId = medicationId
        self.scheduledFor = scheduledFor
        self.takenAt = takenAt
        self.skipped = skipped
        self.snoozedUntil = snoozedUntil
    }

    /// Derive `status` from the Prisma flags the same way the GET endpoint
    /// synthesises it server-side (route lines 99-106): skipped → skipped,
    /// takenAt non-null → taken, snoozedUntil in future → snoozed, else
    /// pending. The snoozedUntil sits on the parent `Medication` row in
    /// the schema; for POST responses we only have the column on the
    /// intake event so we approximate.
    public func toDomain(now: Date = .now) -> MedicationIntake {
        let status: IntakeStatus = if skipped {
            .skipped
        } else if takenAt != nil {
            .taken
        } else if let snooze = snoozedUntil, snooze > now {
            .snoozed
        } else {
            .pending
        }
        return MedicationIntake(
            id: id,
            medicationId: medicationId,
            scheduledAt: scheduledFor,
            takenAt: takenAt,
            status: status,
            snoozedUntil: snoozedUntil
        )
    }
}

/// Server intake status. Today's ledger also returns terminal `missed`; write
/// routes accept only user dispositions, so read states fail closed on writes.
/// Keeping the read value prevents one terminal row from atomically dropping
/// a valid pending sibling during `[MedicationIntake]` decoding.
public enum IntakeStatus: String, Codable, Sendable {
    case pending
    case taken
    case skipped
    case snoozed
    case missed
}

// The medication compliance payload types (`ComplianceDay`,
// `MedicationCompliancePayload`, `ComplianceWindowResult`,
// `DailyComplianceBucket`) live in `MedicationCompliance.swift` (extracted
// v0.10 W-Meds-A2 to keep this file under the length budget + to host the
// v1.7.0 SB-SCHED-2 `due`/`expectedCount` additions).

// MARK: - T-5 GLP-1 fields

//
// Reserved coordination marker for the T-5 GLP-1 Detail Stack. The T-5
// architectural decision (see `.planning/v05x-marathon/PB-T5-report.md`)
// is **Option C** — four separate SwiftData entities under
// `HealthLog/Screens/GLP1/GLP1LocalEntities.swift` keyed by
// `medication.id`. No fields are added to `Medication` itself because
// the model is a Codable struct shared with the server wire-shape;
// adding fields would force a wire-DTO change without server support.
//
// When server-sync for the four GLP-1 sub-features lands (future
// SB-T5-* items in `SERVER-BACKLOG.md`), the iOS side will mirror the
// new wire-fields into `MedicationWireDTO` + `Medication` here under
// the same `// MARK: - T-5 GLP-1 fields` heading.
//
// Coordination with T-3: this marker sits **after** the T-3 archive
// fields (when they land). Both T-3 and T-5 are APPEND-ONLY to this
// model file.
