import Foundation

public extension IntakeStatus {
    var isReadOnlyTerminal: Bool {
        self == .missed
    }

    /// Status for mutation payloads; prevents read-only rows reaching network/outbox.
    ///
    /// The sentinel is refused here too. `__UNKNOWN__` is not a
    /// status any server or local column ever held; a client that sent it would
    /// be inventing one. One of the three intake write paths passes through
    /// here (`IntakeUpdate` to the API via `record(intake:)`); the other two
    /// are closed by their own exhaustive checks — `markIntakeRetroactively` rejects `.missed` and
    /// `.unknown` before building its patch, and `recordFromReminder` guards
    /// `status == .taken || status == .skipped`. A fifth write path needs one
    /// of those two shapes; nothing here is automatic for it.
    var writableRawValue: String {
        get throws {
            guard self != .unknown else {
                throw HLError.server(
                    status: 422,
                    code: "medications.intake.status_unknown",
                    message: "An intake status this build cannot name is never written back."
                )
            }
            guard !isReadOnlyTerminal else {
                throw HLError.server(
                    status: 422,
                    code: "medications.intake.status_read_only",
                    message: "A missed intake is read-only."
                )
            }
            return rawValue
        }
    }
}

/// Wire-body payloads for the medication CRUD + intake endpoints.
///
/// Extracted from `MedicationsRepository` so the actor body
/// stays under the type-body-length budget after the v1.5/v1.6/v1.7 field
/// growth. The nested-type names (`MedicationsRepository.MedicationCreate`,
/// `…MedicationPatch`, `…IntakeUpdate`, `…IntakePatch`) are unchanged, so the
/// outbox `Payloads.*` references + every call site keep compiling verbatim.
public extension MedicationsRepository {
    /// Wire-format payload for `POST /api/medications/intake`. Public for Outbox replay
    /// (Operation.payload encoded once at enqueue, decoded once at replay).
    struct IntakeUpdate: Codable, Sendable {
        public let intakeId: String
        public let status: String
        public let takenAt: Date
        /// **v1.8.5 — optional injection-site (server enum string).** Sent only
        /// on a TAKEN write for an injection medication with tracking on; the
        /// server silently drops it otherwise. Default-tolerant decode keeps
        /// older outbox payloads replayable.
        public let injectionSite: String?
        /// **#188 (8)** — the end of a snooze, sent only with `snoozed`. The
        /// server's own default is 30 minutes; the Watch's "Later" used to get
        /// that while the notification and the alarm snoozed for
        /// ``MedicationSnooze/interval``. Optional, so queued payloads from an
        /// older build still replay.
        public let snoozedUntil: Date?

        public init(
            intakeId: String,
            status: String,
            takenAt: Date,
            injectionSite: String? = nil,
            snoozedUntil: Date? = nil
        ) {
            self.intakeId = intakeId
            self.status = status
            self.takenAt = takenAt
            self.injectionSite = injectionSite
            self.snoozedUntil = snoozedUntil
        }
    }

    /// **Wire body for `POST /api/medications/{id}/intake`.** Mirrors the
    /// server's `MedicationIntakeRequest` schema (`medication.ts:795+`): an
    /// idempotent insert-or-return keyed on `(medication, scheduledFor)` that
    /// accepts the optional `doseTaken` actual-dose override (free text ≤50
    /// chars, persisted only on a taken write). `medicationId` is the path
    /// param, not a body field. All non-status fields are omitted when nil.
    struct MedicationIdIntakeBody: Codable, Sendable {
        public let scheduledFor: Date?
        public let takenAt: Date?
        public let skipped: Bool
        public let idempotencyKey: String?
        public let injectionSite: String?
        public let doseTaken: String?
        /// **v1.15.18 — optional late-take slot pin (`forceSlotInstant`).** When
        /// set, the take is pinned onto the named scheduled slot instead of
        /// orphaning to an ad-hoc row; the instant MUST be a real slot anchor of
        /// this medication on its day (server 422s an arbitrary instant). Absent
        /// (nil) → default window-band attribution — the common free-log case.
        /// Encoded via the synthesized `encodeIfPresent`, so nil is omitted from
        /// the wire (the server treats absent as "attribute by band").
        public let forceSlotInstant: Date?

