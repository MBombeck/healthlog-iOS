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
    /// v1.40: the label of a custom category (`category` = `custom:<uuid>`).
    public var categoryLabel: String?
    public let active: Bool?
    public let notificationsEnabled: Bool?
    /// v1.42.2 `remindersActive` / `autoMarkTaken`, folded in `toDomain()`.
    public var remindersActive: Bool?, autoMarkTaken: Bool?
    /// #1280 (v1.46.0) `endedAt` / `canEndCourse`, v1.40 `canStartCourse`, v1.42.2
    /// `autoMarkTakenSince`. Read through `Medication+CourseActions.swift`.
    public var endedAt: Date?, canEndCourse: Bool?, canStartCourse: Bool?, autoMarkTakenSince: Date?
    /// #141 (v1.43) `related`, single-medication reads only. See `MedicationsRepository+Related.swift`.
    public var related: RelatedLinks?
    /// #131 (v1.43) composition; `ingredients` on single reads only. See `Medication+Ingredients.swift`.
    public var ingredients: MedicationIngredients?, hasIngredients: Bool?
    /// MED-PLUS (v1.40) course summary. See `Medication+Courses.swift`.
    public var courseCount: Int?, previousCourseEndedOn: String?
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
    /// **`trackIntake` (v1.39.1, #1033) — intake tracking.** `false` keeps the
    /// medication as a record: dose, dates and schedule stay stored, but nothing
    /// is ever due, nothing reminds on any channel and no adherence figure
    /// exists. The server then serves `schedules: []` and the stored schedule in
    /// ``recordedSchedules``. Optional because a server older than v1.39.1 does
    /// not send it; absent reads as `true`, the column default.
    public let trackIntake: Bool?
    /// **`recordedSchedules` (v1.39.1)** — present only when ``trackIntake`` is
    /// `false`: the stored schedule, kept as information. Nothing derives a due
    /// dose or a reminder from it.
    public let recordedSchedules: [MedicationScheduleDTO]?
    /// v1.39.4 — see ``MedicationCourseStatus`` and ``Medication/isIntakeActionable``.
    public let courseStatus: MedicationCourseStatus?
    public let intakeActionable: Bool?
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
        trackIntake: Bool? = nil,
        recordedSchedules: [MedicationScheduleDTO]? = nil,
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
        externalId: String? = nil,
        courseStatus: MedicationCourseStatus? = nil,
        intakeActionable: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.dose = dose
        self.treatmentClass = treatmentClass
        self.dosesPerUnit = dosesPerUnit
        self.unitsPerDose = unitsPerDose
        self.category = category
        self.courseStatus = courseStatus
        self.intakeActionable = intakeActionable
        self.active = active
        self.notificationsEnabled = notificationsEnabled
        self.schedules = schedules
        self.lastTakenAt = lastTakenAt
        self.todayEventCount = todayEventCount
        self.stockDosesRemaining = stockDosesRemaining
        self.runwayDays = runwayDays
        self.oneShot = oneShot
        self.asNeeded = asNeeded
        self.trackIntake = trackIntake
        self.recordedSchedules = recordedSchedules
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
    /// v1.40: server label of a custom category; `nil` for a built-in one.
    public var categoryLabel: String?
    public var remindersActive: Bool?
    /// MED (1.5.0): the server's course-action fields, verbatim (`nil` from a
    /// server or cache blob that predates them). See `Medication+CourseActions.swift`.
    public var endedAt: Date?, canEndCourse: Bool?, canStartCourse: Bool?, autoMarkTakenSince: Date?
    /// RELATED (1.5.0, #141): records related to this one; `nil` on list rows.
    public var related: RelatedLinks?
    /// SUPP (1.5.0, #131): composition per unit; see `Medication+Ingredients.swift`.
    public var ingredients: MedicationIngredients?, hasIngredients: Bool?
    /// MED-PLUS (1.5.0): the server's `autoMarkTaken` verbatim and the course summary
    /// (v1.40); `nil` from an older server or a 1.4.1 cache blob. See `Medication+AutoMarkTaken.swift`.
    public var autoMarkTaken: Bool?, courseCount: Int?, previousCourseEndedOn: String?
    public let dosesPerUnit: Int?
    /// **v1.16.10/.12 `unitsPerDose`.** Inventory units one dose consumes
    /// (whole 1–100 or a curated split-pill fraction). `nil` → 1.0. See
    /// ``effectiveUnitsPerDose``.
    public let unitsPerDose: Double?
    public internal(set) var schedule: MedicationSchedule
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
    public internal(set) var endsOn: Date?
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
    /// **v1.39.1 (#1033) — the server's `trackIntake`, verbatim.** `nil` when
    /// the server predates the field (or a cache blob does), which means
    /// tracked. Read it through ``tracksIntake``.
    public let trackIntake: Bool?
    /// **v1.39.1 — the stored schedule of a medication kept as a record**
    /// (`recordedSchedules`). Information only: ``schedule`` stays empty for
    /// such a medication, so nothing that plans a reminder or a due dose ever
    /// sees these entries. `nil` for a tracked medication.
    public let recordedSchedule: MedicationSchedule?
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
    public internal(set) var externalSource: String?
    /// The HK `medicationConceptIdentifier` the mirror keys on (present only
    /// alongside ``externalSource``).
    public internal(set) var externalId: String?

    // MARK: - v1.37.19 slot-aware supply truth (#25)

    /// Server-computed whole doses the usable stock still covers, slot-aware.
    /// See ``MedicationWireDTO/stockDosesRemaining`` — `nil` (tracking off /
    /// unknown) and `0` (tracked and exhausted) are different answers.
    public let stockDosesRemaining: Int?
    /// Server-computed projected days of supply, from the same slot-aware burn
    /// rate the low-stock notification engine uses. See
    /// ``MedicationWireDTO/runwayDays`` — `nil` is not `0`.
    public let runwayDays: Int?

    /// v1.39.4 (#1040) — the server's `courseStatus` / `intakeActionable`,
    /// verbatim (`nil` from an older server). Read through ``isIntakeActionable``.
    public internal(set) var courseStatus: MedicationCourseStatus?
    public internal(set) var intakeActionable: Bool?

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
        trackIntake: Bool? = nil,
        recordedSchedule: MedicationSchedule? = nil,
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
        runwayDays: Int? = nil,
        courseStatus: MedicationCourseStatus? = nil,
        intakeActionable: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.dose = dose
        self.treatmentClass = treatmentClass
        self.category = category
        self.courseStatus = courseStatus
        self.intakeActionable = intakeActionable
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
        self.trackIntake = trackIntake
        self.recordedSchedule = recordedSchedule
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

// The medication compliance payload types (`ComplianceDay`, `MedicationCompliancePayload`,
// `ComplianceWindowResult`, `DailyComplianceBucket`) live in `MedicationCompliance.swift`
// (extracted v0.10 W-Meds-A2 for the length budget + the v1.7.0 SB-SCHED-2 `due` additions).

// MARK: - Where new server fields go (MED, 1.5.0)

// This file holds the stored shape only. A new server field is one `var` line
// in `MedicationWireDTO` and, if the UI reads it, one in `Medication` (both
// optional, so a 1.4.1 cache blob and an older server still decode). Its
// adoption goes into `toDomain()` in `Medication+Decoding.swift`, its reading
// logic into a `Medication+<Topic>.swift` extension. Copies keep every `var`
// field because they start from `var copy = self` (`replacingSchedule`,
// `withAppleHealthProvenance`, `endingCourse`). The GLP-1 detail stack keeps
// its own SwiftData entities (`Screens/GLP1/GLP1LocalEntities.swift`).
