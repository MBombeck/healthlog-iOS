import Foundation

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
    /// Audit B-5 — decode-only sentinel for a status this build cannot name
    /// (`IntakeStatus+Unknown.swift`). Never taken, never sent, never counted.
    case unknown = "__UNKNOWN__"
}
