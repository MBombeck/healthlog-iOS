import Foundation

/// **W-REMINDERS (#23 v1.18.1) — a single Vorsorge reminder row.**
///
/// Decodes one `MeasurementReminderDTO` from the server's
/// `GET /api/measurement-reminders` list (OpenAPI `MeasurementReminderDTO`).
/// The reminder engine is the **single authority** for due dates: `nextDueAt`
/// / `lastSatisfiedAt` are server-computed and **render-only**. iOS must never
/// recompute them (no `Calendar`/date arithmetic on `nextDueAt`/`endsOn` —
/// format only). Reminders also AUTO-SATISFY server-side when a matching
/// reading / lab / wearable-sync posts, so iOS must NOT call `/satisfy` on a
/// measurement write — `satisfy` is the MANUAL "mark done" action only.
///
/// **Forward-compat:** `measurementType` stays a `String?` (NOT a closed enum)
/// — the server's `MeasurementReminderType` enum widened from 7→15 entries and
/// will widen again; mirroring the `APNsPayload.metricType: String?` precedent
/// means a future type the client doesn't know can't break the decode. `origin`
/// decodes defensively into ``MeasurementReminderRow/Origin`` with an
/// `.unknown` fallback so a new provenance value never drops the row.
public struct MeasurementReminderRow: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let label: String
    /// Auto-resolve target metric (`UPPER_SNAKE`, e.g. `WEIGHT`,
    /// `BLOOD_PRESSURE_SYS`). `nil` = free-text reminder (resolves only on a
    /// manual satisfy or a matching lab result). Kept as `String?` — never a
    /// closed enum — so the server enum widening can't break the build.
    public let measurementType: String?
    /// Rolling cadence in days, when the reminder uses an interval (mutually
    /// exclusive with `rrule` server-side). Render verbatim.
    public let intervalDays: Int?
    /// RFC-5545 recurrence rule, when the reminder uses a calendar schedule
    /// (mutually exclusive with `intervalDays`). Render verbatim.
    public let rrule: String?
    /// Server-stored cadence anchor (the instant the schedule counts off from).
    /// `nil` = the server anchors off `createdAt` / `lastSatisfiedAt`. The edit
    /// path can SET it (a chosen start date) or CLEAR it (`RecordPatchField`);
    /// it is never used in client-side due-date math — the server recomputes
    /// `nextDueAt` from it (`MeasurementReminderUpdate`).
    public let anchorDate: Date?
    /// ISO course-window end. `nil` = open-ended. Render verbatim ("ends DD.MM.");
    /// never used in due-date math.
    public let endsOn: Date?
    /// Provenance — user-created (`VORSORGE`) vs minted by a Coach cadence
    /// suggestion (`COACH`). Defensive decode (see ``Origin``).
    public let origin: Origin
    /// Local hour-of-day (0–23) the server cron fires the reminder. Render only.
    public let notifyHour: Int?
    /// Free-text location hint (e.g. a clinic name). Optional.
    public let location: String?
    /// Server-computed next-due timestamp. **Render-only — never recompute.**
    public let nextDueAt: Date?
    /// Server-computed last-satisfied timestamp. **Render-only.**
    public let lastSatisfiedAt: Date?
    /// **v1.37.20** — server-resolved snooze cursor: the instant the snoozed
    /// cycle comes due (the chosen calendar day resolved to `notifyHour` in the
    /// profile timezone; `nextDueAt` is set to the same instant). Snoozed means
    /// `snoozedUntil > now` — a clock comparison the server told clients to make,
    /// never a recomputed cadence. `nil` = not snoozed.
    public let snoozedUntil: Date?
    /// **v1.37.20** — instant of the most recent honest skip. A skipped cycle
    /// means `lastSkippedAt > lastSatisfiedAt`; a skip never moves
    /// `lastSatisfiedAt`, because a skip is not a completion. `nil` = never
    /// skipped.
    public let lastSkippedAt: Date?
    /// **v1.37.20** — how many cycles have been skipped in total. Published as a
    /// required integer, so a live row always carries it; a pre-v1.37.20 cache
    /// blob that predates the field reads `0`.
    public let skipCount: Int
    /// Whether the reminder is active. A disabled reminder still lists but the
    /// cron won't fire it.
    public let enabled: Bool

    /// Reminder provenance. Defensive: an unknown future `origin` string decodes
    /// to `.unknown` (the row still renders) instead of failing the whole list.
    public enum Origin: String, Sendable, Equatable {
        case vorsorge = "VORSORGE"
        case coach = "COACH"
        case unknown

        init(wire: String?) {
            guard let wire, let known = Origin(rawValue: wire) else {
                self = .unknown
                return
            }
            self = known
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, measurementType, intervalDays, rrule, anchorDate, endsOn, origin
        case notifyHour, location, nextDueAt, lastSatisfiedAt, enabled
        case snoozedUntil, lastSkippedAt, skipCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        measurementType = try c.decodeIfPresent(String.self, forKey: .measurementType)
        intervalDays = try c.decodeIfPresent(Int.self, forKey: .intervalDays)
        rrule = try c.decodeIfPresent(String.self, forKey: .rrule)
        anchorDate = try c.decodeIfPresent(Date.self, forKey: .anchorDate)
        endsOn = try c.decodeIfPresent(Date.self, forKey: .endsOn)
        origin = try Origin(wire: c.decodeIfPresent(String.self, forKey: .origin))
        notifyHour = try c.decodeIfPresent(Int.self, forKey: .notifyHour)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        nextDueAt = try c.decodeIfPresent(Date.self, forKey: .nextDueAt)
        lastSatisfiedAt = try c.decodeIfPresent(Date.self, forKey: .lastSatisfiedAt)
        // v1.37.20 — required and nullable on the wire. Decoded tolerantly all
        // the same: every SWR cache blob written before the field existed omits
        // the key entirely, and a stale cache must still read as a reminder.
        snoozedUntil = try c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        lastSkippedAt = try c.decodeIfPresent(Date.self, forKey: .lastSkippedAt)
        skipCount = try c.decodeIfPresent(Int.self, forKey: .skipCount) ?? 0
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    /// Encodes back to the wire shape — used only by the SWR cache round-trip
    /// (`JSONEncoder.hlDefault`), never sent to the server. `origin` re-emits as
    /// its raw `VORSORGE`/`COACH` string; an `.unknown` row re-emits `unknown`
    /// (it is never written to the server, only cached, so this is lossless for
    /// the cache's purposes).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encodeIfPresent(measurementType, forKey: .measurementType)
        try c.encodeIfPresent(intervalDays, forKey: .intervalDays)
        try c.encodeIfPresent(rrule, forKey: .rrule)
        try c.encodeIfPresent(anchorDate, forKey: .anchorDate)
        try c.encodeIfPresent(endsOn, forKey: .endsOn)
        try c.encode(origin.rawValue, forKey: .origin)
        try c.encodeIfPresent(notifyHour, forKey: .notifyHour)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encodeIfPresent(nextDueAt, forKey: .nextDueAt)
        try c.encodeIfPresent(lastSatisfiedAt, forKey: .lastSatisfiedAt)
        try c.encodeIfPresent(snoozedUntil, forKey: .snoozedUntil)
        try c.encodeIfPresent(lastSkippedAt, forKey: .lastSkippedAt)
        try c.encode(skipCount, forKey: .skipCount)
        try c.encode(enabled, forKey: .enabled)
    }

    /// Memberwise init for tests / previews (the wire path goes through
    /// `init(from:)`).
    public init(
        id: String,
        label: String,
        measurementType: String?,
        intervalDays: Int?,
        rrule: String?,
        endsOn: Date?,
        origin: Origin,
        notifyHour: Int?,
        location: String?,
        nextDueAt: Date?,
        lastSatisfiedAt: Date?,
        enabled: Bool,
        // Appended (not inserted) with a default so the existing labelled
        // call sites — tests, previews, the store's optimistic reconstruct —
        // keep compiling; Swift matches call arguments by declaration order.
        anchorDate: Date? = nil,
        // v1.37.20, appended for the same reason. A call site that omits them
        // builds a row that reads "never snoozed, never skipped" — which is why
        // a reconstruct of a live row must pass them through rather than rely on
        // the defaults.
        snoozedUntil: Date? = nil,
        lastSkippedAt: Date? = nil,
        skipCount: Int = 0
    ) {
        self.id = id
        self.label = label
        self.measurementType = measurementType
        self.intervalDays = intervalDays
        self.rrule = rrule
        self.anchorDate = anchorDate
        self.endsOn = endsOn
        self.origin = origin
        self.notifyHour = notifyHour
        self.location = location
        self.nextDueAt = nextDueAt
        self.lastSatisfiedAt = lastSatisfiedAt
        self.snoozedUntil = snoozedUntil
        self.lastSkippedAt = lastSkippedAt
        self.skipCount = skipCount
        self.enabled = enabled
    }

    /// **Build 6.4 — the edit-sheet's patch, as a pure function.**
    ///
    /// Builds the PATCH body for editing `row` with the form's current values,
    /// including the now-active cadence SWITCHING (Interval ↔ RRULE) and the
    /// explicit `anchorDate` clear. Kept a pure function (out of the `View`) so
    /// the exact omitted/null/set wire contract is testable — the trap that hid
    /// the original RRULE regression for months.
    ///
    /// **Cadence exclusivity + the #62 fix.** `intervalDays` and `rrule` are
    /// EXCLUSIVE server-side (`api/measurement-reminders/[id]/route.ts`): setting
    /// one while omitting the other clears the other, and — since server v1.32.1
    /// (#62) — the recompute keys off `Object.hasOwn(updateData, …)` so a cleared
    /// cadence can no longer leak the stale one into `nextDueAt`. So:
    ///   - **Interval mode** → `intervalDays = .set(n)`, `rrule = .unchanged`
    ///     (omitted). The server clears `rrule` via the exclusivity rule.
    ///   - **RRULE mode** → `rrule = .set(rule)`, `intervalDays = .unchanged`
    ///     (omitted). The server clears `intervalDays`. Sending the rule
    ///     explicitly (the form can now edit it) is what carries a switch onto,
    ///     or an edit of, a calendar schedule.
    ///
    /// Omitting the untouched cadence is a `RecordPatchField.unchanged` — dropped
    /// from the wire — which is the `undefined` the server reads as "don't touch".
    /// The clearable text fields (`measurementType`, `anchorDate`, `location`)
    /// tri-state: a value → `.set`, an emptied field that HAD a value → `.clear`
    /// (explicit JSON `null`), an empty field that never had one → `.unchanged`.
    static func editingPatch(
        for row: MeasurementReminderRow,
        label: String,
        measurementType: String?,
        cadence: ReminderCadence,
        anchorDate: Date?,
        notifyHour: Int,
        location: String?,
        enabled: Bool
    ) -> MeasurementReminderUpdate {
        let intervalField: RecordPatchField<Int>
        let rruleField: RecordPatchField<String>
        switch cadence {
        case let .interval(days):
            intervalField = .set(days)
            rruleField = .unchanged
        case let .rrule(rule):
            rruleField = .set(rule)
            intervalField = .unchanged
        }

        return MeasurementReminderUpdate(
            label: label,
            measurementType: Self.clearableField(new: measurementType, had: row.measurementType != nil),
            intervalDays: intervalField,
            rrule: rruleField,
            anchorDate: Self.clearableDate(new: anchorDate, had: row.anchorDate != nil),
            notifyHour: notifyHour,
            location: Self.clearableField(
                new: location?.trimmingCharacters(in: .whitespacesAndNewlines),
                had: row.location != nil
            ),
            enabled: enabled
        )
    }

    /// Tri-state a clearable string field: a non-empty value → `.set`; an
    /// empty/`nil` value that HAD a stored value → `.clear`; otherwise omit.
    private static func clearableField(new value: String?, had: Bool) -> RecordPatchField<String> {
        if let value, !value.isEmpty { return .set(value) }
        return had ? .clear : .unchanged
    }

    /// Tri-state a clearable date field (the `anchorDate` null-out path).
    private static func clearableDate(new value: Date?, had: Bool) -> RecordPatchField<Date> {
        if let value { return .set(value) }
        return had ? .clear : .unchanged
    }

    /// `true` when this reminder is driven by an RFC-5545 `rrule` rather than a
    /// rolling interval. An empty string counts as "no rule" — the server treats
    /// the two cadences as exclusive, so a blank `rrule` means the row is on the
    /// interval path.
    var isRRuleScheduled: Bool {
        rrule?.isEmpty == false
    }
}

