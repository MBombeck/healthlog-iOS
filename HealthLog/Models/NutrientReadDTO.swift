import Foundation

// Read-side nutrient DTOs (server v1.28 `GET /api/nutrients`, v1.29
// `GET /api/nutrients/daily` + `POST /api/nutrients/water`, GH iOS #48).
//
// The write path (`POST /api/nutrients/batch`) lives in `NutrientBatchDTO.swift`;
// this file is the LEZE-/Anzeige-Seite the app was missing — the daily totals
// the server holds, the per-nutrient day-series + its resolved EFSA reference,
// and the manual water quick-add.
//
// **Tolerant by design.** Every shape decodes defensively (`decodeIfPresent`
// with sane defaults, an unknown catalog code skips its row instead of failing
// the whole list, a malformed reference nils instead of throwing) so a forward-
// compatible server addition or a partially-populated payload never blanks the
// screen. Units ride the wire per-nutrient (`mg` | `ug` | `ml`) and are NEVER
// hardcoded on the read path — the row's own `unit` is authoritative.

// MARK: - Overview (`GET /api/nutrients?days=N`)

/// One per-nutrient row of the window summary: the latest synced day + its total
/// and how many days inside the window carried data. Catalog order, one row per
/// nutrient WITH data (the server omits empty nutrients).
public struct NutrientOverviewRowDTO: Codable, Sendable, Equatable, Identifiable {
    public let nutrient: NutrientCode
    /// Canonical wire unit for this nutrient (`mg` | `ug` | `ml`) — read from the
    /// wire, not the client catalog, so a server unit change never desyncs.
    public let unit: String
    /// `yyyy-MM-dd` (user local timezone) of the most recent day carrying data.
    public let latestDay: String
    /// The latest day's cumulative-sum total in `unit`.
    public let latestAmount: Double
    /// Count of distinct days inside the window carrying data (≥ 1).
    public let daysWithData: Int

    public var id: NutrientCode {
        nutrient
    }

    public init(
        nutrient: NutrientCode,
        unit: String,
        latestDay: String,
        latestAmount: Double,
        daysWithData: Int
    ) {
        self.nutrient = nutrient
        self.unit = unit
        self.latestDay = latestDay
        self.latestAmount = latestAmount
        self.daysWithData = daysWithData
    }

    private enum CodingKeys: String, CodingKey {
        case nutrient, unit, latestDay, latestAmount, daysWithData
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `nutrient` is the only load-bearing field — an unknown/missing code
        // throws so the enclosing lossy list drops just this row.
        nutrient = try c.decode(NutrientCode.self, forKey: .nutrient)
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
        latestDay = try c.decodeIfPresent(String.self, forKey: .latestDay) ?? ""
        latestAmount = try c.decodeIfPresent(Double.self, forKey: .latestAmount) ?? 0
        daysWithData = try c.decodeIfPresent(Int.self, forKey: .daysWithData) ?? 0
    }
}

/// `GET /api/nutrients` window summary — `windowDays` + the per-nutrient rows.
/// The `nutrients` array decodes LOSSILY: a row whose nutrient code is unknown
/// to this build (a forward-compat server addition) is skipped, never fatal.
public struct NutrientOverviewDTO: Codable, Sendable, Equatable {
    public let windowDays: Int
    public let nutrients: [NutrientOverviewRowDTO]

    public init(windowDays: Int, nutrients: [NutrientOverviewRowDTO]) {
        self.windowDays = windowDays
        self.nutrients = nutrients
    }

    private enum CodingKeys: String, CodingKey {
        case windowDays, nutrients
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windowDays = try c.decodeIfPresent(Int.self, forKey: .windowDays) ?? 0
        let lossy = try c.decodeIfPresent([LossyNutrientRow].self, forKey: .nutrients) ?? []
        nutrients = lossy.compactMap(\.value)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(windowDays, forKey: .windowDays)
        try c.encode(nutrients, forKey: .nutrients)
    }
}

/// One array element that consumes exactly one row and NEVER throws — an
/// un-decodable row (unknown code / wrong shape) yields `nil` so a single bad
/// entry cannot fail the whole list decode.
private struct LossyNutrientRow: Decodable {
    let value: NutrientOverviewRowDTO?
    init(from decoder: Decoder) {
        value = try? NutrientOverviewRowDTO(from: decoder)
    }
}

// MARK: - EFSA reference (`GET /api/nutrients/daily` → `reference`)

/// The EFSA value kind the server resolved (named in Coach prose later).
public enum NutrientReferenceKind: String, Codable, Sendable, Equatable {
    /// Population Reference Intake.
    case pri = "PRI"
    /// Adequate Intake.
    case ai = "AI"
    /// Safe-level ceiling (caffeine).
    case safeLevel
}

/// Whether the reference is a target intake or a do-not-exceed ceiling.
public enum NutrientReferenceDirection: String, Codable, Sendable, Equatable {
    case target
    case upperGuidance
}

