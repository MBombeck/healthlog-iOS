import Foundation
import SwiftData

// v0.11 W1 (KEYSTONE) — Local-canonical SwiftData mirror for manual-entry
// Measurement / Mood / MedicationIntake rows.
//
// **Why this exists:** In standalone mode (no server) a manual write has no
// server SWR path to read it back from — the list re-fetches from the server,
// finds nothing, and the write "vanishes". This local mirror gives those rows
// a canonical on-device home so a standalone write is immediately read back by
// the lists (the core acceptance — the "vanishing writes" trap).
//
// **Dormant in paired mode (v0.11 invariant):** these entities + the
// `LocalStore`/`LocalRepository` that own them are registered in the
// composition-root but nothing *reads* them while paired — the server SWR path
// stays authoritative. Read-union (W2), the Release door (W5), and adopt-on-
// pair upload (W4) are later waves; W1 is the data layer ONLY.
//
// **Pattern cloned (proven, in-repo):** the GLP-1 local stack —
// `GLP1LocalEntities.swift` (`@Model`) + `GLP1LocalStore.swift` (`@ModelActor`)
// + `GLP1LocalRepository.makeWithRecovery()` + Sendable `*Snapshot` DTOs. The
// `@Model` instances NEVER cross the actor boundary; the snapshots are the
// cross-actor currency.
//
// **Not a DTO promotion:** the server-facing `Measurement` / `Mood` /
// `Medication` Codable models stay untouched — this mirror is *parallel*, not a
// replacement (the deferred "A2" north star is the merge of the two).

// MARK: - Measurement mirror

/// Local-canonical manual measurement row. `externalId` is the server's
/// tombstone key (offline-sync §7.3) — a UUID string minted at write time so a
/// later adopt-on-pair upload (W4) round-trips with a stable identity. BP rows
/// carry `systolic`/`diastolic`; every other kind uses `value` + `unit`.
@Model
public final class LocalMeasurementEntry {
    /// Stable identity = UUID().uuidString. Unique so a re-issued write
    /// (optimistic retry) collapses onto the same row.
    public var externalId: String
    /// `MetricKind.rawValue`. Stored raw (not the enum) so a future kind a
    /// newer build writes degrades gracefully when read by an older build —
    /// mirrors the `OutboxOperation.kindRaw` forward-compat pattern.
    public var kind: String
    /// Primary value in the kind's canonical unit. For BP this is `0` and the
    /// real reading lives in `systolic`/`diastolic`.
    public var value: Double
    /// Server-wire unit string for `value`.
    public var unit: String
    /// Systolic component for blood-pressure rows. `nil` for every other kind.
    public var systolic: Double?
    /// Diastolic component for blood-pressure rows. `nil` for every other kind.
    public var diastolic: Double?
    /// When the measurement was taken (user-supplied; may be backdated).
    public var recordedAt: Date
    /// Optional free-text note.
    public var note: String?
    /// Provenance — `"manual"` for hand-entered rows. HK-imported rows (a later
    /// wave) would carry a different source so the read-union can dedupe.
    public var source: String
    /// Wall-clock creation timestamp.
    public var createdAt: Date

    #Unique<LocalMeasurementEntry>([\.externalId])

    public init(
        externalId: String = UUID().uuidString,
        kind: String,
        value: Double,
        unit: String,
        systolic: Double? = nil,
        diastolic: Double? = nil,
        recordedAt: Date,
        note: String? = nil,
        source: String = "manual",
        createdAt: Date = .now
    ) {
        self.externalId = externalId
        self.kind = kind
        self.value = value
        self.unit = unit
        self.systolic = systolic
        self.diastolic = diastolic
        self.recordedAt = recordedAt
        self.note = note
        self.source = source
        self.createdAt = createdAt
    }
}

// MARK: - Mood mirror

/// Local-canonical manual mood entry. `score` is the 1–5 valence the mood
/// picker emits; `tags` is the user's free-list of mood tags.
@Model
public final class LocalMoodEntry {
    public var externalId: String
    /// Mood valence score (matches the server `Mood.score` 1–5 scale).
    public var score: Int
    /// User-selected mood tags. Stored as a value-type array — SwiftData
    /// transparently boxes `[String]`.
    public var tags: [String]
    /// v0.14 — structured mood-tag keys (Daylio-style picker). New column;
    /// existing rows lightweight-migrate to the `[]` default so the offline
    /// store and adopt-on-pair carry structured tags exactly like `tags`.
    public var tagKeys: [String] = []
    public var note: String?
    public var recordedAt: Date
    public var source: String
    public var createdAt: Date