// MARK: - Completion ledger (v1.37.20)

/// The ledger types a reminder's history page is made of, reachable from the
/// reminder they belong to. Both are defined in `MeasurementReminderHistory.swift`
/// — the row file names them so the reminder and its ledger are one vocabulary.
public extension MeasurementReminderRow {
    /// One row of this reminder's completion ledger
    /// (`GET /api/measurement-reminders/{id}/history`).
    typealias Event = MeasurementReminderEvent
    /// One page of this reminder's completion ledger, newest first.
    typealias HistoryPage = MeasurementReminderHistoryPage
}

// MARK: - Cadence input

/// The form's chosen cadence for an edit/create. Exactly one of the two server
/// cadence families — a rolling `intervalDays` or an RFC-5545 `rrule` — so the
/// exclusivity is expressed in the type rather than reconstructed downstream.
public enum ReminderCadence: Equatable, Sendable {
    case interval(Int)
    case rrule(String)
}

// MARK: - Create / Update bodies

/// `POST /api/measurement-reminders` body (OpenAPI `MeasurementReminderCreate`).
/// Exactly one of `intervalDays` (rolling) or `rrule` (RFC-5545) is required;
/// `measurementType` enables server-side auto-resolve (omit for free-text).
/// `anchorDate` optionally pins the schedule's start instant; `location` is a
/// free-text hint; `enabled` (default `true` server-side) can create a reminder
/// switched off. All optionals drop from the wire when `nil` (Swift's synthesised
/// `Encodable` omits `nil`), which the server reads as "use the default".
public struct MeasurementReminderCreate: Encodable, Sendable {
    public let label: String
    public let measurementType: String?
    public let intervalDays: Int?
    public let rrule: String?
    public let anchorDate: Date?
    public let notifyHour: Int?
    public let location: String?
    public let enabled: Bool?

