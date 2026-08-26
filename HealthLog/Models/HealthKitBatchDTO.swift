import Foundation

/// Wire-Form für einen einzelnen Eintrag in `POST /api/measurements/batch`.
/// Locked Contract — siehe `08-locked-contracts.md §2.1` (`batchEntrySchema`).
///
/// **Field-Mapping** (aus `06-ios-responsibilities.md § HealthKit table`):
/// - `hkIdentifier`: Apple-HK-Konstante als String, z. B. `HKQuantityTypeIdentifierBodyMass`.
/// - `value`: Vorkonvertiert (×100 für SpO2 + BodyFat — siehe `HealthKitWireConverter`).
/// - `unit`: HK-Unit-String, z. B. `kg`, `mmHg`, `count`.
/// - `startDate`/`endDate`: ISO-8601 mit Offset.
/// - `sleepStage`: Optional Integer (`HKCategoryValueSleepAnalysis` codepoint, 0..20).
/// - `externalId`: `HKSample.uuid.uuidString` — Server-Dedup-Key.
/// - `externalSourceVersion`: Optional `HKSourceRevision.productType` o. ae. für Provenance.
/// - `deviceType`: Mapping von `HKDevice.model` (`watch|band|ring|phone|scale|other|unknown`).
public struct HealthKitBatchEntryDTO: Codable, Sendable, Equatable {
    public let hkIdentifier: String
    public let value: Double
    /// v1.19.2 (iOS #34 extension) — per-bucket MINIMUM bpm. Persisted server-side
    /// ONLY on a well-formed `stats:HKQuantityTypeIdentifierHeartRate:<bucket>` row
    /// (the 10-minute aggregated heart-rate bucket, where `value` is the bucket's
    /// AVERAGE); ignored/stored-null on every other entry. Optional so the
    /// synthesized `encodeIfPresent` OMITS the key entirely on every per-sample
    /// row — the wire shape for all non-HR-bucket entries stays byte-identical to
    /// the pre-v1.19.2 payload.
    public let valueMin: Double?
    /// v1.19.2 (iOS #34 extension) — per-bucket MAXIMUM bpm. See ``valueMin``.
    public let valueMax: Double?
    public let unit: String
    public let startDate: Date
    public let endDate: Date
    public let sleepStage: Int?
    /// W-HKREAD — the integer `HKCategoryValue` codepoint for an EVENT-class
    /// category sample (irregular-rhythm, high/low-HR, walking-steadiness,
    /// breathing-disturbance, audio-exposure). Carries the device's own
    /// verdict / severity; the server resolves it to a `rhythmClassification`
    /// via `mapAppleHealthEntry`. `nil` for every continuous reading — the
    /// server's `categoryValue` field is `.optional()`.
    public let categoryValue: Int?
    public let externalId: String
    public let externalSourceVersion: String?
    public let deviceType: HealthKitDeviceType?

    public init(
        hkIdentifier: String,
        value: Double,
        valueMin: Double? = nil,
        valueMax: Double? = nil,
        unit: String,
        startDate: Date,
        endDate: Date,
        sleepStage: Int? = nil,
        categoryValue: Int? = nil,
        externalId: String,
        externalSourceVersion: String? = nil,
        deviceType: HealthKitDeviceType? = nil
    ) {
        self.hkIdentifier = hkIdentifier
        self.value = value
        self.valueMin = valueMin
        self.valueMax = valueMax
        self.unit = unit
        self.startDate = startDate
        self.endDate = endDate
        self.sleepStage = sleepStage
        self.categoryValue = categoryValue
        self.externalId = externalId
        self.externalSourceVersion = externalSourceVersion
        self.deviceType = deviceType
    }
}

