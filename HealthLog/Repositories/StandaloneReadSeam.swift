import Foundation

// v0.11 W2 — the standalone read-union seam, declared in the platform-free
// repository layer (`HealthLogCore`) so `MeasurementsRepository` / `MoodRepository`
// / `MedicationsRepository` can branch on it WITHOUT importing the app-only
// `Standalone/` concretes (`LocalRepository`, `HealthKitReadAdapter`). The app
// target wires the real implementations into `StandaloneGate`; the repos see
// only these Sendable protocols.
//
// **Paired invariant (the whole point):** every repo takes `standalone:
// StandaloneGate? = nil`, defaulting to `nil`. With `nil` the repo is byte-for-
// byte the existing server/SWR code path — the standalone branch is unreachable.
// The composition-root injects a non-nil gate; the gate ALSO carries the live
// `isStandalone` flag, so even when wired the paired runtime stays on the server
// path. Standalone is a two-key lock: the gate must be present AND the mode flag
// must read standalone.

// MARK: - Sendable snapshots (the cross-actor currency)

// These value-type mirrors of the app-only `@Model` entities live HERE in Core so
// the repository read-union can consume them without importing the SwiftData
// `Standalone/LocalEntries.swift`. The `init(from model:)` converters stay in
// that app file (where the `@Model` classes are visible).

/// Value-type mirror of `LocalMeasurementEntry`. The `@Model` instance is bound
/// to the `LocalStore` actor's `ModelContext` and must never leak; this is what
/// crosses the boundary.
public struct LocalMeasurementSnapshot: Sendable, Hashable, Identifiable {
    public var id: String {
        externalId
    }

    public let externalId: String
    public let kind: String
    public let value: Double
    public let unit: String
    public let systolic: Double?
    public let diastolic: Double?
    public let recordedAt: Date
    public let note: String?
    public let source: String
    public let createdAt: Date

