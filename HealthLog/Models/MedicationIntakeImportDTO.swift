import Foundation

// CU-18 — Medikamenten-Einnahme-Import: Kickoff + Job-Status.
//
// Routen (Server v1.33.0, Shapes belegt in
// `.planning/parity/WIRE-SHAPES-v134.md` §1 gegen den Server-Quellcode):
//
// - `POST /api/medications/{id}/intake/import` → `202` mit
//   ``MedicationIntakeImportKickoffDTO`` (`{ jobId, status, statusUrl }`).
//   `statusUrl` ist ein RELATIVER Pfad und soll benutzt werden, statt ihn
//   client-seitig zusammenzubauen — so kommuniziert der kontoweite Zwilling
//   `POST /api/medications/intake/dose-history-import` seinen abweichenden
//   Status-Pfad.
// - `GET /api/medications/{id}/intake/import/{jobId}/status` →
//   ``MedicationIntakeImportStatusDTO``. Der kontoweite Zwilling
//   `GET /api/medications/intake/dose-history-import/{jobId}/status` liefert
//   dieselbe Shape durch denselben Server-Helfer.
//
// Server-Quellen: `src/lib/medications/intake-import-job-status.ts` (Projektion)
// und `src/lib/jobs/medication-intake-import.ts` (Progress-/Result-Typen).
//
// **Decode-Doktrin (dreifach tolerant):**
//
// 1. `status` ist server-seitig ein FREIER String (Prisma-Spalte
//    `String @default("queued")`, TS-Typ `string`) — kein Enum erzwingt die
//    vier heutigen Werte. Wir halten den Rohwert und typisieren nur lesend;
//    ein unbekanntes Literal gilt als "läuft noch", nicht als Fehler.
// 2. `reason` ist ein **String**, kein geschlossenes Enum. Die Route steht
//    (zum Tag v1.34.2) nicht in der OpenAPI, die 16 heute bekannten Literale
//    sind in `MedicationIntakeImportSkipReasons.known` nur zur Dokumentation
//    gepinnt — sie sind **kein Wächter**: ein siebzehntes Literal decodiert
//    und zählt weiter mit.
// 3. `progress` reicht der Server ungeprüft roh durch (`Prisma.JsonValue`,
//    Spalten-Default `"{}"`). Jedes Feld ist deshalb optional bzw. defaulted,
//    und ein nicht-objektiger Blob degradiert zu `nil` statt zu werfen.
//
// **`status == "done"` garantiert NICHT `result != nil`.** Die serverseitige
// Allowlist-Projektion (`projectMedicationImportResult`) verwirft einen
// unstimmigen Blob still und gibt `null` zurück. Ein fertiger Job ohne
// verwertbares Ergebnis ist "fertig, Details nicht darstellbar" — weder Fehler
// noch Grund weiterzupollen. Genau dafür existiert
// ``MedicationIntakeImportOutcome/finishedWithoutDetails``.
//
// **Kein Import-Screen auf iOS (Stand CU-18):** die App startet heute keinen
// Medikamenten-Einnahme-Import. Diese DTOs pinnen den Vertrag samt der drei
// Toleranzen, damit die Fläche, die ihn adoptiert, keine der Fallen neu
// entdecken muss.

// MARK: - Kickoff (POST → 202)

/// `202`-Payload des Kickoffs.
public struct MedicationIntakeImportKickoffDTO: Codable, Sendable, Equatable {
    public let jobId: String
    /// Immer `"queued"` im heutigen Server-Code; roh gehalten wie überall auf
    /// dieser Route.
    public let status: String
    /// Relativer Status-Pfad, z. B.
    /// `/api/medications/{id}/intake/import/{jobId}/status`. Verbatim benutzen.
    public let statusUrl: String?

    public init(jobId: String, status: String, statusUrl: String? = nil) {
        self.jobId = jobId
        self.status = status
        self.statusUrl = statusUrl
    }
}

// MARK: - Job-Phase

/// Die vier Literale, die der Worker heute schreibt. Bewusst KEIN
/// `Decodable`-Conformance auf der Wire-Ebene: der Status wird als String
/// dekodiert und erst hier lesend typisiert, damit ein fünftes Server-Literal
/// den Poll nicht kippt.
public enum MedicationIntakeImportPhase: String, Sendable, Equatable, CaseIterable {
    case queued
    case running
    case done
    case failed
}