    public init(
        label: String,
        measurementType: String? = nil,
        intervalDays: Int? = nil,
        rrule: String? = nil,
        anchorDate: Date? = nil,
        notifyHour: Int? = nil,
        location: String? = nil,
        enabled: Bool? = nil
    ) {
        self.label = label
        self.measurementType = measurementType
        self.intervalDays = intervalDays
        self.rrule = rrule
        self.anchorDate = anchorDate
        self.notifyHour = notifyHour
        self.location = location
        self.enabled = enabled
    }

    /// Convenience: build the create body from a `ReminderCadence` so the sheet
    /// never hand-picks between `intervalDays` / `rrule` (exclusivity by type).
    public init(
        label: String,
        measurementType: String?,
        cadence: ReminderCadence,
        anchorDate: Date?,
        notifyHour: Int,
        location: String?,
        enabled: Bool
    ) {
        let trimmedLocation = location?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch cadence {
        case let .interval(days):
            self.init(
                label: label,
                measurementType: measurementType,
                intervalDays: days,
                rrule: nil,
                anchorDate: anchorDate,
                notifyHour: notifyHour,
                location: (trimmedLocation?.isEmpty == false) ? trimmedLocation : nil,
                enabled: enabled
            )
        case let .rrule(rule):
            self.init(
                label: label,
                measurementType: measurementType,
                intervalDays: nil,
                rrule: rule,
                anchorDate: anchorDate,
                notifyHour: notifyHour,
                location: (trimmedLocation?.isEmpty == false) ? trimmedLocation : nil,
                enabled: enabled
            )
        }
    }
}