        public init(
            scheduledFor: Date?,
            takenAt: Date?,
            skipped: Bool,
            idempotencyKey: String?,
            injectionSite: String? = nil,
            doseTaken: String? = nil,
            forceSlotInstant: Date? = nil
        ) {
            self.scheduledFor = scheduledFor
            self.takenAt = takenAt
            self.skipped = skipped
            self.idempotencyKey = idempotencyKey
            self.injectionSite = injectionSite
            self.doseTaken = doseTaken
            self.forceSlotInstant = forceSlotInstant
        }
    }

    /// Wire body for `POST /api/medications` — drug-definition create.
    /// Mirrors the server's create-schema (`route.ts:38-95`). All fields the
    /// UI exposes; server fills `userId`, `createdAt`, `id`. Stored on the
    /// outbox payload so an offline-created medication replays cleanly on
    /// next reachability without losing fields.
    struct MedicationCreate: Codable, Sendable {
        public let name: String
        public let dose: String
        public let treatmentClass: String?
        public let dosesPerUnit: Int?
        /// **v1.16.10/.12 `unitsPerDose`.** Inventory units one dose consumes
        /// (whole 1–100 or a curated split-pill fraction). Omitted (nil) →
        /// server default 1.
        public let unitsPerDose: Double?
        public let category: String?
        public let active: Bool?
        public let notificationsEnabled: Bool?
        public let schedules: [MedicationScheduleDTO]?

        // MARK: - Course-window + delivery fields (server v1.5/v1.6)

        /// Single-administration medication (`createMedicationSchema.oneShot`).
        public let oneShot: Bool?
        /// Course-window start (ISO `YYYY-MM-DD`).
        public let startsOn: String?
        /// Course-window end (ISO `YYYY-MM-DD`).
        public let endsOn: String?
        /// Route of administration (`ORAL | INJECTION | OTHER`).
        public let deliveryForm: String?

        // MARK: - v1.7.0 delivery booleans

        /// Per-medication Live-Activity gate. Omitted (nil) → server default.
        public let liveActivityEnabled: Bool?
        /// Per-medication AlarmKit critical-alarm gate. Omitted (nil) → default.
        public let criticalAlarmEnabled: Bool?

        // MARK: - v1.8.5 injection-site tracking

        /// Enable per-intake injection-site capture (default false server-side).
        public let trackInjectionSites: Bool?
        /// Per-medication preferred-site allow-list (server enum strings).
        /// `[]` clears the restriction (all eight allowed). Omitted (nil) →
        /// server keeps its value.
        public let allowedInjectionSites: [String]?

        // MARK: - v1.28 — Apple Health mirror + PRN + RxNorm

        /// **Marks the medication as MIRRORED from an external list.** Only
        /// `"APPLE_HEALTH"` is accepted. Must be sent together with
        /// ``externalId`` (both-or-neither). Idempotent per (user, source,
        /// concept): a re-post returns the existing med (200) instead of a
        /// duplicate. Omitted (nil) on app-managed creates → an unmarked med.
        public let externalSource: String?
        /// **Stable external identifier of the mirrored medication** — the
        /// HealthKit `medicationConceptIdentifier` (≤128). Both-or-neither with
        /// ``externalSource``.
        public let externalId: String?
        /// Optional RxNorm RxCUI (numeric string). Secondary coding; never a
        /// replacement for the free-text name. Omitted (nil) → untouched.
        public let rxNormCode: String?
        /// As-needed (PRN) medication. When true the medication carries NO
        /// schedules and is excluded from compliance. The Apple-mirror path
        /// sets this from `scheduleType == .asNeeded`.
        public let asNeeded: Bool?
        /// **v1.39.1 — intake tracking.** Omitted (nil) → the server
        /// default, tracked. The add sheet sends `false` only, and only against
        /// a server that knows the field.
        public let trackIntake: Bool?

