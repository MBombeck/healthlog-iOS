import Foundation
import SwiftData

/// `@ModelActor` persistence layer for the GLP-1 local entities. Lives
/// behind the `GLP1LocalRepository` actor — callers never see this type
/// nor a `ModelContext`; only Sendable value-type snapshots cross the
/// actor boundary. Mirrors the `OutboxStore` discipline (see ADR-011 +
/// the swift-concurrency skill's Core-Data-→-SwiftData guidance).
///
/// **Threading:** `PersistentModel` instances are bound to this actor's
/// `ModelContext` and must never leak across the boundary. The four
/// `*Snapshot` value-types below are the Sendable mirror.
@ModelActor
public actor GLP1LocalStore {
    // MARK: - Titration

    public func snapshotTitrationSteps(
        medicationID: String
    ) throws -> [TitrationStepEntrySnapshot] {
        let descriptor = FetchDescriptor<TitrationStepEntry>(
            predicate: #Predicate { $0.medicationID == medicationID },
            sortBy: [SortDescriptor(\.effectiveFrom, order: .forward)]
        )
        return try modelContext.fetch(descriptor).map(TitrationStepEntrySnapshot.init(from:))
    }

    public func insertTitrationStep(
        id: String,
        medicationID: String,
        effectiveFrom: Date,
        doseMg: Double,
        note: String?
    ) throws {
        let entry = TitrationStepEntry(
            id: id,
            medicationID: medicationID,
            effectiveFrom: effectiveFrom,
            doseMg: doseMg,
            note: note
        )
        modelContext.insert(entry)
        try modelContext.save()
    }

    public func updateTitrationStep(
        id: String,
        effectiveFrom: Date,
        doseMg: Double,
        note: String?
    ) throws {
        let descriptor = FetchDescriptor<TitrationStepEntry>(
            predicate: #Predicate { $0.id == id }
        )
        guard let entry = try modelContext.fetch(descriptor).first else { return }
        entry.effectiveFrom = effectiveFrom
        entry.doseMg = doseMg
        entry.note = note
        try modelContext.save()
    }

    public func deleteTitrationStep(id: String) throws {
        let descriptor = FetchDescriptor<TitrationStepEntry>(
            predicate: #Predicate { $0.id == id }
        )
        if let entry = try modelContext.fetch(descriptor).first {
            modelContext.delete(entry)
            try modelContext.save()
        }
    }

    // MARK: - Side-effects

    public func snapshotSideEffects(
        medicationID: String,
        sinceDays: Int
    ) throws -> [SideEffectEntrySnapshot] {
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -max(0, sinceDays),
            to: .now
        ) ?? .distantPast
        let descriptor = FetchDescriptor<SideEffectEntry>(
            predicate: #Predicate {
                $0.medicationID == medicationID && $0.loggedAt >= cutoff
            },
            sortBy: [SortDescriptor(\.loggedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map(SideEffectEntrySnapshot.init(from:))
    }

    public func insertSideEffect(
        id: String,
        medicationID: String,
        loggedAt: Date,
        kindRaw: String,
        severity: Int,
        note: String?
    ) throws {
        let entry = SideEffectEntry(
            id: id,
            medicationID: medicationID,
            loggedAt: loggedAt,
            kindRaw: kindRaw,
            severity: severity,
            note: note
        )
        modelContext.insert(entry)
        try modelContext.save()
    }

    public func deleteSideEffect(id: String) throws {
        let descriptor = FetchDescriptor<SideEffectEntry>(
            predicate: #Predicate { $0.id == id }
        )
        if let entry = try modelContext.fetch(descriptor).first {
            modelContext.delete(entry)
            try modelContext.save()
        }
    }

    /// v0.12 SP3 — back-write the server log id onto a mirrored local row.
    public func setSideEffectServerID(localID: String, serverID: String) throws {
        let descriptor = FetchDescriptor<SideEffectEntry>(
            predicate: #Predicate { $0.id == localID }
        )
        guard let entry = try modelContext.fetch(descriptor).first else { return }
        entry.serverID = serverID
        entry.syncedAt = .now
        try modelContext.save()
    }

    /// v0.12 SP3 — resolve the server log id for a local row (if mirrored).
    public func sideEffectServerID(localID: String) throws -> String? {
        let descriptor = FetchDescriptor<SideEffectEntry>(
            predicate: #Predicate { $0.id == localID }
        )
        return try modelContext.fetch(descriptor).first?.serverID
    }

    // MARK: - Pen inventory

    public func snapshotPens(
        medicationID: String
    ) throws -> [PenInventoryEntrySnapshot] {
        let descriptor = FetchDescriptor<PenInventoryEntry>(
            predicate: #Predicate { $0.medicationID == medicationID },
            sortBy: [SortDescriptor(\.dispensedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map(PenInventoryEntrySnapshot.init(from:))
    }

    public func insertPen(
        id: String,
        medicationID: String,
        manufacturer: String,
        doseStrength: String,
        dispensedAt: Date,
        firstUsedAt: Date?,
        finishedAt: Date?,
        notes: String?
    ) throws {
        let entry = PenInventoryEntry(
            id: id,
            medicationID: medicationID,
            manufacturer: manufacturer,
            doseStrength: doseStrength,
            dispensedAt: dispensedAt,
            firstUsedAt: firstUsedAt,
            finishedAt: finishedAt,
            notes: notes
        )
        modelContext.insert(entry)
        try modelContext.save()
    }

    public func markPenFinished(id: String, finishedAt: Date) throws {
        let descriptor = FetchDescriptor<PenInventoryEntry>(
            predicate: #Predicate { $0.id == id }
        )
        guard let entry = try modelContext.fetch(descriptor).first else { return }
        entry.finishedAt = finishedAt
        try modelContext.save()
    }

    public func deletePen(id: String) throws {
        let descriptor = FetchDescriptor<PenInventoryEntry>(
            predicate: #Predicate { $0.id == id }
        )
        if let entry = try modelContext.fetch(descriptor).first {
            modelContext.delete(entry)
            try modelContext.save()
        }
    }

    /// v0.12 SP4 — back-write the server inventory-item id onto a mirrored pen.
    public func setPenServerID(localID: String, serverID: String) throws {
        let descriptor = FetchDescriptor<PenInventoryEntry>(
            predicate: #Predicate { $0.id == localID }
        )
        guard let entry = try modelContext.fetch(descriptor).first else { return }
        entry.serverID = serverID
        entry.syncedAt = .now
        try modelContext.save()
    }

    // #52 — `upsertPenFromServer` lives in `GLP1LocalStore+PenBackfill.swift`
    // (file_length discipline: this file sits just under the 600-line cap).

    /// v0.12 SP4 — resolve the server inventory-item id for a local pen.
    public func penServerID(localID: String) throws -> String? {
        let descriptor = FetchDescriptor<PenInventoryEntry>(
            predicate: #Predicate { $0.id == localID }
        )
        return try modelContext.fetch(descriptor).first?.serverID
    }

    // MARK: - Injection sites

    public func snapshotSites(
        medicationID: String,
        limit: Int
    ) throws -> [InjectionSiteEntrySnapshot] {
        var descriptor = FetchDescriptor<InjectionSiteEntry>(
            predicate: #Predicate { $0.medicationID == medicationID },
            sortBy: [SortDescriptor(\.injectedAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(1, limit)
        return try modelContext.fetch(descriptor).map(InjectionSiteEntrySnapshot.init(from:))
    }

    public func insertSite(
        id: String,
        medicationID: String,
        injectedAt: Date,
        siteRaw: String,
        note: String?
    ) throws {
        let entry = InjectionSiteEntry(
            id: id,
            medicationID: medicationID,
            injectedAt: injectedAt,
            siteRaw: siteRaw,
            note: note
        )
        modelContext.insert(entry)
        try modelContext.save()
    }

    public func deleteSite(id: String) throws {
        let descriptor = FetchDescriptor<InjectionSiteEntry>(
            predicate: #Predicate { $0.id == id }
        )
        if let entry = try modelContext.fetch(descriptor).first {
            modelContext.delete(entry)
            try modelContext.save()
        }
    }

    // MARK: - Cascade delete (account-deletion / medication-archive)

    /// Drops every row for the given medication across all four tables.
    /// Used when the parent medication is archived or the account is
    /// purged. Idempotent — no-op when nothing matches.
    public func deleteAllForMedication(_ medicationID: String) throws {
        let titrationDescriptor = FetchDescriptor<TitrationStepEntry>(
            predicate: #Predicate { $0.medicationID == medicationID }
        )
        for row in try modelContext.fetch(titrationDescriptor) {
            modelContext.delete(row)
        }
        let sideEffectDescriptor = FetchDescriptor<SideEffectEntry>(
            predicate: #Predicate { $0.medicationID == medicationID }
        )
        for row in try modelContext.fetch(sideEffectDescriptor) {
            modelContext.delete(row)
        }
        let penDescriptor = FetchDescriptor<PenInventoryEntry>(
            predicate: #Predicate { $0.medicationID == medicationID }
        )
        for row in try modelContext.fetch(penDescriptor) {
            modelContext.delete(row)
        }
        let siteDescriptor = FetchDescriptor<InjectionSiteEntry>(
            predicate: #Predicate { $0.medicationID == medicationID }
        )
        for row in try modelContext.fetch(siteDescriptor) {
            modelContext.delete(row)
        }
        try modelContext.save()
    }

    /// Wipes every row from every table — used by the account-deletion
    /// cascade (mirrors `OutboxStore.deleteAll`).
    public func deleteAll() throws {
        for row in try modelContext.fetch(FetchDescriptor<TitrationStepEntry>()) {
            modelContext.delete(row)
        }
        for row in try modelContext.fetch(FetchDescriptor<SideEffectEntry>()) {
            modelContext.delete(row)
        }
        for row in try modelContext.fetch(FetchDescriptor<PenInventoryEntry>()) {
            modelContext.delete(row)
        }
        for row in try modelContext.fetch(FetchDescriptor<InjectionSiteEntry>()) {
            modelContext.delete(row)
        }
        try modelContext.save()
    }
}

// MARK: - Sendable snapshots

public struct TitrationStepEntrySnapshot: Sendable, Hashable, Identifiable {
    public let id: String
    public let medicationID: String
    public let effectiveFrom: Date
    public let doseMg: Double
    public let note: String?
    public let createdAt: Date

    init(from model: TitrationStepEntry) {
        id = model.id
        medicationID = model.medicationID
        effectiveFrom = model.effectiveFrom
        doseMg = model.doseMg
        note = model.note
        createdAt = model.createdAt
    }

    public init(
        id: String,
        medicationID: String,
        effectiveFrom: Date,
        doseMg: Double,
        note: String?,
        createdAt: Date
    ) {
        self.id = id
        self.medicationID = medicationID
        self.effectiveFrom = effectiveFrom
        self.doseMg = doseMg
        self.note = note
        self.createdAt = createdAt
    }
}

public struct SideEffectEntrySnapshot: Sendable, Hashable, Identifiable {
    public let id: String
    public let medicationID: String
    public let loggedAt: Date
    public let kindRaw: String
    public let severity: Int
    public let note: String?
    public let createdAt: Date
    /// v0.12 SP3 — server log id once this row has been mirrored to
    /// `…/side-effects`; `nil` for purely-local (standalone or not-yet-synced)
    /// rows and for server-origin rows hydrated by reconcile (where it equals
    /// `id`).
    public let serverID: String?

    /// Convenience accessor — falls back to `nil` if the persisted raw
    /// string is unknown (forward-compat: a future kind written by a
    /// newer build then read by an older build degrades gracefully).
    public var kind: SideEffectKind? {
        SideEffectKind(rawValue: kindRaw)
    }

    init(from model: SideEffectEntry) {
        id = model.id
        medicationID = model.medicationID
        loggedAt = model.loggedAt
        kindRaw = model.kindRaw
        severity = model.severity
        note = model.note
        createdAt = model.createdAt
        serverID = model.serverID
    }

    public init(
        id: String,
        medicationID: String,
        loggedAt: Date,
        kindRaw: String,
        severity: Int,
        note: String?,
        createdAt: Date,
        serverID: String? = nil
    ) {
        self.id = id
        self.medicationID = medicationID
        self.loggedAt = loggedAt
        self.kindRaw = kindRaw
        self.severity = severity
        self.note = note
        self.createdAt = createdAt
        self.serverID = serverID
    }
}

public struct PenInventoryEntrySnapshot: Sendable, Hashable, Identifiable {
    public let id: String
    public let medicationID: String
    public let manufacturer: String
    public let doseStrength: String
    public let dispensedAt: Date
    public let firstUsedAt: Date?
    public let finishedAt: Date?
    public let notes: String?
    public let createdAt: Date
    /// v0.12 SP4 — server inventory-item id once mirrored; `nil` for purely-local
    /// (standalone or not-yet-synced) pens.
    public let serverID: String?

    /// Whether the pen is "in use" — has been started but not finished.
    public var isActive: Bool {
        firstUsedAt != nil && finishedAt == nil
    }

    /// Whether the pen has been fully consumed.
    public var isFinished: Bool {
        finishedAt != nil
    }

    init(from model: PenInventoryEntry) {
        id = model.id
        medicationID = model.medicationID
        manufacturer = model.manufacturer
        doseStrength = model.doseStrength
        dispensedAt = model.dispensedAt
        firstUsedAt = model.firstUsedAt
        finishedAt = model.finishedAt
        notes = model.notes
        createdAt = model.createdAt
        serverID = model.serverID
    }

    public init(
        id: String,
        medicationID: String,
        manufacturer: String,
        doseStrength: String,
        dispensedAt: Date,
        firstUsedAt: Date?,
        finishedAt: Date?,
        notes: String?,
        createdAt: Date,
        serverID: String? = nil
    ) {
        self.id = id
        self.medicationID = medicationID
        self.manufacturer = manufacturer
        self.doseStrength = doseStrength
        self.dispensedAt = dispensedAt
        self.firstUsedAt = firstUsedAt
        self.finishedAt = finishedAt
        self.notes = notes
        self.createdAt = createdAt
        self.serverID = serverID
    }
}

public struct InjectionSiteEntrySnapshot: Sendable, Hashable, Identifiable {
    public let id: String
    public let medicationID: String
    public let injectedAt: Date
    public let siteRaw: String
    public let note: String?
    public let createdAt: Date

    public var site: InjectionSite? {
        InjectionSite(rawValue: siteRaw)
    }

    init(from model: InjectionSiteEntry) {
        id = model.id
        medicationID = model.medicationID
        injectedAt = model.injectedAt
        siteRaw = model.siteRaw
        note = model.note
        createdAt = model.createdAt
    }

    public init(
        id: String,
        medicationID: String,
        injectedAt: Date,
        siteRaw: String,
        note: String?,
        createdAt: Date
    ) {
        self.id = id
        self.medicationID = medicationID
        self.injectedAt = injectedAt
        self.siteRaw = siteRaw
        self.note = note
        self.createdAt = createdAt
    }
}

// MARK: - ModelContainer factories

public extension GLP1LocalStore {
    /// Production initializer: persistent SQLite under `Application
    /// Support/HealthLog/GLP1/glp1.sqlite`, no CloudKit. Mirrors the
    /// `OutboxStore.makePersistent` pattern (ADR-011/012).
    static func makePersistent() throws -> ModelContainer {
        let storeURL = try persistentStoreURL()
        let schema = Schema(versionedSchema: GLP1SchemaV1.self)
        let config = ModelConfiguration(
            "HealthLogGLP1",
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
    /// `OutboxStore.makeInMemory`.
    static func makeInMemory() throws -> ModelContainer {
        let schema = Schema(versionedSchema: GLP1SchemaV1.self)
        let config = ModelConfiguration(
            "HealthLogGLP1.test",
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
        let dir = appSupport.appendingPathComponent("HealthLog/GLP1", isDirectory: true)
        try SensitiveDataBackupExclusion.prepareDirectory(at: dir, fileManager: fm)
        return dir.appendingPathComponent("glp1.sqlite")
    }

    /// Best-effort file-protection (Outbox-store pattern). Same rationale
    /// as ADR-012 — the data is sensitive (medical context) but must be
    /// readable when the device is locked since reminder triggers and
    /// background-refresh tasks may touch it.
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