/// `PATCH /api/measurement-reminders/{id}` body (OpenAPI
/// `MeasurementReminderUpdate`). Partial — omitted fields are left untouched
/// server-side, `nextDueAt` is recomputed after the cadence merge.
///
/// **Build 6.4 — tri-state clearable fields.** The cadence pair
/// (`intervalDays`/`rrule`), the `anchorDate`, the `location`, and the
/// `measurementType` each carry a ``RecordPatchField`` so the three wire states
/// stay distinct: OMIT the key (untouched), send `null` (clear), or send a value
/// (set). A plain optional cannot express "clear" — it collapses `nil` to
/// "omit" — which is why cadence switching (clear one, set the other) and the
/// explicit `anchorDate` null-out need the primitive. `label`, `notifyHour`, and
/// `enabled` are never cleared, so they stay plain optionals (`encodeIfPresent`).
public struct MeasurementReminderUpdate: Encodable, Sendable, Equatable {
    public let label: String?
    public let measurementType: RecordPatchField<String>
    public let intervalDays: RecordPatchField<Int>
    public let rrule: RecordPatchField<String>
    public let anchorDate: RecordPatchField<Date>
    public let notifyHour: Int?
    public let location: RecordPatchField<String>
    public let enabled: Bool?

    public init(
        label: String? = nil,
        measurementType: RecordPatchField<String> = .unchanged,
        intervalDays: RecordPatchField<Int> = .unchanged,
        rrule: RecordPatchField<String> = .unchanged,
        anchorDate: RecordPatchField<Date> = .unchanged,
        notifyHour: Int? = nil,
        location: RecordPatchField<String> = .unchanged,
        enabled: Bool? = nil
    ) {
        self.label = label
        self.measurementType = measurementType
        self.intervalDays = intervalDays
        self.rrule = rrule
        self.anchorDate = anchorDate
        self.notifyHour = notifyHour
        self.location = location
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case label, measurementType, intervalDays, rrule, anchorDate, notifyHour, location, enabled
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(label, forKey: .label)
        try measurementType.encode(into: &c, forKey: .measurementType)
        try intervalDays.encode(into: &c, forKey: .intervalDays)
        try rrule.encode(into: &c, forKey: .rrule)
        try anchorDate.encode(into: &c, forKey: .anchorDate)
        try c.encodeIfPresent(notifyHour, forKey: .notifyHour)
        try location.encode(into: &c, forKey: .location)
        try c.encodeIfPresent(enabled, forKey: .enabled)
    }
}