        public init(
            name: String,
            dose: String,
            treatmentClass: String? = nil,
            dosesPerUnit: Int? = nil,
            unitsPerDose: Double? = nil,
            category: String? = nil,
            active: Bool? = true,
            notificationsEnabled: Bool? = nil,
            schedules: [MedicationScheduleDTO]? = nil,
            oneShot: Bool? = nil,
            startsOn: String? = nil,
            endsOn: String? = nil,
            deliveryForm: String? = nil,
            liveActivityEnabled: Bool? = nil,
            criticalAlarmEnabled: Bool? = nil,
            trackInjectionSites: Bool? = nil,
            allowedInjectionSites: [String]? = nil,
            externalSource: String? = nil,
            externalId: String? = nil,
            rxNormCode: String? = nil,
            asNeeded: Bool? = nil,
            trackIntake: Bool? = nil
        ) {
            self.name = name
            self.dose = dose
            self.treatmentClass = treatmentClass
            self.dosesPerUnit = dosesPerUnit
            self.unitsPerDose = unitsPerDose
            self.category = category
            self.active = active
            self.notificationsEnabled = notificationsEnabled
            self.schedules = schedules
            self.oneShot = oneShot
            self.startsOn = startsOn
            self.endsOn = endsOn
            self.deliveryForm = deliveryForm
            self.liveActivityEnabled = liveActivityEnabled
            self.criticalAlarmEnabled = criticalAlarmEnabled
            self.trackInjectionSites = trackInjectionSites
            self.allowedInjectionSites = allowedInjectionSites
            self.externalSource = externalSource
            self.externalId = externalId
            self.rxNormCode = rxNormCode
            self.asNeeded = asNeeded
            self.trackIntake = trackIntake
        }
    }

    /// Patch body for `PUT /api/medications/[id]`. All fields optional —
    /// server applies only the keys that are present. Supports archive
    /// (`active: false`), rename, dose change, schedule edit, and
    /// notification-toggle in a single endpoint.
    struct MedicationPatch: Codable, Sendable {
        public let name: String?
        public let dose: String?
        public let treatmentClass: String?
        public let dosesPerUnit: Int?
        /// **v1.16.10/.12 `unitsPerDose`.** Omitted (nil) → unchanged
        /// server-side (read-modify-write safe).
        public let unitsPerDose: Double?
        public let category: String?
        public let active: Bool?
        public let notificationsEnabled: Bool?
        public let schedules: [MedicationScheduleDTO]?

        // MARK: - Course-window + delivery fields (server v1.5/v1.6)

        /// Single-administration medication.
        public let oneShot: Bool?
        /// Course-window start (ISO `YYYY-MM-DD`).
        public let startsOn: String?
        /// Course-window end (ISO `YYYY-MM-DD`).
        public let endsOn: String?
        /// Route of administration (`ORAL | INJECTION | OTHER`).
        public let deliveryForm: String?

        // MARK: - v1.7.0 delivery booleans

        /// Per-medication Live-Activity gate. **PUT accepts only the two
        /// booleans** (`nextDueAt` is server-computed read-only). Omitted (nil)
        /// → unchanged server-side (read-modify-write safe).
        public let liveActivityEnabled: Bool?
        /// Per-medication AlarmKit critical-alarm gate. Same nil-omit semantics.
        public let criticalAlarmEnabled: Bool?

        // MARK: - v1.8.5 injection-site tracking

        /// Enable / disable per-intake injection-site capture. Omitted (nil) →
        /// unchanged server-side (RMW-safe).
        public let trackInjectionSites: Bool?
        /// Per-medication preferred-site allow-list (server enum strings). `[]`
        /// clears the per-med list; nil → unchanged.
        public let allowedInjectionSites: [String]?