/// Body-Envelope für `POST /api/measurements/batch`.
/// Codable (statt nur Encodable) damit Tests den abgeschickten Body wieder
/// dekodieren und gegen das Erwartete asserten können.
public struct HealthKitBatchPayload: Codable, Sendable, Equatable {
    public let entries: [HealthKitBatchEntryDTO]
    /// **CU-21 (C1)** — optionales **Top-Level**-Feld (Geschwister von
    /// `entries`, nicht pro Eintrag), Server ≥ v1.32.31. Trägt den tatsächlichen
    /// Auslöser dieses Sweeps; der Server persistiert ihn und leitet daraus ab,
    /// ob dieses Telefon selbstständig liefert oder nur bei geöffneter App.
    /// `nil` ⇒ der Schlüssel wird **weggelassen** (synthetisiertes
    /// `encodeIfPresent`), die Wire-Form bleibt für Pfade ohne bekannten
    /// Auslöser byte-identisch zur Vor-CU-21-Form.
    public let syncTrigger: SyncTrigger?

    public init(entries: [HealthKitBatchEntryDTO], syncTrigger: SyncTrigger? = nil) {
        self.entries = entries
        self.syncTrigger = syncTrigger
    }
}

/// Server-Antwort: `data` von `POST /api/measurements/batch`. Per-Entry-Status-Liste
/// ist die Cursor-Advance-Quelle (siehe `08-locked-contracts.md §2.1`).
///
/// **Phase 07 / Plan 07-04.** Dieses DTO dekodiert *tolerant* — jedes Feld
/// optional-mit-Default, jedes unbekannte Statuswort als `.unknown`. Toleranz
/// ist hier ausdrücklich keine Annahme: HTTP 200 allein bewegt keinen Cursor.
/// Welche Indizes terminal sind, entscheidet ``MeasurementBatchAcceptance``
/// gegen eine explizite Per-Route-Policy.
public struct HealthKitBatchResponseDTO: Codable, Sendable, Equatable {
    public let processed: Int
    public let inserted: Int
    public let duplicates: Int
    public let skipped: [SkippedEntry]
    public let entries: [EntryResult]

    public init(processed: Int, inserted: Int, duplicates: Int, skipped: [SkippedEntry], entries: [EntryResult]) {
        self.processed = processed
        self.inserted = inserted
        self.duplicates = duplicates
        self.skipped = skipped
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case processed, inserted, duplicates, skipped, entries
    }

    /// **CU-21 (4) — tolerantes Decoding der Batch-Antwort.**
    ///
    /// Jedes Feld ist optional-mit-Default. Der Grund ist nicht Kosmetik: der
    /// Server weist seit v1.32.37 instabile `externalId`s per-Entry ab und
    /// liefert dafür einen `skipped`-Eintrag, während der Rest des Batches
    /// landet. Ein hartes Decoding, das an einem fehlenden Zählerfeld oder einem
    /// unbekannten Statuswort scheitert, würde aus dieser Teil-Ablehnung ein
    /// **komplettes** Batch-Scheitern machen — und damit genau den Retry-Loop
    /// auslösen, den der deterministische Grund nie auflösen könnte.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        processed = try c.decodeIfPresent(Int.self, forKey: .processed) ?? 0
        inserted = try c.decodeIfPresent(Int.self, forKey: .inserted) ?? 0
        duplicates = try c.decodeIfPresent(Int.self, forKey: .duplicates) ?? 0
        skipped = try c.decodeIfPresent([SkippedEntry].self, forKey: .skipped) ?? []
        entries = try c.decodeIfPresent([EntryResult].self, forKey: .entries) ?? []
    }

    public struct SkippedEntry: Codable, Sendable, Equatable {
        public let index: Int
        /// **Bewusst `String`, kein geschlossenes Enum.** Der Server erweitert
        /// die Reason-Liste laufend (`unmappable_identifier`,
        /// `value_out_of_range`, seit v1.32.37 `unstable_external_id`, …); ein
        /// Enum hier hieße, dass der nächste neue Grund den ganzen Batch beim
        /// Decoding kippt. Die Klassifizierung nach retry-fähig/terminal passiert
        /// in `HealthKitService.uploadAndDecide` gegen benannte Konstanten in
        /// ``HealthKitServerSupportConfig``.
        public let reason: String

        public init(index: Int, reason: String) {
            self.index = index
            self.reason = reason
        }

        private enum CodingKeys: String, CodingKey {
            case index, reason
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Ein Skip ohne Index ist nicht zuordenbar; `-1` fällt beim
            // Cursor-Advance durch die `indices.contains`-Prüfung.
            index = try c.decodeIfPresent(Int.self, forKey: .index) ?? -1
            reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? "unknown"
        }
    }

    public struct EntryResult: Codable, Sendable, Equatable {
        public let index: Int
        public let status: HealthKitEntryStatus
        public let reason: String?

        public init(index: Int, status: HealthKitEntryStatus, reason: String? = nil) {
            self.index = index
            self.status = status
            self.reason = reason
        }

        private enum CodingKeys: String, CodingKey {
            case index, status, reason
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            index = try c.decodeIfPresent(Int.self, forKey: .index) ?? -1
            status = try c.decodeIfPresent(HealthKitEntryStatus.self, forKey: .status) ?? .unknown
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
        }
    }
}

