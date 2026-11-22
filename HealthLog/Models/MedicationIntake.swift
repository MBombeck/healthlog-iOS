import Foundation

public struct MedicationIntake: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let medicationId: String
    public let scheduledAt: Date
    public let takenAt: Date?
    public let status: IntakeStatus
    /// Server 1.49.0 (#191): applies to this slot only, the one the snooze
    /// holds, no longer to every slot of the medication.
    public let snoozedUntil: Date?
    /// **#191 — who recorded the take** (`WEB`, `APP`, `INTEGRATION`,
    /// `TELEGRAM`, `APPLE_HEALTH`, `IMPORT`, `AUTO`; ``MedicationTakenVia``);
    /// `nil` unless taken, and on older servers.
    public let takenVia: String?
    /// The row's sync version, when the server sends it. An undo sends it back
    /// as `expectedSyncVersion` (#191), so it never removes a take someone
    /// else recorded since.
    public let syncVersion: Int?
    /// The row's idempotency key, when the server sends it; the alternative
    /// undo precondition (`expectedIdempotencyKey`).
    public let idempotencyKey: String?
    /// **#188 (4), #191 — the server's resolved dose state** (`state` and
    /// its companions). `nil` on an older server; read only behind
    /// ``MedicationCapability/doseState``.
    public let doseState: ServerDoseState?

    public init(
        id: String,
        medicationId: String,
        scheduledAt: Date,
        takenAt: Date? = nil,
        status: IntakeStatus,
        snoozedUntil: Date? = nil,
        takenVia: String? = nil,
        syncVersion: Int? = nil,
        idempotencyKey: String? = nil,
        doseState: ServerDoseState? = nil
    ) {
        self.id = id
        self.medicationId = medicationId
        self.scheduledAt = scheduledAt
        self.takenAt = takenAt
        self.status = status
        self.snoozedUntil = snoozedUntil
        self.takenVia = takenVia
        self.syncVersion = syncVersion
        self.idempotencyKey = idempotencyKey
        self.doseState = doseState
    }

    private enum CodingKeys: String, CodingKey {
        case id, medicationId, scheduledAt, takenAt, status, snoozedUntil
        case takenVia, syncVersion, idempotencyKey, doseState
        case state, takenLate, dueAt, overdueSince, slotInstant, missedAfter
    }

    /// Tolerant for everything 1.49.0 adds: a missing or mistyped new field is
    /// `nil` and never costs the row. The resolved dose state comes flat on
    /// the row (`state`, `takenLate`, `dueAt`, `overdueSince`, `slotInstant`;
    /// #191, final) and is kept nested under `doseState` by the offline cache.
    /// `status` keeps its own meaning and is never read as the dose state.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        medicationId = try c.decode(String.self, forKey: .medicationId)
        scheduledAt = try c.decode(Date.self, forKey: .scheduledAt)
        takenAt = try c.decodeIfPresent(Date.self, forKey: .takenAt)
        status = try c.decode(IntakeStatus.self, forKey: .status)
        snoozedUntil = try c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        takenVia = try? c.decodeIfPresent(String.self, forKey: .takenVia)
        syncVersion = try? c.decodeIfPresent(Int.self, forKey: .syncVersion)
        idempotencyKey = try? c.decodeIfPresent(String.self, forKey: .idempotencyKey)
        if let state = try? c.decodeIfPresent(String.self, forKey: .state) {
            doseState = ServerDoseState(
                state: state,
                takenLate: (try? c.decodeIfPresent(Bool.self, forKey: .takenLate)) == true,
                dueAt: try? c.decodeIfPresent(Date.self, forKey: .dueAt),
                overdueSince: try? c.decodeIfPresent(Date.self, forKey: .overdueSince),
                slotInstant: try? c.decodeIfPresent(Date.self, forKey: .slotInstant),
                missedAfter: try? c.decodeIfPresent(Date.self, forKey: .missedAfter)
            )
        } else {
            doseState = try? c.decodeIfPresent(ServerDoseState.self, forKey: .doseState)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(medicationId, forKey: .medicationId)
        try c.encode(scheduledAt, forKey: .scheduledAt)
        try c.encodeIfPresent(takenAt, forKey: .takenAt)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(snoozedUntil, forKey: .snoozedUntil)
        try c.encodeIfPresent(takenVia, forKey: .takenVia)
        try c.encodeIfPresent(syncVersion, forKey: .syncVersion)
        try c.encodeIfPresent(idempotencyKey, forKey: .idempotencyKey)
        try c.encodeIfPresent(doseState, forKey: .doseState)
    }
}

/// **#188 (4), #191 — the dose state the server resolves per slot.** With
/// it the app reads the server's thresholds through `state` and never grades
/// "overdue" with fixed thresholds of its own.
public struct ServerDoseState: Codable, Sendable, Hashable {
    /// `upcoming`, `due`, `overdue`, `taken`, `skipped`, `missed`, or a word
    /// this build does not know (then nothing is derived from it).
    public let state: String
    /// Only meaningful for `taken`.
    public let takenLate: Bool
    /// The start of the window.
    public let dueAt: Date?
    /// `nil` unless overdue.
    public let overdueSince: Date?
    /// The slot identity.
    public let slotInstant: Date?
    /// #190/#191 (final) — from this instant the dose counts as missed.
    public let missedAfter: Date?