        /// **As-needed (PRN) medication (v1.16.11, #316).** Omitted (nil) →
        /// unchanged server-side, like every other field here.
        ///
        /// **This field did not exist, and its absence was a bug with
        /// user impact.** Without it no edit could make a medication PRN or
        /// clear its plan, so "as needed" was reachable only at create time and
        /// even there it was written as a schedule-level key the server strips.
        ///
        /// It is paired with ``schedules`` and the pairing is enforced by the
        /// route in **both** directions: `asNeeded: true` alongside any schedule
        /// entry is a 422, and an empty `schedules` array without
        /// `asNeeded: true` is likewise a 422. Build the two together with
        /// ``MedicationCadenceLogic/scheduleWrite(value:times:graceMinutes:calendar:existingDoseWindows:slotUnitsPerDose:)``
        /// rather than by hand, so they cannot drift apart.
        public let asNeeded: Bool?

        /// **v1.39.1 — intake tracking.** Omitted (nil) → unchanged
        /// server-side. Named only when the person changed the switch, or to
        /// make a schedule edit on a medication kept as a record apply (the
        /// server drops `schedules`/`asNeeded`/`oneShot` on such a medication
        /// from a write that does not name it). Build the value with
        /// ``MedicationTrackIntakeWrite/value(server:edited:scheduleChanged:)``.
        public let trackIntake: Bool?

        /// **v1.42.2 — record doses automatically**. Omitted (nil) →
        /// unchanged server-side; named only when the person flipped the switch
        /// (``MedicationAutoMarkTakenFormValue/write``). Outside the initialiser
        /// so every caller stays as it was.
        public var autoMarkTaken: Bool?

        /// **#174 (server 1.47.6) — the medication's note**, at most 500
        /// characters after trimming. Omitted (nil) → unchanged; an empty
        /// string clears it. Named only when the person changed it
        /// (``MedicationNoteWrite``), as the web does.
        public var note: String?

        /// **Read-modify-write safety (R1 risk 5).** Every field is optional;
        /// the server applies only the keys present. When `schedules` is
        /// supplied it REPLACES the full schedule list server-side, so a
        /// caller editing only a non-schedule field (rename, dose, archive,
        /// delivery-toggle) MUST leave `schedules == nil` to avoid dropping a
        /// server-side `rrule` / `rollingIntervalDays` / `asNeeded` / the cyclic
        /// triple the user did not touch. Callers that DO rebuild `schedules`
        /// must read-modify-write from the medication's decoded `ScheduleEntry`
        /// rows (which carry rrule/rolling/asNeeded/cyclic) rather than rebuild
        /// from the flattened legacy triple.
        public init(
            name: String? = nil,
            dose: String? = nil,
            treatmentClass: String? = nil,
            dosesPerUnit: Int? = nil,
            unitsPerDose: Double? = nil,
            category: String? = nil,
            active: Bool? = nil,
            notificationsEnabled: Bool? = nil,
            schedules: [MedicationScheduleDTO]? = nil,
            oneShot: Bool? = nil,
            startsOn: String? = nil,
            endsOn: String? = nil,
            deliveryForm: String? = nil,
            liveActivityEnabled: Bool? = nil,
            criticalAlarmEnabled: Bool? = nil,
            trackInjectionSites: Bool? = nil,
            allowedInjectionSites: [String]? = nil,
            asNeeded: Bool? = nil,
            trackIntake: Bool? = nil
        ) {
            self.name = name
            self.dose = dose
            self.treatmentClass = treatmentClass
            self.dosesPerUnit = dosesPerUnit
            self.unitsPerDose = unitsPerDose
            self.category = category
            self.active = active
            self.notificationsEnabled = notificationsEnabled
            self.schedules = schedules
            self.oneShot = oneShot
            self.startsOn = startsOn
            self.endsOn = endsOn
            self.deliveryForm = deliveryForm
            self.liveActivityEnabled = liveActivityEnabled
            self.criticalAlarmEnabled = criticalAlarmEnabled
            self.trackInjectionSites = trackInjectionSites
            self.allowedInjectionSites = allowedInjectionSites
            self.asNeeded = asNeeded
            self.trackIntake = trackIntake
        }
    }

