import Foundation

/// Server-authoritative nutrient catalog code (server v1.28, `NutrientCode`).
///
/// The closed catalog is the 24 HealthKit `Dietary*` vitamin/mineral types plus
/// water and caffeine. Energy, macros (carbs/protein/fat/sugar/fiber) and
/// sodium/potassium are deliberately OUT of scope — we neither request their HK
/// read-authorization nor ever POST them here.
public enum NutrientCode: String, Codable, Sendable, CaseIterable, Equatable {
    case vitaminA = "vitamin_a"
    case thiamin
    case riboflavin
    case niacin
    case pantothenicAcid = "pantothenic_acid"
    case vitaminB6 = "vitamin_b6"
    case biotin
    case folate
    case vitaminB12 = "vitamin_b12"
    case vitaminC = "vitamin_c"
    case vitaminD = "vitamin_d"
    case vitaminE = "vitamin_e"
    case vitaminK = "vitamin_k"
    case calcium
    case iron
    case magnesium
    case phosphorus
    case zinc
    case copper
    case manganese
    case selenium
    case chromium
    case molybdenum
    case iodine
    case water
    case caffeine
}

/// One nutrient day total for `POST /api/nutrients/batch` (server v1.28,
/// `NutrientIntakeEntry`).
///
/// - `day`: `yyyy-MM-dd` in the user's current IANA timezone — the SAME day-key
///   rule as the `stats:` measurement keys (see
///   ``HealthKitStatisticsService/dayKey(for:calendar:)``).
/// - `nutrient`: the closed-catalog ``NutrientCode``.
/// - `unit`: MUST equal the catalog's canonical wire unit for the code
///   (`mg` | `ug` | `ml`) — a mismatch makes the server skip the entry
///   `unit_mismatch`. No IU conversion — we send exactly what HealthKit reports
///   in the catalog unit.
/// - `amount`: the day's cumulative-sum total in the catalog unit (≥ 0).
/// - `externalSourceVersion`: optional provenance (e.g. app/source version).
public struct NutrientIntakeEntryDTO: Codable, Sendable, Equatable {
    public let day: String
    public let nutrient: NutrientCode
    public let unit: String
    public let amount: Double
    public let externalSourceVersion: String?

    public init(
        day: String,
        nutrient: NutrientCode,
        unit: String,
        amount: Double,
        externalSourceVersion: String? = nil
    ) {
        self.day = day
        self.nutrient = nutrient
        self.unit = unit
        self.amount = amount
        self.externalSourceVersion = externalSourceVersion
    }
}

/// Body envelope for `POST /api/nutrients/batch` (`NutrientBatchRequest`).
/// Bulk day-total upsert, max 500 entries; upsert key is `(day, nutrient)` and a
/// re-post REPLACES the stored total (last-writer-wins, reported `updated`).
/// Codable (not just Encodable) so tests can round-trip the sent body.
public struct NutrientBatchRequestDTO: Codable, Sendable, Equatable {
    public let entries: [NutrientIntakeEntryDTO]

    public init(entries: [NutrientIntakeEntryDTO]) {
        self.entries = entries
    }
}

/// Per-entry ingest status (`NutrientEntryResult.status`). All three are
/// terminal — the batch itself is always `200` when the envelope parses.
public enum NutrientEntryStatus: String, Codable, Sendable, Equatable {
    case inserted
    case updated
    case skipped
}

/// `data` payload of `POST /api/nutrients/batch` (`NutrientBatchResponse`).
///
/// Per-entry failures surface as `skipped` rows (reasons `unit_mismatch` |
/// `value_out_of_range` | `day_invalid` | `upsert_failed`) — the caller LOGS +
/// DROPS them and never retries. A re-post of an existing `(day, nutrient)`
/// reports `updated` (never `duplicate`).
public struct NutrientBatchResponseDTO: Codable, Sendable, Equatable {
    public let processed: Int
    public let inserted: Int
    public let updated: Int
    public let skipped: [SkippedEntry]
    public let entries: [EntryResult]

    public init(
        processed: Int,
        inserted: Int,
        updated: Int,
        skipped: [SkippedEntry],
        entries: [EntryResult]
    ) {
        self.processed = processed
        self.inserted = inserted
        self.updated = updated
        self.skipped = skipped
        self.entries = entries
    }

    public struct SkippedEntry: Codable, Sendable, Equatable {
        public let index: Int
        public let reason: String

        public init(index: Int, reason: String) {
            self.index = index
            self.reason = reason
        }
    }

    public struct EntryResult: Codable, Sendable, Equatable {
        public let index: Int
        public let status: NutrientEntryStatus
        public let reason: String?

        public init(index: Int, status: NutrientEntryStatus, reason: String? = nil) {
            self.index = index
            self.status = status
            self.reason = reason
        }
    }
}