/// The EFSA reference resolved against the caller's profile sex (server-side,
/// `null` when the profile has no sex on file — never guessed). `value` is in
/// the series' `unit`.
public struct NutrientReferenceDTO: Codable, Sendable, Equatable {
    public let kind: NutrientReferenceKind
    public let direction: NutrientReferenceDirection
    public let value: Double
    /// Citation, shown verbatim (e.g. "EFSA DRV 2015 (retinol equivalents, adults)").
    public let source: String

    public init(
        kind: NutrientReferenceKind,
        direction: NutrientReferenceDirection,
        value: Double,
        source: String
    ) {
        self.kind = kind
        self.direction = direction
        self.value = value
        self.source = source
    }
}

// MARK: - Daily series (`GET /api/nutrients/daily?nutrient=<code>&days=N`)

/// One calendar day in the dense series — `amount` is `0` for a day with no data.
public struct NutrientDayPointDTO: Codable, Sendable, Equatable, Identifiable {
    public let day: String
    public let amount: Double

    public var id: String {
        day
    }

    public init(day: String, amount: Double) {
        self.day = day
        self.amount = amount
    }

    private enum CodingKeys: String, CodingKey { case day, amount }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decodeIfPresent(String.self, forKey: .day) ?? ""
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
    }
}

/// `GET /api/nutrients/daily` — a dense per-day series for ONE nutrient plus its
/// resolved EFSA `reference` (or `nil` when the profile sex is unknown). A
/// malformed reference nils rather than failing the whole decode.
public struct NutrientDailySeriesDTO: Codable, Sendable, Equatable {
    public let nutrient: NutrientCode
    public let unit: String
    public let windowDays: Int
    public let days: [NutrientDayPointDTO]
    public let reference: NutrientReferenceDTO?

    public init(
        nutrient: NutrientCode,
        unit: String,
        windowDays: Int,
        days: [NutrientDayPointDTO],
        reference: NutrientReferenceDTO?
    ) {
        self.nutrient = nutrient
        self.unit = unit
        self.windowDays = windowDays
        self.days = days
        self.reference = reference
    }

    private enum CodingKeys: String, CodingKey {
        case nutrient, unit, windowDays, days, reference
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nutrient = try c.decode(NutrientCode.self, forKey: .nutrient)
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
        windowDays = try c.decodeIfPresent(Int.self, forKey: .windowDays) ?? 0
        days = try c.decodeIfPresent([NutrientDayPointDTO].self, forKey: .days) ?? []
        // A reference with an unknown kind/direction nils rather than throwing —
        // the surface simply hides the reference line, honest to "no reference".
        reference = (try? c.decodeIfPresent(NutrientReferenceDTO.self, forKey: .reference)).flatMap { $0 }
    }

    /// The latest day carrying data (highest non-empty `day`), or `nil` when the
    /// whole window is empty — the value the reference progress compares against.
    public var latestNonEmptyDay: NutrientDayPointDTO? {
        days.filter { $0.amount > 0 }.max { $0.day < $1.day }
    }
}

// MARK: - Water quick-add (`POST /api/nutrients/water`)

/// `add` increments today's MANUAL water total (quick-add chips); `set`
/// overwrites it (the "edit today's total" path).
public enum NutrientWaterWriteMode: String, Codable, Sendable, Equatable {
    case add
    case set
}

/// `POST /api/nutrients/water` body. Water only. `day` omitted → server uses the
/// caller's current local day. `Codable` (not just `Encodable`) so the outbox
/// payload round-trips and tests can decode the sent body.
public struct NutrientWaterWriteRequestDTO: Codable, Sendable, Equatable {
    public let amountMl: Double
    public let mode: NutrientWaterWriteMode
    public let day: String?

    public init(amountMl: Double, mode: NutrientWaterWriteMode, day: String? = nil) {
        self.amountMl = amountMl
        self.mode = mode
        self.day = day
    }
}

/// The MANUAL water row after the add/set write. `nutrient` is const `"water"`
/// and `source` const `"MANUAL"` — decoded as plain strings (tolerant).
public struct NutrientWaterWriteResponseDTO: Codable, Sendable, Equatable {
    public let day: String
    public let nutrient: String
    public let source: String
    public let amount: Double
    public let unit: String

    public init(day: String, nutrient: String, source: String, amount: Double, unit: String) {
        self.day = day
        self.nutrient = nutrient
        self.source = source
        self.amount = amount
        self.unit = unit
    }

    private enum CodingKeys: String, CodingKey {
        case day, nutrient, source, amount, unit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decodeIfPresent(String.self, forKey: .day) ?? ""
        nutrient = try c.decodeIfPresent(String.self, forKey: .nutrient) ?? "water"
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "MANUAL"
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? "ml"
    }
}