    public init(
        state: String,
        takenLate: Bool = false,
        dueAt: Date? = nil,
        overdueSince: Date? = nil,
        slotInstant: Date? = nil,
        missedAfter: Date? = nil
    ) {
        self.state = state
        self.takenLate = takenLate
        self.dueAt = dueAt
        self.overdueSince = overdueSince
        self.slotInstant = slotInstant
        self.missedAfter = missedAfter
    }

    /// **#190 (final) — the dose window as the server times it.** Today rows
    /// carry `dueAt` (the window opens), `overdueSince` (it turns overdue)
    /// and `missedAfter` (it counts as missed). Where the app grades a dose
    /// by the clock it reads these three instants, never fixed thresholds.
    /// `nil` when the row carries none of them.
    public func phase(at now: Date) -> MedicationDosePhaseTiming? {
        guard dueAt != nil || overdueSince != nil || missedAfter != nil else { return nil }
        if let missedAfter, now >= missedAfter { return .missed }
        if let overdueSince, now >= overdueSince { return .overdue }
        if let dueAt, now >= dueAt { return .due }
        return .pending
    }

    /// The server's overdue verdict, exactly as it sent it.
    public var isOverdue: Bool {
        state == "overdue"
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
    /// #191 — `takenVia`, `syncVersion` and `idempotencyKey` of the raw row.
    public let takenVia: String?
    public let syncVersion: Int?
    public let idempotencyKey: String?
    /// **#191 — `alreadyTaken: true`** on `POST /api/medications/{id}/intake`
    /// (and `/api/ingest/medication`): the slot already held a take, nothing
    /// was written, the row is the first take.
    public let alreadyTaken: Bool

    public init(
        id: String,
        medicationId: String,
        scheduledFor: Date,
        takenAt: Date? = nil,
        skipped: Bool = false,
        snoozedUntil: Date? = nil,
        takenVia: String? = nil,
        syncVersion: Int? = nil,
        idempotencyKey: String? = nil,
        alreadyTaken: Bool = false
    ) {
        self.id = id
        self.medicationId = medicationId
        self.scheduledFor = scheduledFor
        self.takenAt = takenAt
        self.skipped = skipped
        self.snoozedUntil = snoozedUntil
        self.takenVia = takenVia
        self.syncVersion = syncVersion
        self.idempotencyKey = idempotencyKey
        self.alreadyTaken = alreadyTaken
    }

    private enum CodingKeys: String, CodingKey {
        case id, medicationId, scheduledFor, takenAt, skipped, snoozedUntil
        case takenVia, syncVersion, idempotencyKey, alreadyTaken
    }

    /// `alreadyTaken` is a boolean inside `data`, next to the row's own
    /// fields (#191, final): `{ "data": { …row, "takenAt", "takenVia",
    /// "alreadyTaken": true } }`. Absent means a normal write.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        medicationId = try c.decode(String.self, forKey: .medicationId)
        scheduledFor = try c.decode(Date.self, forKey: .scheduledFor)
        takenAt = try c.decodeIfPresent(Date.self, forKey: .takenAt)
        skipped = try c.decodeIfPresent(Bool.self, forKey: .skipped) ?? false
        snoozedUntil = try c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        takenVia = try? c.decodeIfPresent(String.self, forKey: .takenVia)
        syncVersion = try? c.decodeIfPresent(Int.self, forKey: .syncVersion)
        idempotencyKey = try? c.decodeIfPresent(String.self, forKey: .idempotencyKey)
        alreadyTaken = (try? c.decodeIfPresent(Bool.self, forKey: .alreadyTaken)) == true
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(medicationId, forKey: .medicationId)
        try c.encode(scheduledFor, forKey: .scheduledFor)
        try c.encodeIfPresent(takenAt, forKey: .takenAt)
        try c.encode(skipped, forKey: .skipped)
        try c.encodeIfPresent(snoozedUntil, forKey: .snoozedUntil)
        try c.encodeIfPresent(takenVia, forKey: .takenVia)
        try c.encodeIfPresent(syncVersion, forKey: .syncVersion)
        try c.encodeIfPresent(idempotencyKey, forKey: .idempotencyKey)
        if alreadyTaken { try c.encode(true, forKey: .alreadyTaken) }
    }

    /// The `alreadyTaken` answer as the error every take path handles.
    public var alreadyTakenError: MedicationAlreadyTaken? {
        alreadyTaken ? MedicationAlreadyTaken(takenAt: takenAt, source: takenVia) : nil
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
            snoozedUntil: snoozedUntil,
            takenVia: takenVia,
            syncVersion: syncVersion,
            idempotencyKey: idempotencyKey
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
    /// Decode-only sentinel for a status this build cannot name
    /// (`IntakeStatus+Unknown.swift`). Never taken, never sent, never counted.
    case unknown = "__UNKNOWN__"
}

/// Where an open dose stands on the server's clock (``ServerDoseState/phase(at:)``).
public enum MedicationDosePhaseTiming: Sendable, Equatable {
    case pending
    case due
    case overdue
    case missed
}