// MARK: - Skip-Gründe

/// Dokumentation der 16 heute bekannten `reason`-Literale
/// (`MEDICATION_IMPORT_SKIP_REASONS`, `medication-intake-import.ts:87-104`).
///
/// Bewusst eine String-Menge und kein Enum: der Decoder darf an einem neuen
/// Literal nicht scheitern, und eine erfundene Enum-Modellierung würde genau
/// das nahelegen. Wert der Konstante ist die Regressionsprobe — ein Test
/// vergleicht sie gegen die Server-Liste.
public enum MedicationIntakeImportSkipReasons {
    /// Reihenfolge wie im Server-Quellcode (Worker-Gründe zuerst, danach die
    /// beim Parsen der Exportdatei entschiedenen).
    public static let known: [String] = [
        "duplicate_in_file",
        "already_recorded",
        "medication_not_found",
        "medication_ambiguous",
        "medication_is_mirrored",
        "status_no_dose_information",
        "status_reminder_event",
        "status_notification_not_sent",
        "status_unknown",
        "missing_timestamp",
        "missing_timezone_offset",
        "unreadable_timestamp",
        "implausible_timestamp",
        "missing_medication",
        "unreadable_dosage",
        "unreadable_row"
    ]
}

/// Ein Grund mit seiner Anzahl (`{ reason, count }`). Der Server liefert nur
/// Gründe mit `count > 0`, absteigend nach Anzahl, bei Gleichstand alphabetisch.
public struct MedicationImportSkipGroupDTO: Codable, Sendable, Equatable {
    /// Roh gehalten — siehe ``MedicationIntakeImportSkipReasons``.
    public let reason: String
    public let count: Int

    public init(reason: String, count: Int) {
        self.reason = reason
        self.count = count
    }

    private enum CodingKeys: String, CodingKey {
        case reason, count
    }

    /// Fehlende Felder werden geleert statt geraten: ein Grund ohne Literal
    /// bekommt `""` (die Fläche zeigt dann keinen Grund an), kein erfundenes
    /// `"unreadable_row"`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
    }
}

/// Eine beschnittene, redigierte Quellzeilen-Angabe (`{ line, reason }`).
/// `line` ist der 1-basierte Zeilen-Ordinal der Exportdatei; der Zeileninhalt
/// selbst wird server-seitig nie gespeichert. Gedeckelt auf 200 Einträge,
/// alles darüber zählt nur noch `skippedDetailsOmitted`.
public struct MedicationImportSkipDetailDTO: Codable, Sendable, Equatable, Identifiable {
    public let line: Int
    public let reason: String

    public var id: Int {
        line
    }

    public init(line: Int, reason: String) {
        self.line = line
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case line, reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        line = try c.decodeIfPresent(Int.self, forKey: .line) ?? 0
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }
}

// MARK: - Progress (Live-Schnappschuss)

/// `progress` des laufenden Jobs (`MedicationImportProgress`). Beide heutigen
/// Erzeugerrouten schreiben das Objekt bereits bei der Zulassung vollständig
/// (`processed: 0, total: N`), aber der Status-Helfer validiert nichts und die
/// Spalte hat `@default("{}")` — Altbestandsjobs liefern das leere Objekt.
/// Deshalb ist hier jedes Feld defaulted.
public struct MedicationImportProgressDTO: Codable, Sendable, Equatable {
    public let processed: Int
    public let total: Int
    public let imported: Int
    /// Zähler je Grund. **Ein Grund ohne Skips fehlt, er steht nicht als `0`
    /// drin** (der Server überspringt Nullzuwächse). Schlüssel roh gehalten.
    public let skippedByReason: [String: Int]
    /// Optional; fehlt auf Alt-Jobs. `nil` ist NICHT dasselbe wie `[]`.
    public let skipDetails: [MedicationImportSkipDetailDTO]?
    /// Optional; tritt gemeinsam mit ``skipDetails`` auf.
    public let skippedDetailsOmitted: Int?
    /// Lokale Kalendertage `YYYY-MM-DD`, dedupliziert, in Einfügereihenfolge.
    public let touchedDays: [String]
    public let rollupProcessed: Int