    /// Tri-state patch field for endpoints where "absent" and "explicit
    /// null" differ. The server's `updateIntakeEventSchema` keeps `takenAt`
    /// / `forceSlotInstant` `.nullable().optional()`: absent = leave
    /// untouched / run default attribution, explicit `null` = clear / unpin.
    enum PatchField<Value: Codable & Sendable & Equatable>: Sendable, Equatable {
        case absent
        case null
        case value(Value)
    }

    /// Patch body for `PUT /api/medications/[medicationId]/intake/[eventId]`.
    /// Lets the user correct a wrong `takenAt` retroactively, flip a
    /// historical intake between taken/skipped, or pin/unpin its slot
    /// attribution. Mirrors the server's `updateIntakeEventSchema`
    /// (v1.16.3): `{ takenAt?, skipped?, scheduledFor?, forceSlotInstant? }`.
    ///
    /// **Contract fix.** The pre-v0.14.8 shape
    /// sent `{status, takenAt}`; the server's Zod schema *strips* the
    /// unknown `status` key, so "mark as skipped" silently no-opped and a
    /// skipped→taken flip left `skipped: true` standing. The body now
    /// carries the real `skipped` boolean and an explicit-`null`-capable
    /// `takenAt` (a skip clears the administration instant). The legacy
    /// `status` string stays encoded for outbox-payload back-compat
    /// (decode + replay of pre-v0.14.8 rows) — the server ignores it.
    struct IntakePatch: Codable, Sendable, Equatable {
        public let status: String?
        public let skipped: Bool?
        public let takenAt: PatchField<Date>
        /// v1.15.18/v1.16.0 — slot-attribution override. `.value(slot)`
        /// pins the dose onto a named real slot (422 when the instant is
        /// not a slot of this medication, or the slot is already served);
        /// `.null` unpins ("Zuordnung lösen", re-attributes by band);
        /// `.absent` runs the default window-band attribution.
        public let forceSlotInstant: PatchField<Date>
        /// #169 (server 1.48.0) — the dose's injection site, as the server's
        /// enum string (``InjectionSite/serverRawValue``). `.value` sets it,
        /// `.null` clears it, `.absent` keeps it. A site the medication does
        /// not allow answers 422 `medications.intake.injection_site.disallowed`.
        public let injectionSite: PatchField<String>

        public init(
            status: String? = nil,
            takenAt: Date? = nil,
            skipped: Bool? = nil,
            takenAtField: PatchField<Date>? = nil,
            forceSlotInstant: PatchField<Date> = .absent,
            injectionSite: PatchField<String> = .absent
        ) {
            self.status = status
            self.skipped = skipped
            self.takenAt = takenAtField ?? takenAt.map { .value($0) } ?? .absent
            self.forceSlotInstant = forceSlotInstant
            self.injectionSite = injectionSite
        }

        enum CodingKeys: String, CodingKey {
            case status
            case skipped
            case takenAt
            case forceSlotInstant
            case injectionSite
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decodeIfPresent(String.self, forKey: .status)
            skipped = try container.decodeIfPresent(Bool.self, forKey: .skipped)
            takenAt = try Self.decodeField(container, key: .takenAt)
            forceSlotInstant = try Self.decodeField(container, key: .forceSlotInstant)
            injectionSite = try Self.decodeField(container, key: .injectionSite)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(status, forKey: .status)
            try container.encodeIfPresent(skipped, forKey: .skipped)
            try Self.encodeField(takenAt, into: &container, key: .takenAt)
            try Self.encodeField(forceSlotInstant, into: &container, key: .forceSlotInstant)
            try Self.encodeField(injectionSite, into: &container, key: .injectionSite)
        }

        private static func decodeField<Value: Codable & Sendable & Equatable>(
            _ container: KeyedDecodingContainer<CodingKeys>,
            key: CodingKeys
        ) throws -> PatchField<Value> {
            guard container.contains(key) else { return .absent }
            if try container.decodeNil(forKey: key) { return .null }
            return try .value(container.decode(Value.self, forKey: key))
        }

