import Foundation
import SwiftData

/// Per-Tag-Last-Posted-Value-Cache fuer den HK-STATS-Pfad. Persistiert
/// `(ownerUserID, hkIdentifier, dayKey) → (lastPostedValue, serverMeasurementId?)`
/// damit late-Watch-Sync-Korrekturen erkennen koennen, ob ein neuer Tagestotal
/// vom zuletzt gesendeten abweicht — wenn ja, schickt der Caller denselben
/// Batch-Entry mit derselben stabilen `stats:<type>:<day>`-`externalId` erneut,
/// was die deployte Route als Upsert (`updated`) verbucht (siehe
/// `08-locked-contracts.md` §12).
///
/// **Phase 07 / Plan 07-04 — owner-partitioniert.** Der Schluessel traegt den
/// Account. Ohne ihn war der Cache installationsweit: Account B las den
/// `lastPostedValue`, den Account A geschrieben hatte, hielt den Tag fuer
/// konvergiert und postete ihn nie — Bs Tagestotal fehlte auf dem Server, und
/// ein Sweep unter B konnte As Zeilen ueberschreiben. Legacy-Rows ohne Owner
/// werden weder geloescht noch adoptiert, sondern quarantaeniert.
///
/// **Storage:** SwiftData mit eigenem `ModelContainer` unter
/// `Application Support/HealthLog/HKStats/hkstats.sqlite`. Reasoning:
///
/// 1. **Restart-Survival.** UserDefaults wuerde reichen, aber ein
///    Outbox-Replay-Pfad nach Cold-Start wuerde dann die Last-Posted-
///    Values verlieren und alle Tage neu POSTen — server-side duplicate
///    aber unnoetiger Traffic + Idempotency-Key-Konsum.
/// 2. **Strukturiertes Predicate-Querying.** Wir wollen "alle Tage in
///    den letzten 7 Tagen" effizient holen koennen — SwiftData-Predicate
///    ist klarer als ein manuell-encoded UserDefaults-Dictionary.
/// 3. **Mirrors SWR-Cache-Pattern.** Gleicher `@ModelActor`-Aufbau wie
///    `SWRCache` — vertraut fuer Maintainer, gleiche Test-Hooks
///    (`makeInMemory()`).
///
/// `cloudKitDatabase: .none` + `completeUntilFirstUserAuthentication` per
/// ADR-011/012 (gleich wie Outbox).
@ModelActor
public actor HealthKitDailyStatsCache {
    /// Holt einen Eintrag fuer `(owner, hkIdentifier, dayKey)`. nil = dieser
    /// Account hat den Tag noch nie gepostet ⟹ Caller schickt neuen POST.
    ///
    /// Ein ownerloser Legacy-Row ist fuer JEDEN benannten Account unsichtbar.
    /// Das ist der Kern der Partitionierung: die naechste Session erbt keinen
    /// `lastPostedValue`, den sie nicht selbst geschrieben hat — sie postet den
    /// Tag neu, und der Server faltet den Upsert auf der stabilen `stats:`-Id.
    public func read(
        ownerUserID: String,
        hkIdentifier: String,
        dayKey: String
    ) -> HealthKitDailyStatsCacheEntry? {
        guard let owner = Self.canonicalOwner(ownerUserID) else { return nil }
        let key = Self.compoundKey(ownerUserID: owner, hkIdentifier: hkIdentifier, dayKey: dayKey)
        return entry(forCompoundKey: key)
    }

    /// Schreibt oder aktualisiert einen Eintrag. Idempotent auf
    /// `(owner, hkIdentifier, dayKey)` — gleicher Schluessel wird upserted.
    ///
    /// Der Write ist erst dann Fortschritt, wenn ein Read-Back denselben Wert
    /// zurueckliefert (dieselbe Regel, die `DurableHealthCursorStore` fuer
    /// Cursor faehrt): ein verlorener Write, der als Erfolg gilt, laesst den
    /// naechsten Sweep glauben, der Tag sei schon konvergiert.
    public func write(
        ownerUserID: String,
        hkIdentifier: String,
        dayKey: String,
        lastPostedValue: Double,
        serverMeasurementId: String? = nil,
        at now: Date = .now
    ) throws {
        guard let owner = Self.canonicalOwner(ownerUserID) else {
            throw HealthKitDailyStatsCacheError.unownedWriteRefused
        }
        let key = Self.compoundKey(ownerUserID: owner, hkIdentifier: hkIdentifier, dayKey: dayKey)
        let descriptor = FetchDescriptor<HealthKitDailyStatsCacheRow>(
            predicate: #Predicate { row in row.compoundKey == key }
        )
        if let row = try modelContext.fetch(descriptor).first {
            row.lastPostedValue = lastPostedValue
            // Server-Id nur ueberschreiben wenn der Caller einen liefert; ein
            // POST-Pfad nach late-watch-sync sollte den initialen Id-Anchor
            // nicht ungewollt verlieren.
            if let serverMeasurementId {
                row.serverMeasurementId = serverMeasurementId
            }
            row.updatedAt = now
        } else {
            modelContext.insert(HealthKitDailyStatsCacheRow(
                ownerUserID: owner,
                hkIdentifier: hkIdentifier,
                dayKey: dayKey,
                lastPostedValue: lastPostedValue,
                serverMeasurementId: serverMeasurementId,
                updatedAt: now
            ))
        }
        try modelContext.save()

        guard let readBack = entry(forCompoundKey: key), readBack.lastPostedValue == lastPostedValue else {
            throw HealthKitDailyStatsCacheError.readBackFailed
        }
    }

    /// Entscheidung-Helper: gibt zurueck welche Aktion fuer einen frisch
    /// aggregierten HK-Statistics-Wert noetig ist. Zwei-Wege-Logik: gleicher
    /// Wert im *eigenen* Cache → skip, sonst Upsert auf der stabilen
    /// `stats:<type>:<day>`-Id.
    public func plan(
        ownerUserID: String,
        for row: HealthKitDailyStatRow
    ) -> HealthKitDailyStatsCacheAction {
        guard let existing = read(
            ownerUserID: ownerUserID,
            hkIdentifier: row.hkIdentifier,
            dayKey: row.dayKey
        ) else {
            return .post(row: row)
        }
        // Strict equality reicht; HK-Statistics-Werte sind ganzzahlig (Steps/Flights)
        // oder server-ranged (kcal/m/min) wo wir kein epsilon-Fuzz brauchen — wenn
        // sich der Tagestotal um 0.001 kcal aendert ist das real-world wertfrei und
        // der Skip ist korrekt.
        if existing.lastPostedValue == row.value {
            return .skip(reason: "lastPostedValueMatches")
        }
        // Late-Watch-Sync: der Tagestotal hat sich geaendert. Der deployte Server
        // behandelt `stats:<type>:<day>` als mutable Upsert (`updated`), also ist
        // der Re-POST derselben stabilen Id die Korrektur — kein PATCH auf eine
        // Row-Id, die dieser Pfad nie besessen hat.
        return .upsert(row: row)
    }

    /// Sweep der Rows EINES Owners, die aelter als `maxAge` sind — der Cache
    /// braucht keine multi-month-Historie. 90-Tage-Window deckt den
    /// Daily-Backfill-Range + Power-User die ein paar Wochen offline waren ab;
    /// alles aeltere ist server-state-authoritativ.
    ///
    /// Owner-gebunden, weil ein altersbasierter Sweep sonst waehrend Account B
    /// die Rows von Account A loeschen wuerde — eine Mutation an fremdem State,
    /// nur langsamer.
    @discardableResult
    public func sweepOlderThan(
        _ maxAge: TimeInterval,
        ownerUserID: String,
        now: Date = .now
    ) throws -> Int {
        guard let owner = Self.canonicalOwner(ownerUserID) else { return 0 }
        let threshold = now.addingTimeInterval(-maxAge)
        let descriptor = FetchDescriptor<HealthKitDailyStatsCacheRow>(
            predicate: #Predicate { row in
                row.ownerUserID == owner && row.updatedAt < threshold
            }
        )
        let rows = try modelContext.fetch(descriptor)
        for row in rows {
            modelContext.delete(row)
        }
        if !rows.isEmpty {
            try modelContext.save()
        }
        return rows.count
    }

    /// Logout/Account-Delete Sweep fuer GENAU einen Account. Nach Logout darf
    /// die naechste User-Session keine alten Last-Posted-Values sehen — und die
    /// Rows der anderen Accounts auf diesem Geraet bleiben unangetastet.
    public func clearAll(ownerUserID: String) throws {
        guard let owner = Self.canonicalOwner(ownerUserID) else {
            throw HealthKitDailyStatsCacheError.unownedWriteRefused
        }
        let descriptor = FetchDescriptor<HealthKitDailyStatsCacheRow>(
            predicate: #Predicate { row in row.ownerUserID == owner }
        )
        for row in try modelContext.fetch(descriptor) {
            modelContext.delete(row)
        }
        try modelContext.save()
    }

    /// Anzahl Eintraege eines Owners — Test-introspection + Diagnostics.
    public func count(ownerUserID: String) throws -> Int {
        guard let owner = Self.canonicalOwner(ownerUserID) else { return 0 }
        return try modelContext.fetchCount(
            FetchDescriptor<HealthKitDailyStatsCacheRow>(
                predicate: #Predicate { row in row.ownerUserID == owner }
            )
        )
    }

    /// Anzahl aller Rows, unabhaengig vom Owner — inklusive der quarantaenierten
    /// ownerlosen Legacy-Rows. Nur Introspection; kein Pfad liest daraus einen
    /// Wert in eine Partition.
    public func totalRowCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<HealthKitDailyStatsCacheRow>())
    }

    /// Wie viele Rows aus der Zeit vor der Owner-Partitionierung stammen.
    ///
    /// Diese Rows werden **nicht** geloescht und **nicht** umetikettiert: sie
    /// sind PHI-abgeleitet (Tagestotale) und dieser Build kann nicht sagen, wem
    /// sie gehoeren. Sie sind fuer jeden benannten Account unsichtbar, also
    /// replayt der erste Sweep nach dem Update die betroffenen Tage einmal neu
    /// — was der Server auf der stabilen `stats:`-Id als Upsert faltet.
    public func quarantinedLegacyRowCount() throws -> Int {
        try modelContext.fetchCount(
            FetchDescriptor<HealthKitDailyStatsCacheRow>(
                predicate: #Predicate { row in row.ownerUserID == nil }
            )
        )
    }

    /// Test seam: fabricates a row in the **pre-partition** shape, i.e. exactly
    /// what the lightweight migration leaves behind for a store written before
    /// this plan. Internal, and the only writer of an ownerless row anywhere —
    /// production has no path that produces one.
    func insertLegacyRowForTesting(
        hkIdentifier: String,
        dayKey: String,
        lastPostedValue: Double,
        serverMeasurementId: String? = nil,
        at now: Date = .now
    ) throws {
        modelContext.insert(HealthKitDailyStatsCacheRow(
            ownerUserID: nil,
            hkIdentifier: hkIdentifier,
            dayKey: dayKey,
            lastPostedValue: lastPostedValue,
            serverMeasurementId: serverMeasurementId,
            updatedAt: now
        ))
        try modelContext.save()
    }

    // MARK: - Internals

    private func entry(forCompoundKey key: String) -> HealthKitDailyStatsCacheEntry? {
        let descriptor = FetchDescriptor<HealthKitDailyStatsCacheRow>(
            predicate: #Predicate { row in row.compoundKey == key }
        )
        guard let row = try? modelContext.fetch(descriptor).first else { return nil }
        return HealthKitDailyStatsCacheEntry(
            ownerUserID: row.ownerUserID,
            hkIdentifier: row.hkIdentifier,
            dayKey: row.dayKey,
            lastPostedValue: row.lastPostedValue,
            serverMeasurementId: row.serverMeasurementId,
            updatedAt: row.updatedAt
        )
    }

    /// `nil` fuer einen leeren/whitespace-Owner. Fail-closed: ohne benannten
    /// Account gibt es keine Partition, in die geschrieben werden duerfte.
    static func canonicalOwner(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Der Unique-Index-Schluessel einer owner-partitionierten Row.
    ///
    /// Drei Segmente. Ein Legacy-Row aus der Zeit vor der Partitionierung hat
    /// zwei (`<hkIdentifier>|<dayKey>`), kann also nie mit einer owner-gebundenen
    /// Row kollidieren — genau deshalb bleibt er unangetastet auf der Platte
    /// liegen statt umgeschrieben zu werden.
    static func compoundKey(ownerUserID: String, hkIdentifier: String, dayKey: String) -> String {
        "\(ownerUserID)|\(hkIdentifier)|\(dayKey)"
    }
}