    public init(
        externalId: String,
        kind: String,
        value: Double,
        unit: String,
        systolic: Double? = nil,
        diastolic: Double? = nil,
        recordedAt: Date,
        note: String? = nil,
        source: String = "manual",
        createdAt: Date
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

public struct LocalMoodSnapshot: Sendable, Hashable, Identifiable {
    public var id: String {
        externalId
    }

    public let externalId: String
    public let score: Int
    public let tags: [String]
    /// v0.14 — structured mood-tag keys (Daylio-style picker). Persisted
    /// offline alongside the free-text `tags` and carried through adopt-on-pair.
    public let tagKeys: [String]
    public let note: String?
    public let recordedAt: Date
    public let source: String
    public let createdAt: Date

    public init(
        externalId: String,
        score: Int,
        tags: [String] = [],
        tagKeys: [String] = [],
        note: String? = nil,
        recordedAt: Date,
        source: String = "manual",
        createdAt: Date
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

public struct LocalIntakeSnapshot: Sendable, Hashable, Identifiable {
    public var id: String {
        externalId
    }

    public let externalId: String
    public let medicationId: String
    public let takenAt: Date
    public let status: String
    /// v0.13 WP — server-wire injection-site raw value for a `taken` injection
    /// dose. `nil` for oral meds / non-taken dispositions. Carried so a
    /// standalone injection logs its site like the paired path.
    public let injectionSite: String?
    public let note: String?
    public let source: String
    public let createdAt: Date

    public init(
        externalId: String,
        medicationId: String,
        takenAt: Date,
        status: String,
        injectionSite: String? = nil,
        note: String? = nil,
        source: String = "manual",
        createdAt: Date
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

/// Value-type mirror of `LocalMedicationEntry` (v0.13 W5) — the standalone
/// medication-definition snapshot. `schedulesJSON` carries the encoded
/// `[MedicationScheduleDTO]` so the recurrence engine + adopt-on-pair upload
/// reconstruct the exact cadence the user built. The `@Model` instance stays
/// bound to the `LocalStore` actor; this crosses the boundary.
public struct LocalMedicationSnapshot: Sendable, Hashable, Identifiable {
    public var id: String {
        externalId
    }

    public let externalId: String
    public let name: String
    public let dose: String
    public let treatmentClass: String?
    public let dosesPerUnit: Int?
    public let category: String?
    public let deliveryForm: String?
    public let oneShot: Bool
    public let trackInjectionSites: Bool
    public let notificationsEnabled: Bool
    public let startsOn: Date?
    public let endsOn: Date?
    public let schedulesJSON: Data?
    public let archived: Bool
    public let archivedAt: Date?
    public let createdAt: Date

    public init(
        externalId: String,
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
        createdAt: Date
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

    /// Decode the persisted `[MedicationScheduleDTO]` (empty on absent/corrupt).
    public var schedules: [MedicationScheduleDTO] {
        guard let schedulesJSON, !schedulesJSON.isEmpty else { return [] }
        return (try? JSONDecoder().decode([MedicationScheduleDTO].self, from: schedulesJSON)) ?? []
    }
}

/// Local-canonical read+write surface the standalone branch consumes — the
/// subset of `LocalRepository` the read-union + offline writes need (manual
/// Measurement / Mood / Intake rows). The app's `LocalRepository` conforms; the
/// repos depend only on this. Writes return the snapshot so the optimistic UI
/// path can swap its temporary row for the canonical one.
public protocol StandaloneLocalReading: Sendable {
    // Reads

    /// Manual measurement snapshots, optionally filtered by `MetricKind.rawValue`,
    /// newest-first, capped at `limit`.
    func standaloneMeasurements(kind: String?, limit: Int?) async throws -> [LocalMeasurementSnapshot]
    /// Manual mood snapshots over the trailing `days` (nil = all), newest-first.
    func standaloneMoods(days: Int?) async throws -> [LocalMoodSnapshot]
    /// Manual intake snapshots, optionally filtered by `medicationId`, newest-first.
    func standaloneIntakes(medicationId: String?) async throws -> [LocalIntakeSnapshot]

    // Writes (standalone-only — paired never reaches these)

    /// Persist a manual measurement locally; returns the canonical snapshot.
    func standaloneAddMeasurement(
        kind: String, value: Double, unit: String,
        systolic: Double?, diastolic: Double?, recordedAt: Date, note: String?
    ) async throws -> LocalMeasurementSnapshot
    /// Update an existing local measurement by `externalId`.
    func standaloneUpdateMeasurement(
        externalId: String, value: Double, unit: String,
        systolic: Double?, diastolic: Double?, recordedAt: Date, note: String?
    ) async throws
    /// Delete a local measurement by `externalId`.
    func standaloneDeleteMeasurement(externalId: String) async throws

    /// Persist a manual mood entry locally; returns the canonical snapshot.
    func standaloneAddMood(
        score: Int, tags: [String], tagKeys: [String], note: String?, recordedAt: Date
    ) async throws -> LocalMoodSnapshot
    /// Update an existing local mood entry by `externalId`.
    func standaloneUpdateMood(
        externalId: String, score: Int, tags: [String], tagKeys: [String], note: String?, recordedAt: Date
    ) async throws
    /// Delete a local mood entry by `externalId`.
    func standaloneDeleteMood(externalId: String) async throws

    /// Persist a manual medication intake locally; returns the canonical
    /// snapshot. `injectionSite` is the server-wire raw value for a `taken`
    /// injection dose (v0.13 WP), `nil` otherwise.
    func standaloneAddIntake(
        medicationId: String, takenAt: Date, status: String, injectionSite: String?, note: String?
    ) async throws -> LocalIntakeSnapshot
    /// Delete a local medication intake by `externalId`. Used by the undo
    /// path (v0.11 W26) to roll a standalone-confirmed dose back off the
    /// mirror — the mark *added* a row, so the inverse is a delete.
    func standaloneDeleteIntake(externalId: String) async throws

    // Medication definitions (v0.13 W5 — offline med catalogue)

    /// Medication-definition snapshots. `includeArchived == false` (default)
    /// returns only active rows — the list surface the user manages offline.
    func standaloneMedications(includeArchived: Bool) async throws -> [LocalMedicationSnapshot]
    /// Single medication definition by `externalId`, or `nil` when absent.
    /// Used by the adopt-on-pair definition provider.
    func standaloneMedication(externalId: String) async throws -> LocalMedicationSnapshot?
    /// Persist a new medication definition locally; returns the canonical snapshot.
    func standaloneAddMedication(_ snapshot: LocalMedicationSnapshot) async throws -> LocalMedicationSnapshot
    /// Update an existing medication definition by `externalId` (full replace of
    /// the mutable fields). No-op when the id is unknown.
    func standaloneUpdateMedication(_ snapshot: LocalMedicationSnapshot) async throws
    /// Soft-delete (archive) a medication definition by `externalId`.
    func standaloneArchiveMedication(externalId: String, archivedAt: Date) async throws
}

/// HealthKit-direct read surface (weight / heart-rate / steps for W2). The app's
/// `HealthKitReadAdapter` conforms. Declared here (Core) so the repos can read it
/// behind the gate without importing HealthKit. On a non-HealthKit host the
/// conforming type returns `[]`.
public protocol StandaloneHealthKitReadServing: Sendable {
    /// Recent discrete samples for `kind`, newest-first, capped at `limit`.
    func standaloneRecentSamples(kind: MetricKind, days: Int, limit: Int) async -> [SeriesPoint]
    /// Daily-bucketed cumulative series (steps) over the trailing `days`, oldest-first.
    func standaloneDailySeries(kind: MetricKind, days: Int) async -> [SeriesPoint]
}

/// The composition-root–assembled bundle the repos branch on. Sendable so it
/// crosses the repo-actor boundary. `isStandalone` is a `@Sendable` closure
/// reading the live runtime mode (UserDefaults-backed via `SyncModeStore`), so
/// a Settings-driven standalone↔paired flip is observed without re-constructing
/// the repos.
public struct StandaloneGate: Sendable {
    public let local: any StandaloneLocalReading
    public let healthKit: any StandaloneHealthKitReadServing
    /// True iff the app is running fully local right now. Read on every repo
    /// call so the branch tracks the live mode. Cheap (a UserDefaults string
    /// read) — no actor hop.
    public let isStandalone: @Sendable () -> Bool

    public init(
        local: any StandaloneLocalReading,
        healthKit: any StandaloneHealthKitReadServing,
        isStandalone: @escaping @Sendable () -> Bool
    ) {
        self.local = local
        self.healthKit = healthKit
        self.isStandalone = isStandalone
    }

    /// Convenience: the standalone branch is active iff the gate is wired AND the
    /// live mode reads standalone.
    public var isActive: Bool {
        isStandalone()
    }
}

// MARK: - Snapshot → domain projection

public extension LocalMeasurementSnapshot {
    /// Projects a local manual-measurement snapshot into the server-shaped
    /// `Measurement` the lists/charts already consume. BP rows rebuild the
    /// `.bloodPressure` value from `systolic`/`diastolic`; everything else is a
    /// `.scalar`. `source = .manual` (the only thing the mirror stores today).
    func toDomainMeasurement() -> Measurement {
        let metricKind = MetricKind(rawValue: kind) ?? .weight
        let value: MeasurementValue = if let systolic, let diastolic, metricKind == .bloodPressure {
            .bloodPressure(systolic: systolic, diastolic: diastolic)
        } else {
            .scalar(self.value)
        }
        return Measurement(
            id: externalId,
            kind: metricKind,
            recordedAt: recordedAt,
            value: value,
            note: note,
            source: .manual,
            externalUUID: externalId
        )
    }
}

public extension LocalMoodSnapshot {
    /// Projects a local mood snapshot into the server-shaped `MoodEntry`.
    func toDomainMood() -> MoodEntry {
        MoodEntry(
            id: externalId,
            recordedAt: recordedAt,
            score: score,
            tags: tags,
            tagKeys: tagKeys,
            note: note
        )
    }
}

public extension LocalMedicationSnapshot {
    /// Projects a local medication-definition snapshot into the server-shaped
    /// `Medication` the lists / cards / recurrence engine already consume. The
    /// persisted `[MedicationScheduleDTO]` is decoded back through the same
    /// `MedicationWireDTO.toDomain()` path the paired list uses, so the cadence
    /// dispatch (one-shot → rolling → rrule → legacy) is byte-identical to a
    /// server-fetched medication. `id == externalId` (stable local identity).
    ///
    /// **v0.14 DATA — `lastTakenAt` anchor (med-due regression fix).** In
    /// standalone the *only* "due today" source is engine-synthesised
    /// placeholders (the local intake mirror carries only taken rows), and the
    /// recurrence engine anchors a rolling / `startsOn==today` cadence on
    /// `lastIntakeAt ?? startsOn ?? createdAt`. Hardcoding `nil` here made the
    /// engine project the next rolling slot off `createdAt` → tomorrow → zero
    /// occurrences today → the Dashboard/Medications/widget surfaces falsely
    /// said "nothing due" (v0.13 W5 regression). The caller threads the local
    /// mirror's latest *taken* intake for this med so the engine anchors on the
    /// real last dose, matching the paired/server projection.
    func toDomainMedication(lastTakenAt: Date? = nil) -> Medication {
        let wire = MedicationWireDTO(
            id: externalId,
            name: name,
            dose: dose,
            treatmentClass: treatmentClass,
            dosesPerUnit: dosesPerUnit,
            category: category,
            active: !archived,
            notificationsEnabled: notificationsEnabled,
            schedules: schedules.isEmpty ? nil : schedules,
            lastTakenAt: lastTakenAt,
            todayEventCount: nil,
            oneShot: oneShot,
            startsOn: startsOn.map(Self.isoDay),
            endsOn: endsOn.map(Self.isoDay),
            deliveryForm: deliveryForm,
            createdAt: createdAt,
            trackInjectionSites: trackInjectionSites
        )
        var medication = wire.toDomain()
        // Carry the optimistic archive timestamp the wire DTO can't model.
        if archived, archivedAt != nil {
            medication = Medication(
                id: medication.id,
                name: medication.name,
                dose: medication.dose,
                treatmentClass: medication.treatmentClass,
                category: medication.category,
                dosesPerUnit: medication.dosesPerUnit,
                schedule: medication.schedule,
                lastTakenAt: medication.lastTakenAt,
                todayEventCount: medication.todayEventCount,
                notificationsEnabled: medication.notificationsEnabled,
                active: medication.active,
                archivedAt: archivedAt,
                startsOn: medication.startsOn,
                endsOn: medication.endsOn,
                oneShot: medication.oneShot,
                deliveryForm: medication.deliveryForm,
                createdAt: medication.createdAt,
                trackInjectionSites: medication.trackInjectionSites,
                allowedInjectionSites: medication.allowedInjectionSites
            )
        }
        return medication
    }

    /// `YYYY-MM-DD` for a course-window `Date`, matching the server `@db.Date`
    /// boundary the wire DTO parses back via `parseCourseDate`.
    private static func isoDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }
}