        private static func encodeField(
            _ field: PatchField<some Codable & Sendable & Equatable>,
            into container: inout KeyedEncodingContainer<CodingKeys>,
            key: CodingKeys
        ) throws {
            switch field {
            case .absent:
                break
            case .null:
                try container.encodeNil(forKey: key)
            case let .value(value):
                try container.encode(value, forKey: key)
            }
        }
    }
}

/// **#188 (8) — one snooze, everywhere.** The notification's "Remind me
/// later", the critical alarm's, the Watch's, the card's and the detail
/// page's defer a dose by the same span.
///
/// **#191 (final) — the account's snooze setting.** With
/// ``MedicationCapability/snoozeSetting`` the span is the account's
/// (`notificationPrefs.medication.snoozeMinutes`, an integer from 5 to 240,
/// default 30), kept in the App Group by every prefs load and every change.
/// Without it the server's own default applies, 30 minutes; the app's old
/// fixed 15 minutes are gone.
public enum MedicationSnooze {
    /// The server's default for the setting, also the span while it is
    /// unknown (#191).
    public static let serverDefaultMinutes = 30
    /// The span the setting may take (`5...240`); anything else reads as the
    /// default.
    public static let allowedMinutes = 5 ... 240
    /// The choices the reminder settings offer, all inside ``allowedMinutes``.
    public static let choices = [5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240]
    static let minutesDefaultsKey = "hl.medications.snoozeMinutes"

    public static var interval: TimeInterval {
        interval(defaults: MedicationCapabilities.appGroupDefaults)
    }

    public static var minutes: Int {
        minutes(defaults: MedicationCapabilities.appGroupDefaults)
    }

    public static func interval(defaults: UserDefaults?) -> TimeInterval {
        TimeInterval(minutes(defaults: defaults) * 60)
    }

    /// The account's span in minutes, or the server default.
    public static func minutes(defaults: UserDefaults?) -> Int {
        guard MedicationCapabilities.isOpen(.snoozeSetting, defaults: defaults) else { return serverDefaultMinutes }
        let stored = defaults?.object(forKey: minutesDefaultsKey) as? Int
        return stored.flatMap { allowedMinutes.contains($0) ? $0 : nil } ?? serverDefaultMinutes
    }

    /// Posted after the stored span changed, so the notification category
    /// can rename its action ("Remind me later (45 min)").
    public static let didChange = Notification.Name("hl.medications.snoozeMinutes.didChange")

    /// Keeps the account's span (or forgets it on `nil`).
    public static func record(serverMinutes: Int?, defaults: UserDefaults? = MedicationCapabilities.appGroupDefaults) {
        let before = defaults?.object(forKey: minutesDefaultsKey) as? Int
        if let serverMinutes {
            defaults?.set(serverMinutes, forKey: minutesDefaultsKey)
        } else {
            defaults?.removeObject(forKey: minutesDefaultsKey)
        }
        if before != serverMinutes { NotificationCenter.default.post(name: didChange, object: nil) }
    }

    /// Clamps a chosen span into ``allowedMinutes``.
    public static func clamped(_ minutes: Int) -> Int {
        min(allowedMinutes.upperBound, max(allowedMinutes.lowerBound, minutes))
    }

    /// "Remind me later (30 min)": the action's title wherever a dose can be
    /// snoozed (term list, #191).
    public static func actionTitle(minutes: Int = minutes) -> String {
        String(
            format: String(
                localized: "med.dose.action.snooze",
                defaultValue: "Remind me later (%lld min)",
                comment: "Snooze action on a medication dose; the span in minutes is the account's setting"
            ),
            minutes
        )
    }
}

/// **#191 — the undo precondition on `DELETE …/intake/{eventId}`.** The
/// version of the row the person saw: its `syncVersion` when the server sent
/// one, otherwise the idempotency key the app's own take went out under. The
/// server answers `409` ``changedSinceSeenCode`` when the row changed since.
/// Sent only behind ``MedicationCapability/undoPrecondition``.
public struct IntakeUndoPrecondition: Sendable, Equatable {
    public let syncVersion: Int?
    public let idempotencyKey: String?