/// One catalog row binding a ``NutrientCode`` to its HealthKit `Dietary*`
/// quantity-type identifier and canonical wire unit. Mirrors the code↔HK↔unit
/// table in the `POST /api/nutrients/batch` endpoint description (server v1.28).
public struct NutrientCatalogItem: Sendable, Equatable {
    public let code: NutrientCode
    /// Raw HealthKit identifier string (e.g. `HKQuantityTypeIdentifierDietaryVitaminA`).
    public let hkIdentifier: String
    /// Canonical wire unit — `mg` (milligram), `ug` (microgram) or `ml`
    /// (millilitre). NEVER IU: mass is reported in the listed metric unit.
    public let unit: String

    public init(code: NutrientCode, hkIdentifier: String, unit: String) {
        self.code = code
        self.hkIdentifier = hkIdentifier
        self.unit = unit
    }
}

/// The closed nutrient catalog — the single source of truth for the
/// code ↔ HealthKit-identifier ↔ unit mapping the sync path queries + posts.
public enum NutrientCatalog {
    /// All 26 catalog rows (24 vitamin/mineral `Dietary*` types + water +
    /// caffeine), in server-catalog order. Units are exactly the endpoint
    /// table's (`ug` = microgram; do NOT convert to IU).
    public static let all: [NutrientCatalogItem] = [
        NutrientCatalogItem(code: .vitaminA, hkIdentifier: "HKQuantityTypeIdentifierDietaryVitaminA", unit: "ug"),
        NutrientCatalogItem(code: .thiamin, hkIdentifier: "HKQuantityTypeIdentifierDietaryThiamin", unit: "mg"),
        NutrientCatalogItem(code: .riboflavin, hkIdentifier: "HKQuantityTypeIdentifierDietaryRiboflavin", unit: "mg"),
        NutrientCatalogItem(code: .niacin, hkIdentifier: "HKQuantityTypeIdentifierDietaryNiacin", unit: "mg"),
        NutrientCatalogItem(
            code: .pantothenicAcid,
            hkIdentifier: "HKQuantityTypeIdentifierDietaryPantothenicAcid",
            unit: "mg"
        ),
        NutrientCatalogItem(code: .vitaminB6, hkIdentifier: "HKQuantityTypeIdentifierDietaryVitaminB6", unit: "mg"),
        NutrientCatalogItem(code: .biotin, hkIdentifier: "HKQuantityTypeIdentifierDietaryBiotin", unit: "ug"),
        NutrientCatalogItem(code: .folate, hkIdentifier: "HKQuantityTypeIdentifierDietaryFolate", unit: "ug"),
        NutrientCatalogItem(code: .vitaminB12, hkIdentifier: "HKQuantityTypeIdentifierDietaryVitaminB12", unit: "ug"),
        NutrientCatalogItem(code: .vitaminC, hkIdentifier: "HKQuantityTypeIdentifierDietaryVitaminC", unit: "mg"),
        NutrientCatalogItem(code: .vitaminD, hkIdentifier: "HKQuantityTypeIdentifierDietaryVitaminD", unit: "ug"),
        NutrientCatalogItem(code: .vitaminE, hkIdentifier: "HKQuantityTypeIdentifierDietaryVitaminE", unit: "mg"),
        NutrientCatalogItem(code: .vitaminK, hkIdentifier: "HKQuantityTypeIdentifierDietaryVitaminK", unit: "ug"),
        NutrientCatalogItem(code: .calcium, hkIdentifier: "HKQuantityTypeIdentifierDietaryCalcium", unit: "mg"),
        NutrientCatalogItem(code: .iron, hkIdentifier: "HKQuantityTypeIdentifierDietaryIron", unit: "mg"),
        NutrientCatalogItem(code: .magnesium, hkIdentifier: "HKQuantityTypeIdentifierDietaryMagnesium", unit: "mg"),
        NutrientCatalogItem(code: .phosphorus, hkIdentifier: "HKQuantityTypeIdentifierDietaryPhosphorus", unit: "mg"),
        NutrientCatalogItem(code: .zinc, hkIdentifier: "HKQuantityTypeIdentifierDietaryZinc", unit: "mg"),
        NutrientCatalogItem(code: .copper, hkIdentifier: "HKQuantityTypeIdentifierDietaryCopper", unit: "mg"),
        NutrientCatalogItem(code: .manganese, hkIdentifier: "HKQuantityTypeIdentifierDietaryManganese", unit: "mg"),
        NutrientCatalogItem(code: .selenium, hkIdentifier: "HKQuantityTypeIdentifierDietarySelenium", unit: "ug"),
        NutrientCatalogItem(code: .chromium, hkIdentifier: "HKQuantityTypeIdentifierDietaryChromium", unit: "ug"),
        NutrientCatalogItem(code: .molybdenum, hkIdentifier: "HKQuantityTypeIdentifierDietaryMolybdenum", unit: "ug"),
        NutrientCatalogItem(code: .iodine, hkIdentifier: "HKQuantityTypeIdentifierDietaryIodine", unit: "ug"),
        NutrientCatalogItem(code: .water, hkIdentifier: "HKQuantityTypeIdentifierDietaryWater", unit: "ml"),
        NutrientCatalogItem(code: .caffeine, hkIdentifier: "HKQuantityTypeIdentifierDietaryCaffeine", unit: "mg")
    ]
}