    public init(
        processed: Int = 0,
        total: Int = 0,
        imported: Int = 0,
        skippedByReason: [String: Int] = [:],
        skipDetails: [MedicationImportSkipDetailDTO]? = nil,
        skippedDetailsOmitted: Int? = nil,
        touchedDays: [String] = [],
        rollupProcessed: Int = 0
    ) {
        self.processed = processed
        self.total = total
        self.imported = imported
        self.skippedByReason = skippedByReason
        self.skipDetails = skipDetails
        self.skippedDetailsOmitted = skippedDetailsOmitted
        self.touchedDays = touchedDays
        self.rollupProcessed = rollupProcessed
    }

    private enum CodingKeys: String, CodingKey {
        case processed, total, imported, skippedByReason
        case skipDetails, skippedDetailsOmitted, touchedDays, rollupProcessed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        processed = try c.decodeIfPresent(Int.self, forKey: .processed) ?? 0
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        imported = try c.decodeIfPresent(Int.self, forKey: .imported) ?? 0
        skippedByReason = try c.decodeIfPresent([String: Int].self, forKey: .skippedByReason) ?? [:]
        skipDetails = try c.decodeIfPresent([MedicationImportSkipDetailDTO].self, forKey: .skipDetails)
        skippedDetailsOmitted = try c.decodeIfPresent(Int.self, forKey: .skippedDetailsOmitted)
        touchedDays = try c.decodeIfPresent([String].self, forKey: .touchedDays) ?? []
        rollupProcessed = try c.decodeIfPresent(Int.self, forKey: .rollupProcessed) ?? 0
    }

    /// Anteil `processed / total` als 0…1, `nil` solange `total == 0` (frisch
    /// zugelassener Leerlauf / `{}`-Altbestand). Bewusst kein `0`-Default: ein
    /// erfundener Nullbalken behauptet Fortschrittswissen, das wir nicht haben.
    public var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1.0, Double(processed) / Double(total))
    }
}

// MARK: - Result (terminales Ergebnis)

/// `result` eines fertigen Jobs (`MedicationImportResult`). Existiert erst nach
/// der Finalisierung — und auch dann nur, wenn der gespeicherte Blob die
/// server-seitige Allowlist besteht.
public struct MedicationImportResultDTO: Codable, Sendable, Equatable {
    public let imported: Int
    /// Alle Einträge, aus denen keine Zeile wurde.
    public let skipped: Int
    /// Nur Gründe mit `count > 0`; bei einem Lauf ohne Skips ein LEERES Array,
    /// nicht `null`.
    public let skipReasons: [MedicationImportSkipGroupDTO]
    /// Optional; `nil` heisst "nicht mitgeliefert", nicht "keine".
    public let skipDetails: [MedicationImportSkipDetailDTO]?
    public let skippedDetailsOmitted: Int?

    public init(
        imported: Int = 0,
        skipped: Int = 0,
        skipReasons: [MedicationImportSkipGroupDTO] = [],
        skipDetails: [MedicationImportSkipDetailDTO]? = nil,
        skippedDetailsOmitted: Int? = nil
    ) {
        self.imported = imported
        self.skipped = skipped
        self.skipReasons = skipReasons
        self.skipDetails = skipDetails
        self.skippedDetailsOmitted = skippedDetailsOmitted
    }

    private enum CodingKeys: String, CodingKey {
        case imported, skipped, skipReasons, skipDetails, skippedDetailsOmitted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imported = try c.decodeIfPresent(Int.self, forKey: .imported) ?? 0
        skipped = try c.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
        skipReasons = try c.decodeIfPresent([MedicationImportSkipGroupDTO].self, forKey: .skipReasons) ?? []
        skipDetails = try c.decodeIfPresent([MedicationImportSkipDetailDTO].self, forKey: .skipDetails)
        skippedDetailsOmitted = try c.decodeIfPresent(Int.self, forKey: .skippedDetailsOmitted)
    }

    /// `true`, wenn der Lauf nichts übersprungen hat — der Fall, in dem eine
    /// Fläche die Gründe-Liste ganz weglassen darf.
    public var isClean: Bool {
        skipped == 0 && skipReasons.isEmpty
    }
}