    public static let changedSinceSeenCode = "medications.intake.changedSinceSeen"

    /// The server's longest `expectedIdempotencyKey`.
    static let maxKeyLength = 128

    /// `nil` when neither is known: an unconditional delete, as before.
    /// A value the server would refuse as `422
    /// medications.intake.invalidPrecondition` (a negative version, an empty
    /// key or one over 128 characters) is left out, never sent.
    public init?(syncVersion: Int?, idempotencyKey: String?) {
        let version = syncVersion.flatMap { $0 >= 0 ? $0 : nil }
        let key = idempotencyKey.flatMap { $0.isEmpty || $0.count > Self.maxKeyLength ? nil : $0 }
        guard version != nil || key != nil else { return nil }
        self.syncVersion = version
        self.idempotencyKey = key
    }

    /// `422 medications.intake.invalidPrecondition`: the app never sends a
    /// malformed precondition, but should a build ever do, the person reads a
    /// sentence instead of the raw code.
    public static let invalidPreconditionCode = "medications.intake.invalidPrecondition"

    public static func isInvalidPrecondition(_ error: Error) -> Bool {
        guard case let .server(status, code, _) = error as? HLError else { return false }
        return status == 422 && code == invalidPreconditionCode
    }

    public static var invalidPreconditionNotice: HLError {
        .server(
            status: 422,
            code: invalidPreconditionCode,
            message: String(
                localized: "med.undo.invalid_precondition",
                defaultValue: "This dose could not be undone. Reload the list and try again."
            )
        )
    }

    /// The query of the DELETE. Every precondition the app knows goes out,
    /// and the server deletes only when all of them match (#191, final).
    /// Empty while the capability is shut, so an older server sees the
    /// unchanged request.
    func queryItems(capabilities: UserDefaults?) -> [(String, String)] {
        guard MedicationCapabilities.isOpen(.undoPrecondition, defaults: capabilities) else { return [] }
        var items: [(String, String)] = []
        if let syncVersion { items.append(("expectedSyncVersion", String(syncVersion))) }
        if let idempotencyKey { items.append(("expectedIdempotencyKey", idempotencyKey)) }
        return items
    }

    /// Whether `error` is the server's "changed since you saw it" answer.
    public static func isChangedSinceSeen(_ error: Error) -> Bool {
        guard case let .server(status, code, _) = error as? HLError else { return false }
        return status == 409 && code == changedSinceSeenCode
    }

    /// What the person reads instead of the raw 409.
    public static var changedSinceSeenNotice: HLError {
        .server(
            status: 409,
            code: changedSinceSeenCode,
            message: String(
                localized: "med.undo.changed_since_seen",
                defaultValue: "This dose was changed on another device in the meantime, so nothing was undone."
            )
        )
    }
}

/// **#190 (final) — intake refusals in plain words.** Pinning a take onto a
/// slot that already holds one answers `422
/// medications.intake.force_slot.occupied`; the person reads a sentence
/// instead of the code. Every other error is returned as it came.
public enum IntakeWriteRefusal {
    public static let forceSlotOccupiedCode = "medications.intake.force_slot.occupied"

    /// 422 when the instant is no real slot of the medication that day.
    public static let forceSlotInvalidCode = "medications.intake.force_slot.invalid"

    public static func explained(_ error: HLError) -> HLError {
        guard case let .server(status, code, _) = error, status == 422 else { return error }
        switch code {
        case forceSlotOccupiedCode:
            return .server(
                status: 422,
                code: forceSlotOccupiedCode,
                message: String(
                    localized: "med.intake.force_slot_occupied",
                    defaultValue: "This dose already has an intake. Edit or delete that one first."
                )
            )
        case forceSlotInvalidCode:
            return .server(
                status: 422,
                code: forceSlotInvalidCode,
                message: String(
                    localized: "med.intake.force_slot_invalid",
                    defaultValue: "There is no dose at this time on that day. Save it as an extra dose."
                )
            )
        default:
            return error
        }
    }
}