// MARK: - Complete envelope (v1.18.6, #32)

/// `POST /api/measurement-reminders/{id}/complete` response payload (OpenAPI
/// `MeasurementReminderCompletion`).
///
/// The explicit user-action twin of `satisfy`: it marks a Vorsorge reminder
/// done server-side (stamps `lastSatisfiedAt = now`, re-anchors `nextDueAt`,
/// fires NO notification) instead of the old local-only deep-link dismiss.
/// **Idempotent:** completing an already-satisfied / auto-resolved reminder
/// returns `completed = false` (no-op) with the canonical post-completion
/// `reminder`. Render the `reminder` row verbatim — never recompute the dates.
public struct MeasurementReminderCompletion: Decodable, Sendable, Equatable {
    /// `true` when this call advanced `lastSatisfiedAt`; `false` on the
    /// idempotent no-op (a prior satisfy / matching reading already fulfilled
    /// the current cycle).
    public let completed: Bool
    /// Canonical post-completion reminder row (re-anchored `nextDueAt`).
    public let reminder: MeasurementReminderRow

    public init(completed: Bool, reminder: MeasurementReminderRow) {
        self.completed = completed
        self.reminder = reminder
    }
}

// MARK: - Skip envelope (v1.37.20)

/// `POST /api/measurement-reminders/{id}/skip` response payload (OpenAPI
/// `MeasurementReminderSkip`).
///
/// An honest skip of the current due cycle: the interval restarts from the skip
/// instant, `lastSkippedAt` is stamped, `skipCount` increments, any snooze is
/// cleared, and a `SKIPPED` row lands in the completion ledger.
/// **`lastSatisfiedAt` is never touched** — a skip is not a completion.
///
/// **Idempotent:** `skipped = false` is a real forward-only no-op (a concurrent
/// skip or satisfy already advanced the row), not an error, and the canonical
/// post-skip `reminder` still comes back. That is the same shape `complete`
/// has, which is why this type mirrors ``MeasurementReminderCompletion`` —
/// and why the *snooze* response deliberately does not.
public struct MeasurementReminderSkip: Decodable, Sendable, Equatable {
    /// `true` when this call recorded the skip; `false` on the idempotent no-op.
    public let skipped: Bool
    /// Canonical post-skip reminder row. Render it verbatim.
    public let reminder: MeasurementReminderRow

