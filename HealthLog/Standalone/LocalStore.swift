import Foundation
import SwiftData

/// `@ModelActor` persistence layer for the standalone local mirror. Lives
/// behind `LocalRepository`; callers never see this type nor a `ModelContext`,
/// only Sendable value-type snapshots cross the actor boundary. Mirrors the
/// `GLP1LocalStore` / `OutboxStore` discipline (ADR-011/012 + the
/// swift-concurrency skill's Core-Data-→-SwiftData guidance).
///
/// **Threading:** `PersistentModel` instances are bound to this actor's
/// `ModelContext` and must never leak across the boundary. The `*Snapshot`
/// value-types in `LocalEntries.swift` are the Sendable mirror.
@ModelActor
public actor LocalStore {
    // MARK: - Measurements

    public func snapshotMeasurements(
        kind: String?,
        limit: Int?
    ) throws -> [LocalMeasurementSnapshot] {
        var descriptor = if let kind {
            FetchDescriptor<LocalMeasurementEntry>(
                predicate: #Predicate { $0.kind == kind },
                sortBy: [SortDescriptor(\.recordedAt, order: .reverse)]
            )
        } else {
            FetchDescriptor<LocalMeasurementEntry>(
                sortBy: [SortDescriptor(\.recordedAt, order: .reverse)]
            )
        }
        if let limit, limit > 0 {
            descriptor.fetchLimit = limit
        }
        return try modelContext.fetch(descriptor).map(LocalMeasurementSnapshot.init(from:))
    }

    public func insertMeasurement(_ snapshot: LocalMeasurementSnapshot) throws {
        let entry = LocalMeasurementEntry(
            externalId: snapshot.externalId,
            kind: snapshot.kind,
            value: snapshot.value,
            unit: snapshot.unit,
            systolic: snapshot.systolic,
            diastolic: snapshot.diastolic,
            recordedAt: snapshot.recordedAt,
            note: snapshot.note,
            source: snapshot.source,
            createdAt: snapshot.createdAt
        )
        modelContext.insert(entry)
        try modelContext.save()
    }

    public func updateMeasurement(
        externalId: String,
        value: Double,
        unit: String,
        systolic: Double?,
        diastolic: Double?,
        recordedAt: Date,
        note: String?
    ) throws {
        let descriptor = FetchDescriptor<LocalMeasurementEntry>(
            predicate: #Predicate { $0.externalId == externalId }
        )
        guard let entry = try modelContext.fetch(descriptor).first else { return }
        entry.value = value
        entry.unit = unit
        entry.systolic = systolic
        entry.diastolic = diastolic
        entry.recordedAt = recordedAt
        entry.note = note
        try modelContext.save()
    }

    public func deleteMeasurement(externalId: String) throws {
        let descriptor = FetchDescriptor<LocalMeasurementEntry>(
            predicate: #Predicate { $0.externalId == externalId }
        )
        if let entry = try modelContext.fetch(descriptor).first {
            modelContext.delete(entry)
            try modelContext.save()
        }
    }

    // MARK: - Moods

    public func snapshotMoods(sinceDays: Int?) throws -> [LocalMoodSnapshot] {
        let descriptor: FetchDescriptor<LocalMoodEntry>
        if let sinceDays {
            let cutoff = Calendar.current.date(
                byAdding: .day,
                value: -max(0, sinceDays),
                to: .now
            ) ?? .distantPast
            descriptor = FetchDescriptor<LocalMoodEntry>(
                predicate: #Predicate { $0.recordedAt >= cutoff },
                sortBy: [SortDescriptor(\.recordedAt, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<LocalMoodEntry>(
                sortBy: [SortDescriptor(\.recordedAt, order: .reverse)]
            )
        }
        return try modelContext.fetch(descriptor).map(LocalMoodSnapshot.init(from:))
    }

    public func insertMood(_ snapshot: LocalMoodSnapshot) throws {
        let entry = LocalMoodEntry(
            externalId: snapshot.externalId,
            score: snapshot.score,
            tags: snapshot.tags,
            tagKeys: snapshot.tagKeys,
            note: snapshot.note,
            recordedAt: snapshot.recordedAt,
            source: snapshot.source,
            createdAt: snapshot.createdAt
        )
        modelContext.insert(entry)
        try modelContext.save()
    }

    public func updateMood(
        externalId: String,
        score: Int,
        tags: [String],
        tagKeys: [String],
        note: String?,
        recordedAt: Date
    ) throws {
        let descriptor = FetchDescriptor<LocalMoodEntry>(
            predicate: #Predicate { $0.externalId == externalId }
        )
        guard let entry = try modelContext.fetch(descriptor).first else { return }
        entry.score = score
        entry.tags = tags
        entry.tagKeys = tagKeys
        entry.note = note
        entry.recordedAt = recordedAt
        try modelContext.save()
    }

    public func deleteMood(externalId: String) throws {
        let descriptor = FetchDescriptor<LocalMoodEntry>(
            predicate: #Predicate { $0.externalId == externalId }
        )
        if let entry = try modelContext.fetch(descriptor).first {
            modelContext.delete(entry)
            try modelContext.save()
        }
    }

    // MARK: - Intakes

    public func snapshotIntakes(medicationId: String?) throws -> [LocalIntakeSnapshot] {
        let descriptor = if let medicationId {
            FetchDescriptor<LocalIntakeEntry>(
                predicate: #Predicate { $0.medicationId == medicationId },
                sortBy: [SortDescriptor(\.takenAt, order: .reverse)]
            )
        } else {
            FetchDescriptor<LocalIntakeEntry>(
                sortBy: [SortDescriptor(\.takenAt, order: .reverse)]
            )
        }
        return try modelContext.fetch(descriptor).map(LocalIntakeSnapshot.init(from:))
    }

    public func insertIntake(_ snapshot: LocalIntakeSnapshot) throws {
        let entry = LocalIntakeEntry(
            externalId: snapshot.externalId,
            medicationId: snapshot.medicationId,
            takenAt: snapshot.takenAt,
            status: snapshot.status,
            injectionSite: snapshot.injectionSite,
            note: snapshot.note,
            source: snapshot.source,
            createdAt: snapshot.createdAt
        )
        modelContext.insert(entry)
        try modelContext.save()
    }

    public func updateIntake(
        externalId: String,
        takenAt: Date,
        status: String,
        note: String?
    ) throws {
        let descriptor = FetchDescriptor<LocalIntakeEntry>(
            predicate: #Predicate { $0.externalId == externalId }
        )
        guard let entry = try modelContext.fetch(descriptor).first else { return }
        entry.takenAt = takenAt
        entry.status = status
        entry.note = note
        try modelContext.save()
    }

    public func deleteIntake(externalId: String) throws {
        let descriptor = FetchDescriptor<LocalIntakeEntry>(
            predicate: #Predicate { $0.externalId == externalId }
        )
        if let entry = try modelContext.fetch(descriptor).first {
            modelContext.delete(entry)
            try modelContext.save()
        }
    }

    // MARK: - Medication definitions (v0.13 W5)

    public func snapshotMedications(includeArchived: Bool) throws -> [LocalMedicationSnapshot] {
        let descriptor = if includeArchived {
            FetchDescriptor<LocalMedicationEntry>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        } else {
            FetchDescriptor<LocalMedicationEntry>(
                predicate: #Predicate { $0.archived == false },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        }
        return try modelContext.fetch(descriptor).map(LocalMedicationSnapshot.init(from:))
    }

    public func snapshotMedication(externalId: String) throws -> LocalMedicationSnapshot? {
        let descriptor = FetchDescriptor<LocalMedicationEntry>(
            predicate: #Predicate { $0.externalId == externalId }
        )
        return try modelContext.fetch(descriptor).first.map(LocalMedicationSnapshot.init(from:))
    }

    public func insertMedication(_ snapshot: LocalMedicationSnapshot) throws {
        let entry = LocalMedicationEntry(
            externalId: snapshot.externalId,
            name: snapshot.name,
            dose: snapshot.dose,
            treatmentClass: snapshot.treatmentClass,
            dosesPerUnit: snapshot.dosesPerUnit,
            category: snapshot.category,
            deliveryForm: snapshot.deliveryForm,
            oneShot: snapshot.oneShot,
            trackInjectionSites: snapshot.trackInjectionSites,
            notificationsEnabled: snapshot.notificationsEnabled,
            startsOn: snapshot.startsOn,
            endsOn: snapshot.endsOn,
            schedulesJSON: snapshot.schedulesJSON,
            archived: snapshot.archived,
            archivedAt: snapshot.archivedAt,
            createdAt: snapshot.createdAt
        )
        modelContext.insert(entry)
        try modelContext.save()
    }

    public func updateMedication(_ snapshot: LocalMedicationSnapshot) throws {
        let externalId = snapshot.externalId
        let descriptor = FetchDescriptor<LocalMedicationEntry>(
            predicate: #Predicate { $0.externalId == externalId }
        )
        guard let entry = try modelContext.fetch(descriptor).first else { return }
        entry.name = snapshot.name
        entry.dose = snapshot.dose
        entry.treatmentClass = snapshot.treatmentClass
        entry.dosesPerUnit = snapshot.dosesPerUnit
        entry.category = snapshot.category
        entry.deliveryForm = snapshot.deliveryForm
        entry.oneShot = snapshot.oneShot
        entry.trackInjectionSites = snapshot.trackInjectionSites
        entry.notificationsEnabled = snapshot.notificationsEnabled
        entry.startsOn = snapshot.startsOn
        entry.endsOn = snapshot.endsOn
        entry.schedulesJSON = snapshot.schedulesJSON
        entry.archived = snapshot.archived
        entry.archivedAt = snapshot.archivedAt
        try modelContext.save()
    }

    public func archiveMedication(externalId: String, archivedAt: Date) throws {
        let descriptor = FetchDescriptor<LocalMedicationEntry>(
            predicate: #Predicate { $0.externalId == externalId }
        )
        guard let entry = try modelContext.fetch(descriptor).first else { return }
        entry.archived = true
        entry.archivedAt = archivedAt
        try modelContext.save()
    }

    // MARK: - Backfill / wipe

    /// Snapshots every row across all three tables for the W4 adopt-on-pair
    /// upload. Sorted newest-first per table so the upload preserves recency.
    public func snapshotAll() throws -> LocalBackfillBundle {
        let measurements = try modelContext.fetch(
            FetchDescriptor<LocalMeasurementEntry>(
                sortBy: [SortDescriptor(\.recordedAt, order: .reverse)]
            )
        ).map(LocalMeasurementSnapshot.init(from:))
        let moods = try modelContext.fetch(
            FetchDescriptor<LocalMoodEntry>(
                sortBy: [SortDescriptor(\.recordedAt, order: .reverse)]
            )
        ).map(LocalMoodSnapshot.init(from:))
        let intakes = try modelContext.fetch(
            FetchDescriptor<LocalIntakeEntry>(
                sortBy: [SortDescriptor(\.takenAt, order: .reverse)]
            )
        ).map(LocalIntakeSnapshot.init(from:))
        let medications = try modelContext.fetch(
            FetchDescriptor<LocalMedicationEntry>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        ).map(LocalMedicationSnapshot.init(from:))
        return LocalBackfillBundle(
            measurements: measurements,
            moods: moods,
            intakes: intakes,
            medications: medications
        )
    }

    /// Wipes every row from every table — used by the account-deletion cascade
    /// (mirrors `GLP1LocalStore.deleteAll` / `OutboxStore.deleteAll`).
    public func deleteAll() throws {
        for row in try modelContext.fetch(FetchDescriptor<LocalMeasurementEntry>()) {
            modelContext.delete(row)
        }
        for row in try modelContext.fetch(FetchDescriptor<LocalMoodEntry>()) {
            modelContext.delete(row)
        }
        for row in try modelContext.fetch(FetchDescriptor<LocalIntakeEntry>()) {
            modelContext.delete(row)
        }
        for row in try modelContext.fetch(FetchDescriptor<LocalMedicationEntry>()) {
            modelContext.delete(row)
        }
        try modelContext.save()
    }
}

// MARK: - Backfill bundle

/// Sendable bundle of every locally-canonical row, used by the W4 adopt-on-pair
/// upload. Carrying all three tables in one value keeps the actor-boundary hop
/// to a single round-trip.
public struct LocalBackfillBundle: Sendable, Hashable {
    public let measurements: [LocalMeasurementSnapshot]
    public let moods: [LocalMoodSnapshot]
    public let intakes: [LocalIntakeSnapshot]
    /// v0.13 W5 — local medication definitions, so adopt-on-pair recreates the
    /// med server-side before remapping its intakes (resolved by externalId).
    public let medications: [LocalMedicationSnapshot]

    public init(
        measurements: [LocalMeasurementSnapshot],
        moods: [LocalMoodSnapshot],
        intakes: [LocalIntakeSnapshot],
        medications: [LocalMedicationSnapshot] = []
    ) {
        self.measurements = measurements
        self.moods = moods
        self.intakes = intakes
        self.medications = medications
    }

    public var isEmpty: Bool {
        measurements.isEmpty && moods.isEmpty && intakes.isEmpty && medications.isEmpty
    }
}

// MARK: - ModelContainer factories

public extension LocalStore {
    /// Production initializer: persistent SQLite under
    /// `Application Support/HealthLog/Standalone/standalone.sqlite`, no CloudKit.
    /// Mirrors the `GLP1LocalStore.makePersistent` pattern (ADR-011/012).
    static func makePersistent() throws -> ModelContainer {
        let storeURL = try persistentStoreURL()
        let schema = Schema(versionedSchema: StandaloneSchemaV1.self)
        let config = ModelConfiguration(
            "HealthLogStandalone",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: schema,
            migrationPlan: nil,
            configurations: [config]
        )
        try? applyFileProtection(to: storeURL)
        return container
    }

    /// In-memory initializer for tests + degraded fallback. Symmetric with
    /// `GLP1LocalStore.makeInMemory`.
    static func makeInMemory() throws -> ModelContainer {
        let schema = Schema(versionedSchema: StandaloneSchemaV1.self)
        let config = ModelConfiguration(
            "HealthLogStandalone.test",
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: nil,
            configurations: [config]
        )
    }

    static func persistentStoreURL() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("HealthLog/Standalone", isDirectory: true)
        try SensitiveDataBackupExclusion.prepareDirectory(at: dir, fileManager: fm)
        return dir.appendingPathComponent("standalone.sqlite")
    }

    /// Best-effort file-protection (Outbox-/GLP1-store pattern). `complete-
    /// UntilFirstUserAuthentication` per ADR-011/012 — the data is sensitive
    /// (medical) but must be readable post-first-unlock for background-refresh
    /// + reminder triggers.
    static func applyFileProtection(to storeURL: URL) throws {
        let fm = FileManager.default
        let candidates = [
            storeURL,
            storeURL.appendingPathExtension("shm"),
            storeURL.appendingPathExtension("wal")
        ]
        for url in candidates where fm.fileExists(atPath: url.path) {
            try fm.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        }
    }
}