/// Fehler des Daily-Stats-Caches. Traegt weder Owner noch Wert.
public enum HealthKitDailyStatsCacheError: Error, Sendable, Equatable {
    /// Es wurde ohne benannten Account geschrieben. Es gibt keine Partition, in
    /// die das gehoeren koennte.
    case unownedWriteRefused
    /// Der Write hat `save()` ueberlebt, aber ein Read-Back liefert ihn nicht
    /// zurueck. Der Caller darf den Tag NICHT als konvergiert behandeln.
    case readBackFailed
}

// MARK: - Sendable-Read-Boundary

/// Sendable-DTO fuer Reads aus dem Cache. Das `@Model` darf den Actor
/// nicht verlassen (PersistentModel-Threading) — der Reader liefert den
/// reinen Value-Struct.
public struct HealthKitDailyStatsCacheEntry: Sendable, Equatable {
    /// `nil` nur fuer eine quarantaenierte Legacy-Row aus der Zeit vor der
    /// Owner-Partitionierung. Kein `read(ownerUserID:…)` liefert so eine Row je
    /// zurueck; das Feld existiert fuer Diagnostics.
    public let ownerUserID: String?
    public let hkIdentifier: String
    public let dayKey: String
    public let lastPostedValue: Double
    public let serverMeasurementId: String?
    public let updatedAt: Date

