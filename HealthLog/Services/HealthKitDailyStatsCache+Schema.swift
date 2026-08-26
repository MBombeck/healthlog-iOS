import Foundation
import SwiftData

// Phase 07 / Plan 07-04 — the versioned shape of the daily-stat cache.
//
// Split out of `HealthKitDailyStatsCache.swift` so the actor's behaviour and
// the store's schema history are separate reading tasks: V1 exists only as the
// migration's source form and is never instantiated at runtime.

// MARK: - SwiftData Model

/// Die aktive Row-Form. Alias auf die aktuelle Schema-Version, damit der
/// restliche Code (und die On-Disk-Entity-Name `HealthKitDailyStatsCacheRow`)
/// unveraendert bleibt.
public typealias HealthKitDailyStatsCacheRow = HealthKitDailyStatsCacheSchemaV2.HealthKitDailyStatsCacheRow

/// Schema-Versionierung — mirrors Cache/Outbox-Pattern.
///
/// **V1 — die Form vor der Owner-Partitionierung.** Der Typ existiert weiterhin
/// und wird von keinem Laufzeitpfad benutzt: er ist die *Quellform* der
/// Migrationsstufe. Ohne ihn haetten V1 und V2 dieselbe Checksumme und SwiftData
/// wuerde den Plan ablehnen — eine Version, die nichts beschreibt, ist keine
/// Version.
public enum HealthKitDailyStatsCacheSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [HealthKitDailyStatsCacheRow.self]
    }

    /// Unique-Index war `(hkIdentifier, dayKey)` — installationsweit, ohne
    /// Account. Genau das ist der Defekt, den V2 schliesst.
    @Model
    public final class HealthKitDailyStatsCacheRow {
        @Attribute(.unique) public var compoundKey: String
        public var hkIdentifier: String
        public var dayKey: String
        public var lastPostedValue: Double
        public var serverMeasurementId: String?
        public var updatedAt: Date

        public init(
            hkIdentifier: String,
            dayKey: String,
            lastPostedValue: Double,
            serverMeasurementId: String? = nil,
            updatedAt: Date = .now
        ) {
            self.hkIdentifier = hkIdentifier
            self.dayKey = dayKey
            self.lastPostedValue = lastPostedValue
            self.serverMeasurementId = serverMeasurementId
            self.updatedAt = updatedAt
            compoundKey = "\(hkIdentifier)|\(dayKey)"
        }
    }
}

/// **Phase 07 / Plan 07-04** — owner-partitionierter Daily-Stats-Cache.
///
/// Die einzige Schema-Aenderung gegenueber V1 ist ein zusaetzliches
/// **optionales** Attribut (`ownerUserID`). Optionale Attribute sind
/// lightweight-migrierbar: kein Backfill, kein Rewrite, keine Zeile geht
/// verloren. Bestehende Rows kommen mit `ownerUserID == nil` durch und bleiben
/// genau so liegen — quarantaeniert, nicht adoptiert.
public enum HealthKitDailyStatsCacheSchemaV2: VersionedSchema {
    public static let versionIdentifier = Schema.Version(2, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [HealthKitDailyStatsCacheRow.self]
    }

    /// SwiftData-Row fuer einen einzigen Daily-Stats-Cache-Eintrag. Unique-
    /// Index ist `(ownerUserID, hkIdentifier, dayKey)` — kann nicht direkt
    /// deklariert werden (SwiftData unterstuetzt keine
    /// compound-unique-Constraints out of the box), aber via `compoundKey` als
    /// denormierter String aufrechterhalten.
    @Model
    public final class HealthKitDailyStatsCacheRow {
        /// Denormierter `<ownerUserID>|<hkIdentifier>|<dayKey>` zum
        /// Unique-Index-Enforcement. Weder Owner-Id noch `hkIdentifier` noch
        /// `dayKey` enthalten Pipes, der Schluessel bleibt also zerlegbar.
        ///
        /// Legacy-Rows aus der Zeit vor der Owner-Partitionierung tragen
        /// weiterhin die zweisegmentige Form `<hkIdentifier>|<dayKey>` und
        /// werden **nicht** umgeschrieben.
        @Attribute(.unique) public var compoundKey: String
        /// Der Account, der diesen Tagestotal gepostet hat. Optional, damit die
        /// Migration additiv (lightweight) bleibt und bestehende Rows erhalten
        /// werden statt geloescht oder erraten zu werden. `nil` heisst genau
        /// eines: dieser Build kann die Row keinem Account zuordnen. Sie bleibt
        /// liegen und ist fuer jeden benannten Account unsichtbar.
        public var ownerUserID: String?
        public var hkIdentifier: String
        public var dayKey: String
        public var lastPostedValue: Double
        public var serverMeasurementId: String?
        public var updatedAt: Date

        public init(
            ownerUserID: String?,
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
            compoundKey = if let ownerUserID {
                HealthKitDailyStatsCache.compoundKey(
                    ownerUserID: ownerUserID,
                    hkIdentifier: hkIdentifier,
                    dayKey: dayKey
                )
            } else {
                "\(hkIdentifier)|\(dayKey)"
            }
        }
    }
}

/// Expliziter Migrationspfad V1 → V2.
///
/// Eine Lightweight-Stage: das neue Attribut ist optional, SwiftData kann sie
/// vollstaendig inferieren, und keine Zeile wird angefasst. Der Plan ist
/// trotzdem *deklariert* statt implizit, damit der Uebergang eine benannte
/// Stufe mit zwei unterscheidbaren Quell-/Zielformen ist und nicht eine
/// stillschweigende Vermutung.
///
/// **Rollback.** Ein aelterer Build oeffnet den V2-Store mit dem V1-Schema.
/// Sollte SwiftData das ablehnen, greift die Recovery-Leiter in
/// ``HealthKitDailyStatsCache/makeWithRecovery()``: der Store wird
/// **beiseitegelegt** (`hkstats-quarantined-<epoch>.sqlite`), nie geloescht und
/// nie zurueckgesetzt. Verloren geht dabei hoechstens ein Memo ueber zuletzt
/// gepostete Tagestotale; die Daten selbst liegen auf dem Server und in
/// HealthKit.
public enum HealthKitDailyStatsCacheMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [HealthKitDailyStatsCacheSchemaV1.self, HealthKitDailyStatsCacheSchemaV2.self]
    }

    public static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: HealthKitDailyStatsCacheSchemaV1.self,
                toVersion: HealthKitDailyStatsCacheSchemaV2.self
            )
        ]
    }
}