// MARK: - Was die Fläche anzeigen darf

/// Ehrlicher Anzeige-Zustand eines Jobs. Trennt bewusst "fertig mit Details"
/// von "fertig ohne verwertbares Ergebnis" — der Fall, den die OpenAPI
/// verschweigt und den `status == "done"` allein nicht ausschliesst.
public enum MedicationIntakeImportOutcome: Sendable, Equatable {
    /// Eingereiht, laufend — oder ein unbekanntes Status-Literal, das wir
    /// bewusst als "läuft noch" lesen statt als Fehler.
    case running
    /// Fertig, Ergebnis liegt vor.
    case finished(MedicationImportResultDTO)
    /// Fertig, aber ohne darstellbares Ergebnis (Allowlist-Projektion hat den
    /// Blob verworfen). Kein Fehler und kein Grund weiterzupollen.
    case finishedWithoutDetails
    /// Terminal gescheitert.
    case failed
}

// MARK: - Status (GET)

/// Antwort-Shape von
/// `GET /api/medications/{id}/intake/import/{jobId}/status`.
public struct MedicationIntakeImportStatusDTO: Codable, Sendable, Equatable {
    public let jobId: String
    /// Roher Status-String — typisiert lesbar über ``phase``.
    public let statusRaw: String
    /// `nil`, wenn der Blob kein dekodierbares Objekt war (`{}` decodiert
    /// dagegen zu einem all-Null-Progress).
    public let progress: MedicationImportProgressDTO?
    /// `nil` bei `queued` / `running`, bei `failed` — UND bei `done`, wenn die
    /// server-seitige Allowlist den gespeicherten Blob verworfen hat.
    public let result: MedicationImportResultDTO?
    /// Trägt server-seitig KEINE Ursacheninformation (der Sanitiser gibt immer
    /// denselben konstanten String zurück). Nicht anzeigen — eine eigene
    /// lokalisierte Meldung an ``MedicationIntakeImportOutcome/failed`` hängen.
    public let failureReason: String?
    public let createdAt: Date?
    public let startedAt: Date?
    public let completedAt: Date?

    public init(
        jobId: String,
        statusRaw: String,
        progress: MedicationImportProgressDTO? = nil,
        result: MedicationImportResultDTO? = nil,
        failureReason: String? = nil,
        createdAt: Date? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.jobId = jobId
        self.statusRaw = statusRaw
        self.progress = progress
        self.result = result
        self.failureReason = failureReason
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    private enum CodingKeys: String, CodingKey {
        case jobId
        case statusRaw = "status"
        case progress
        case result
        case failureReason
        case createdAt
        case startedAt
        case completedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try c.decode(String.self, forKey: .jobId)
        statusRaw = try c.decode(String.self, forKey: .statusRaw)
        // `progress` ist ungeprüft durchgereichtes JSON — ein nicht-objektiger
        // Blob darf den Poll nicht kippen.
        progress = try? c.decodeIfPresent(MedicationImportProgressDTO.self, forKey: .progress)
        result = try? c.decodeIfPresent(MedicationImportResultDTO.self, forKey: .result)
        failureReason = try c.decodeIfPresent(String.self, forKey: .failureReason)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
    }

    /// Typisierter Status; `nil` bei einem Literal, das iOS nicht kennt.
    public var phase: MedicationIntakeImportPhase? {
        MedicationIntakeImportPhase(rawValue: statusRaw)
    }

    /// Poll-Abbruchkriterium. Ein unbekanntes Literal ist bewusst NICHT
    /// terminal — lieber einmal zu oft pollen als einen laufenden Job als
    /// beendet melden.
    public var isTerminal: Bool {
        phase == .done || phase == .failed
    }

    /// Der Zustand, den eine Fläche rendern darf — inklusive des ehrlichen
    /// "fertig, aber ohne Ergebnis".
    public var outcome: MedicationIntakeImportOutcome {
        switch phase {
        case .failed:
            .failed
        case .done:
            result.map { .finished($0) } ?? .finishedWithoutDetails
        case .queued, .running, nil:
            .running
        }
    }
}