    public init(
        ownerUserID: String? = nil,
        hkIdentifier: String,
        dayKey: String,
        lastPostedValue: Double,
        serverMeasurementId: String? = nil,
        updatedAt: Date = .now
    ) {
        self.ownerUserID = ownerUserID
        self.hkIdentifier = hkIdentifier
        self.dayKey = dayKey
        self.lastPostedValue = lastPostedValue
        self.serverMeasurementId = serverMeasurementId
        self.updatedAt = updatedAt
    }
}

/// Action-Plan fuer einen neuen Statistics-Run.
///
/// **Phase 07 / Plan 07-04.** Der `patch`-Arm ist entfallen. Er verlangte eine
/// Server-Row-Id, die dieser Pfad nie besass: `postDailyStat` gab immer `nil`
/// zurueck, also wurde `serverMeasurementId` in Produktion nie geschrieben und
/// der Arm nie erreicht. Die deployte Route behandelt `stats:<type>:<day>` als
/// mutable Upsert, also ist der Re-POST derselben stabilen Id die Korrektur —
/// und sie kommt als `updated` terminal zurueck statt als `duplicate`-No-op.
public enum HealthKitDailyStatsCacheAction: Sendable, Equatable {
    /// Erst-Post — kein Cache-Hit fuer diesen Account. Caller schickt den
    /// Batch-Entry mit `externalId = row.externalId`.
    case post(row: HealthKitDailyStatRow)
    /// Tagestotal hat sich geaendert. Caller schickt denselben Batch-Entry mit
    /// derselben stabilen `externalId`; der Server upserted.
    case upsert(row: HealthKitDailyStatRow)
    /// Kein Update noetig (Wert hat sich nicht geaendert).
    case skip(reason: String)
}

