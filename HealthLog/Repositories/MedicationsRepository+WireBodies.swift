import Foundation

public extension IntakeStatus {
    var isReadOnlyTerminal: Bool {
        self == .missed
    }

    /// Status for mutation payloads; prevents read-only rows reaching network/outbox.
    var writableRawValue: String {
        get throws {
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
/// Extracted from `MedicationsRepository` (v0.10 W-Meds-A2) so the actor body
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

        public init(intakeId: String, status: String, takenAt: Date, injectionSite: String? = nil) {
            self.intakeId = intakeId
            self.status = status
            self.takenAt = takenAt
            self.injectionSite = injectionSite
        }
    }

    /// **H6 — wire body for `POST /api/medications/{id}/intake`.** Mirrors the
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

        // MARK: - v0.10 R1 §3.8 — v1.5/v1.6 course-window + delivery fields

        /// Single-administration medication (`createMedicationSchema.oneShot`).
        public let oneShot: Bool?
        /// Course-window start (ISO `YYYY-MM-DD`).
        public let startsOn: String?
        /// Course-window end (ISO `YYYY-MM-DD`).
        public let endsOn: String?
        /// Route of administration (`ORAL | INJECTION | OTHER`).
        public let deliveryForm: String?

        // MARK: - v1.7.0 delivery booleans (W-Meds-A2, SB-LA-1 / SB-AK-1)

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

        // MARK: - v1.28 (GH #47) — Apple Health mirror + PRN + RxNorm

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
            asNeeded: Bool? = nil
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

        // MARK: - v0.10 R1 §3.8 — v1.5/v1.6 course-window + delivery fields

        /// Single-administration medication.
        public let oneShot: Bool?
        /// Course-window start (ISO `YYYY-MM-DD`).
        public let startsOn: String?
        /// Course-window end (ISO `YYYY-MM-DD`).
        public let endsOn: String?
        /// Route of administration (`ORAL | INJECTION | OTHER`).
        public let deliveryForm: String?

        // MARK: - v1.7.0 delivery booleans (W-Meds-A2, SB-LA-1 / SB-AK-1)

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
        /// **09-14 — this field did not exist, and its absence was a bug with
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
            asNeeded: Bool? = nil
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
    /// **W3-MEDCONTRACT (v0.14.8) — contract fix.** The pre-v0.14.8 shape
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

        public init(
            status: String? = nil,
            takenAt: Date? = nil,
            skipped: Bool? = nil,
            takenAtField: PatchField<Date>? = nil,
            forceSlotInstant: PatchField<Date> = .absent
        ) {
            self.status = status
            self.skipped = skipped
            self.takenAt = takenAtField ?? takenAt.map { .value($0) } ?? .absent
            self.forceSlotInstant = forceSlotInstant
        }

        enum CodingKeys: String, CodingKey {
            case status
            case skipped
            case takenAt
            case forceSlotInstant
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decodeIfPresent(String.self, forKey: .status)
            skipped = try container.decodeIfPresent(Bool.self, forKey: .skipped)
            takenAt = try Self.decodeField(container, key: .takenAt)
            forceSlotInstant = try Self.decodeField(container, key: .forceSlotInstant)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(status, forKey: .status)
            try container.encodeIfPresent(skipped, forKey: .skipped)
            try Self.encodeField(takenAt, into: &container, key: .takenAt)
            try Self.encodeField(forceSlotInstant, into: &container, key: .forceSlotInstant)
        }

        private static func decodeField(
            _ container: KeyedDecodingContainer<CodingKeys>,
            key: CodingKeys
        ) throws -> PatchField<Date> {
            guard container.contains(key) else { return .absent }
            if try container.decodeNil(forKey: key) { return .null }
            return try .value(container.decode(Date.self, forKey: key))
        }

        private static func encodeField(
            _ field: PatchField<Date>,
            into container: inout KeyedEncodingContainer<CodingKeys>,
            key: CodingKeys
        ) throws {
            switch field {
            case .absent:
                break
            case .null:
                try container.encodeNil(forKey: key)
            case let .value(date):
                try container.encode(date, forKey: key)
            }
        }
    }
}