/// Per-Entry-Status des deployten Servers (`v1.37.12`, Revision `d21fe48`).
///
/// **Phase 07 / Plan 07-04 — tolerantes Decoding ist NICHT terminale Annahme.**
/// Dieses Enum sagt nur, welches Wort der Server geschickt hat. Ob ein Index den
/// Cursor bewegen darf, entscheidet ausschliesslich
/// ``MeasurementBatchAcceptance`` — reason-aware und pro Index. Vier Worte sind
/// dort terminal (`inserted`, `updated`, `duplicate`, und `skipped` nur mit
/// einem allowlisteten Grund), zwei halten den Cursor (`failed`, `unknown`).
public enum HealthKitEntryStatus: String, Codable, Sendable, Equatable, CaseIterable {
    /// Neue DB-Row.
    case inserted
    /// **v1.37.12** — die Row existierte und wurde *fortgeschrieben*. Der Server
    /// behandelt eine `stats:<type>:<day>`-`externalId` als mutable Upsert; ein
    /// konvergierter Tagestotal kommt genau so zurück. Terminal: der Wert steht
    /// im Server-State, ein Retry würde nichts ändern.
    case updated
    /// DB-Row existierte schon, kein Fehler. Trägt bei einem Stats-Upsert
    /// zusätzlich `reason: "superseded_in_batch"`, wenn eine spätere Zeile
    /// *desselben Requests* mit derselben stabilen ID gewonnen hat.
    case duplicate
    /// Server hat den Eintrag gesehen und bewusst nicht geschrieben. Der Grund
    /// entscheidet: nur die dokumentierte Allowlist
    /// (``MeasurementBatchAcceptance/Policy``) ist terminal.
    case skipped
    /// **v1.37.12** — der Server hat den Eintrag angenommen, ihn aber nicht
    /// persistieren können. Ausdrücklich NICHT terminal: derselbe Eintrag kann
    /// beim nächsten Versuch landen, also hält der Cursor.
    case failed
    /// **CU-21 (4)** — Auffangwert für ein Statuswort, das dieser Build noch
    /// nicht kennt. Ein neues Server-Wort darf das Decoding der ganzen Antwort
    /// nicht kippen. Es darf aber auch keinen Cursor bewegen: dieser Build kann
    /// nicht sagen, was der Server getan hat, also hält der Index.
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = HealthKitEntryStatus(rawValue: raw) ?? .unknown
    }
}

/// `HKDevice.model` → `deviceType`-Mapping. Locked Enum, siehe Server-Side
/// `deviceTypeEnum` in `src/lib/validations/measurement.ts`. Werte sind die exakten
/// Wire-Strings — Drift bricht den Source-Priority-Picker (Axis 2 — siehe
/// `08-locked-contracts.md §4`).
public enum HealthKitDeviceType: String, Codable, Sendable, CaseIterable, Equatable {
    case watch
    case band
    case ring
    case phone
    case scale
    case other
    case unknown
}