// MARK: - ModelContainer factories

public extension HealthKitDailyStatsCache {
    /// Synchronous production factory. Tries the persistent SQLite store and
    /// falls back to a non-trapping in-memory store (logged warning) so a
    /// corrupt cache file never crashes launch — mirrors the Outbox / SWRCache
    /// recovery ladders. In-memory loses the last-posted-values every relaunch
    /// (extra HK queries), which is worth post-mortem triage but not a crash.
    /// **Phase 07 / Plan 07-04 — die Leiter hat jetzt eine Sprosse mehr.**
    /// Zwischen "persistent" und "in-memory" liegt *beiseitelegen*: schlaegt der
    /// Open fehl (etwa weil ein aelterer Build den V2-Store mit dem V1-Schema
    /// oeffnet), wird die Store-Datei umbenannt und ein frischer persistenter
    /// Store angelegt. Nichts wird geloescht und nichts zurueckgesetzt — die
    /// alten Bytes bleiben unter `hkstats-quarantined-<epoch>.sqlite` liegen,
    /// und Restart-Survival ueberlebt einen Schema-Konflikt.
    static func makeWithRecovery() -> HealthKitDailyStatsCache {
        do {
            return try HealthKitDailyStatsCache(modelContainer: makePersistent())
        } catch {
            HLLog.healthKit
                .warning(
                    "HK-STATS persistent cache unavailable: \(error.localizedDescription, privacy: .public)"
                )
        }
        do {
            try quarantinePersistentStore()
            let container = try makePersistent()
            HLLog.healthKit.warning("HK-STATS store moved aside; a fresh persistent store was opened")
            return HealthKitDailyStatsCache(modelContainer: container)
        } catch {
            HLLog.healthKit
                .warning(
                    "HK-STATS quarantine/reopen failed, falling back to in-memory: \(error.localizedDescription, privacy: .public)"
                )
            let container = ModelContainerRecovery.recoveredInMemoryContainer(
                log: HLLog.healthKit,
                subsystem: "HKStats",
                build: HealthKitDailyStatsCache.makeInMemory
            )
            return HealthKitDailyStatsCache(modelContainer: container)
        }
    }