    #Unique<LocalMoodEntry>([\.externalId])

    public init(
        externalId: String = UUID().uuidString,
        score: Int,
        tags: [String] = [],
        tagKeys: [String] = [],
        note: String? = nil,
        recordedAt: Date,
        source: String = "manual",
        createdAt: Date = .now
    ) {
        self.externalId = externalId
        self.score = score
        self.tags = tags
        self.tagKeys = tagKeys
        self.note = note
        self.recordedAt = recordedAt
        self.source = source
        self.createdAt = createdAt
    }
}

// MARK: - Medication-intake mirror

/// Local-canonical manual medication-intake row. The reconcile key is the
/// composite `(medicationId, takenAt)` per spec §3.1 until the server's
/// version columns land — `externalId` is the local stable identity.
@Model
public final class LocalIntakeEntry {
    public var externalId: String
    /// Foreign key to `Medication.id` (server-issued string).
    public var medicationId: String
    /// When the dose was taken (user-supplied; may be backdated).
    public var takenAt: Date
    /// Intake disposition — raw of the server's status vocabulary
    /// (`"taken"` / `"skipped"` / `"snoozed"`). Stored raw for forward-compat.
    public var status: String
    /// v0.13 WP — server-wire injection-site raw value for a `taken` injection
    /// dose (`InjectionSite.serverRawValue`). `nil` for oral meds, non-taken
    /// dispositions, or when the user logged no site. Persisted so an offline
    /// injection records its site exactly like the paired `record(intake:)`
    /// path, and so the adopt-on-pair upload can round-trip it later.
    public var injectionSite: String?
    public var note: String?
    public var source: String
    public var createdAt: Date

    #Unique<LocalIntakeEntry>([\.externalId])

    public init(
        externalId: String = UUID().uuidString,
        medicationId: String,
        takenAt: Date,
        status: String,
        injectionSite: String? = nil,
        note: String? = nil,
        source: String = "manual",
        createdAt: Date = .now
    ) {
        self.externalId = externalId
        self.medicationId = medicationId
        self.takenAt = takenAt
        self.status = status
        self.injectionSite = injectionSite
        self.note = note
        self.source = source
        self.createdAt = createdAt
    }
}

// MARK: - Medication-definition mirror (v0.13 W5)

/// Local-canonical medication DEFINITION row — the offline med catalogue that
/// lets a standalone user create / schedule / take a medication with no server.
/// Mirrors the server `Medication` + `MedicationSchedule` fields the adopt-on-
/// pair upload needs so a paired upgrade maps cleanly (see
/// `LocalMedicationSnapshot.toAdoptCreateBody()`).
///
/// **Schedule fidelity:** the full `[MedicationScheduleDTO]` array is persisted
/// as encoded JSON (`schedulesJSON`) so the recurrence engine sees the exact
/// cadence/times/rrule/rolling/cyclic shape the user built — no lossy flatten.
/// A decode failure degrades to "no schedule" (PRN-like) rather than throwing.
///
/// **Soft-delete:** `archived` flips on archive (server parity = `active =
/// false`); `archivedAt` stamps the wall-clock so the Archived filter renders
/// relative time. Archived rows stay in the store (offline cache + idempotency
/// anchor for adopt-on-pair).
@Model
public final class LocalMedicationEntry {
    /// Stable identity = UUID().uuidString. Unique so an optimistic re-issue
    /// collapses onto the same row. Doubles as the adopt-on-pair externalId.
    public var externalId: String
    public var name: String
    public var dose: String
    public var treatmentClass: String?
    public var dosesPerUnit: Int?
    public var category: String?
    /// Route of administration (`ORAL | INJECTION | OTHER`).
    public var deliveryForm: String?
    /// Single-administration medication.
    public var oneShot: Bool
    /// Whether per-intake injection-site capture is active.
    public var trackInjectionSites: Bool
    public var notificationsEnabled: Bool
    /// Course-window start (midnight-anchored). `nil` = active from creation.
    public var startsOn: Date?
    /// Course-window end. `nil` = chronic.
    public var endsOn: Date?
    /// JSON-encoded `[MedicationScheduleDTO]`. `nil`/empty = no schedule (PRN).
    public var schedulesJSON: Data?
    /// Soft-delete flag (server parity: `active = false`).
    public var archived: Bool
    /// Wall-clock archive timestamp (for the Archived filter's relative time).
    public var archivedAt: Date?
    public var createdAt: Date