    public init(skipped: Bool, reminder: MeasurementReminderRow) {
        self.skipped = skipped
        self.reminder = reminder
    }
}

// MARK: - Snooze (v1.37.20)

/// `POST /api/measurement-reminders/{id}/snooze` request body (OpenAPI
/// `MeasurementReminderSnooze`), whose single required field is a **calendar
/// day**, not an instant.
///
/// The published schema is `format: date` with a `YYYY-MM-DD` pattern, so the
/// field is a `String`: encoding a `Date` through `JSONEncoder.hlDefault` would
/// emit a full ISO-8601 timestamp and violate the pattern. The server resolves
/// the day to the reminder's `notifyHour` in the profile timezone — which is
/// exactly why the client sends a day and not a moment.
///
/// Bounds are the server's: at least tomorrow, at most five years out, `422`
/// otherwise. They are documented rather than enforced here; a client-side
/// rejection would be inventing a refusal the contract gives to the server.
public struct MeasurementReminderSnooze: Encodable, Sendable, Equatable {
    /// `YYYY-MM-DD` in the owner's calendar.
    public let until: String

    public init(until day: String) {
        until = day
    }

    /// Builds the body from a picked day. `timeZone` is the zone the *user* read
    /// the calendar in, so the day sent is the day they tapped.
    public init(day: Date, in timeZone: TimeZone) {
        until = Self.day(day, in: timeZone)
    }

    /// `YYYY-MM-DD` for `date` in `timeZone`. POSIX locale + Gregorian calendar
    /// so the format is stable regardless of the device's regional settings.
    /// The formatter is built per call (Swift 6 concurrency: a shared mutable
    /// `DateFormatter` is not `Sendable`).
    public static func day(_ date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// `POST /api/measurement-reminders/{id}/snooze` response payload — the inline
/// `data` object of the OpenAPI `MeasurementReminderSnoozeEnvelope`.
///
/// **Deliberately asymmetric with skip:** it carries the reminder alone, with no
/// applied/no-op flag (repeated snoozes simply let the last one win). Sharing one
/// decode type with ``MeasurementReminderSkip`` would be wrong on both routes.
public struct MeasurementReminderSnoozeResult: Decodable, Sendable, Equatable {
    /// Canonical post-snooze reminder row: `snoozedUntil` and `nextDueAt` are the
    /// same resolved instant, and the regular cadence is untouched.
    public let reminder: MeasurementReminderRow

    public init(reminder: MeasurementReminderRow) {
        self.reminder = reminder
    }
}