    /// Legt den bestehenden Store (inkl. `-wal` / `-shm`) beiseite statt ihn zu
    /// loeschen. Idempotent genug: der Zeitstempel im Namen macht jede Runde
    /// eindeutig.
    static func quarantinePersistentStore(now: Date = .now) throws {
        let fm = FileManager.default
        let storeURL = try persistentStoreURL()
        let stamp = String(Int(now.timeIntervalSince1970))
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: storeURL.path + suffix)
            guard fm.fileExists(atPath: source.path) else { continue }
            let destination = storeURL
                .deletingLastPathComponent()
                .appendingPathComponent("hkstats-quarantined-\(stamp).sqlite\(suffix)", isDirectory: false)
            try fm.moveItem(at: source, to: destination)
        }
    }

    /// Detached-task variant of `makeWithRecovery()`. Schedules the SwiftData
    /// `ModelContainer` open on a `.userInitiated` detached task so the
    /// ~30-80 ms cold open no longer blocks the launch tick (audit P-1).
    /// Consumed by `HealthKitStatisticsSyncCoordinator.init(cacheTask:)`, which
    /// resolves it lazily on the first sync / sweep. Unlike the Outbox, the
    /// stats cache has no `BGTaskScheduler` coupling.
    static func makeWithRecoveryTask() -> Task<HealthKitDailyStatsCache, Never> {
        Task.detached(priority: .userInitiated) {
            HealthKitDailyStatsCache.makeWithRecovery()
        }
    }

    /// Persistent-SQLite unter `Application Support/HealthLog/HKStats/hkstats.sqlite`.
    /// `cloudKitDatabase: .none`, `completeUntilFirstUserAuthentication` per
    /// ADR-011/012.
    static func makePersistent() throws -> ModelContainer {
        let storeURL = try persistentStoreURL()
        let schema = Schema(versionedSchema: HealthKitDailyStatsCacheSchemaV2.self)
        let config = ModelConfiguration(
            "HealthLogHKStats",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: schema,
            migrationPlan: HealthKitDailyStatsCacheMigrationPlan.self,
            configurations: [config]
        )
        try? applyFileProtection(to: storeURL)
        return container
    }

    /// In-Memory-Container fuer Unit-Tests — kein I/O.
    static func makeInMemory() throws -> ModelContainer {
        let schema = Schema(versionedSchema: HealthKitDailyStatsCacheSchemaV2.self)
        let config = ModelConfiguration(
            "HealthLogHKStats.test",
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: HealthKitDailyStatsCacheMigrationPlan.self,
            configurations: [config]
        )
    }

    /// Standort-Helper. Sibling zum Outbox- + Cache-SQLite.
    static func persistentStoreURL() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport
            .appendingPathComponent("HealthLog", isDirectory: true)
            .appendingPathComponent("HKStats", isDirectory: true)
        try SensitiveDataBackupExclusion.prepareDirectory(at: dir, fileManager: fm)
        return dir.appendingPathComponent("hkstats.sqlite", isDirectory: false)
    }

    /// `.completeUntilFirstUserAuthentication`-File-Protection. Idempotent.
    static func applyFileProtection(to url: URL) throws {
        try (url as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication,
            forKey: .fileProtectionKey
        )
    }
}