    #Unique<LocalMedicationEntry>([\.externalId])

    public init(
        externalId: String = UUID().uuidString,
        name: String,
        dose: String,
        treatmentClass: String? = nil,
        dosesPerUnit: Int? = nil,
        category: String? = nil,
        deliveryForm: String? = nil,
        oneShot: Bool = false,
        trackInjectionSites: Bool = false,
        notificationsEnabled: Bool = true,
        startsOn: Date? = nil,
        endsOn: Date? = nil,
        schedulesJSON: Data? = nil,
        archived: Bool = false,
        archivedAt: Date? = nil,
        createdAt: Date = .now
    ) {
        self.externalId = externalId
        self.name = name
        self.dose = dose
        self.treatmentClass = treatmentClass
        self.dosesPerUnit = dosesPerUnit
        self.category = category
        self.deliveryForm = deliveryForm
        self.oneShot = oneShot
        self.trackInjectionSites = trackInjectionSites
        self.notificationsEnabled = notificationsEnabled
        self.startsOn = startsOn
        self.endsOn = endsOn
        self.schedulesJSON = schedulesJSON
        self.archived = archived
        self.archivedAt = archivedAt
        self.createdAt = createdAt
    }
}

// MARK: - Snapshot converters (the cross-actor currency)

// The `*Snapshot` value-type *structs themselves* live in the platform-free
// `Repositories/StandaloneReadSeam.swift` (Core) so the repository read-union can
// project them into domain models without importing this app-only SwiftData file.
// Only the `init(from model:)` converters stay here, where the `@Model` classes
// are visible.

extension LocalMeasurementSnapshot {
    init(from model: LocalMeasurementEntry) {
        self.init(
            externalId: model.externalId,
            kind: model.kind,
            value: model.value,
            unit: model.unit,
            systolic: model.systolic,
            diastolic: model.diastolic,
            recordedAt: model.recordedAt,
            note: model.note,
            source: model.source,
            createdAt: model.createdAt
        )
    }
}

extension LocalMoodSnapshot {
    init(from model: LocalMoodEntry) {
        self.init(
            externalId: model.externalId,
            score: model.score,
            tags: model.tags,
            tagKeys: model.tagKeys,
            note: model.note,
            recordedAt: model.recordedAt,
            source: model.source,
            createdAt: model.createdAt
        )
    }
}

extension LocalIntakeSnapshot {
    init(from model: LocalIntakeEntry) {
        self.init(
            externalId: model.externalId,
            medicationId: model.medicationId,
            takenAt: model.takenAt,
            status: model.status,
            injectionSite: model.injectionSite,
            note: model.note,
            source: model.source,
            createdAt: model.createdAt
        )
    }
}

extension LocalMedicationSnapshot {
    init(from model: LocalMedicationEntry) {
        self.init(
            externalId: model.externalId,
            name: model.name,
            dose: model.dose,
            treatmentClass: model.treatmentClass,
            dosesPerUnit: model.dosesPerUnit,
            category: model.category,
            deliveryForm: model.deliveryForm,
            oneShot: model.oneShot,
            trackInjectionSites: model.trackInjectionSites,
            notificationsEnabled: model.notificationsEnabled,
            startsOn: model.startsOn,
            endsOn: model.endsOn,
            schedulesJSON: model.schedulesJSON,
            archived: model.archived,
            archivedAt: model.archivedAt,
            createdAt: model.createdAt
        )
    }
}

// MARK: - Schema v1

/// Versioned schema seed for the standalone local store. Mirrors the
/// `GLP1SchemaV1` / `OutboxSchemaV1` pattern — start from a named version so the
/// first migration (when read-union + version columns land) is explicit.
public enum StandaloneSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [
            LocalMeasurementEntry.self,
            LocalMoodEntry.self,
            LocalIntakeEntry.self,
            LocalMedicationEntry.self
        ]
    }
}
