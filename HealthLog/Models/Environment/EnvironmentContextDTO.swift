import Foundation

// Wire DTOs for the environmental-context module overview (Build 7 Item 7.7;
// server module `environment`, ModuleKey since Build 2).
//
// Source of truth (verified 2026-07-23 against the `HealthLog` server repo):
//   - `src/app/api/environment/route.ts` — `GET /api/environment` handler
//   - `src/lib/environment/open-meteo.ts` — `OPEN_METEO_ATTRIBUTION`
//   - `prisma/schema.prisma` — `EnvironmentTravelLocation` / `EnvironmentContext`
//
// CONTRACT FACTS the client must honour:
//   - The overview returns the coarse HOME location, the manual TRAVEL overrides,
//     a small SUMMARY of stored daily observations (count + latest day, NOT the
//     per-day weather values — those are consumed server-side for correlations),
//     and the upstream ATTRIBUTION string. There is no air-quality / pollen / UV
//     data in this contract — the module is weather + daylight only, so this
//     surface deliberately does not model those.
//   - Module-gated: a `403 module.disabled` envelope when the account has the
//     `environment` module switched off (typed into `HLError.moduleDisabled` by
//     `APIClient`). The store maps that to a "sinnvoll leer" disabled state.
//   - **Open-Meteo attribution is a LICENCE obligation (CC BY 4.0), not polish.**
//     The upstream weather data is Open-Meteo, which requires a visible, linked
//     "Weather data by Open-Meteo.com" credit. The attribution therefore ALWAYS
//     resolves to a non-empty string — even if a (older / partial) server omits
//     the field, ``EnvironmentOverviewDTO`` falls back to
//     ``EnvironmentOverviewDTO/defaultAttribution`` so the credit can never
//     disappear.
//
// Responses are wrapped in the standard `{ data: … }` envelope, unwrapped by
// `APIClient.send`. Every field decodes defensively (`decodeIfPresent` with sane
// defaults, a lossy travel list) so a forward-compatible server addition or a
// partially-populated payload never blanks the screen. Date-ish fields ride the
// wire as raw strings (`YYYY-MM-DD` day-keys / ISO-8601 instants) and are kept as
// `String` for tolerance — no client-side date parsing is load-bearing.

// MARK: - Home

/// The account's coarse home location (rounded to ~city granularity server-side).
/// `nil` on the overview when the user has not set a home yet. Every field is
/// tolerant: a partial row still renders what it has.
public struct EnvironmentHomeDTO: Codable, Sendable, Equatable {
    /// Coarse latitude (server rounds to ~1 km). `nil` when unset.
    public let lat: Double?
    /// Coarse longitude. `nil` when unset.
    public let lon: Double?
    /// Human label, e.g. "Bochum, North Rhine-Westphalia, Germany".
    public let label: String?
    /// IANA timezone anchoring the day-key of stored observations.
    public let timezone: String?
    /// Effective-from instant (ISO-8601) — the home resolves days from here on.
    /// `nil` when the server did not stamp it.
    public let since: String?

    public init(
        lat: Double?,
        lon: Double?,
        label: String?,
        timezone: String?,
        since: String?
    ) {
        self.lat = lat
        self.lon = lon
        self.label = label
        self.timezone = timezone
        self.since = since
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lat = try c.decodeIfPresent(Double.self, forKey: .lat)
        lon = try c.decodeIfPresent(Double.self, forKey: .lon)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        timezone = try c.decodeIfPresent(String.self, forKey: .timezone)
        since = try c.decodeIfPresent(String.self, forKey: .since)
    }

    private enum CodingKeys: String, CodingKey {
        case lat, lon, label, timezone, since
    }
}

// MARK: - Travel override

/// One manual travel override — for any day in `[startDate, endDate]` the weather
/// fetch resolves against this coarse location instead of home. `startDate` /
/// `endDate` are inclusive `YYYY-MM-DD` day-keys (server model).
public struct EnvironmentTravelDTO: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let startDate: String
    public let endDate: String
    public let lat: Double?
    public let lon: Double?
    public let label: String

    public init(
        id: String,
        startDate: String,
        endDate: String,
        lat: Double?,
        lon: Double?,
        label: String
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.lat = lat
        self.lon = lon
        self.label = label
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        startDate = try c.decodeIfPresent(String.self, forKey: .startDate) ?? ""
        endDate = try c.decodeIfPresent(String.self, forKey: .endDate) ?? ""
        lat = try c.decodeIfPresent(Double.self, forKey: .lat)
        lon = try c.decodeIfPresent(Double.self, forKey: .lon)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case id, startDate, endDate, lat, lon, label
    }
}

// MARK: - Observation summary

/// Small summary of the stored daily observations (weather / daylight). The
/// overview does NOT return the per-day values — only the coverage: how many days
/// are recorded and the latest day / fetch instant. This is what the display
/// surface honestly shows ("N Tage erfasst, zuletzt …").
public struct EnvironmentContextSummaryDTO: Codable, Sendable, Equatable {
    /// Number of stored observation days for the account (≥ 0).
    public let days: Int
    /// `YYYY-MM-DD` of the most recent stored observation, or `nil` when none.
    public let latestDate: String?
    /// ISO-8601 instant the latest observation was fetched, or `nil`.
    public let latestFetchedAt: String?

    public init(days: Int, latestDate: String?, latestFetchedAt: String?) {
        self.days = days
        self.latestDate = latestDate
        self.latestFetchedAt = latestFetchedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = try c.decodeIfPresent(Int.self, forKey: .days) ?? 0
        latestDate = try c.decodeIfPresent(String.self, forKey: .latestDate)
        latestFetchedAt = try c.decodeIfPresent(String.self, forKey: .latestFetchedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case days, latestDate, latestFetchedAt
    }
}

// MARK: - Overview

/// `GET /api/environment` — the environmental-context module overview: the coarse
/// home, the travel overrides (lossy list), the observation summary, and the
/// upstream Open-Meteo attribution.
public struct EnvironmentOverviewDTO: Codable, Sendable, Equatable {
    public let home: EnvironmentHomeDTO?
    public let travel: [EnvironmentTravelDTO]
    public let context: EnvironmentContextSummaryDTO
    /// **Licence-mandated** Open-Meteo credit (CC BY 4.0). Always non-empty — a
    /// server that omits the field falls back to ``defaultAttribution`` so the
    /// required credit can never be lost to deploy skew.
    public let attribution: String

    /// The canonical Open-Meteo credit string (server
    /// `OPEN_METEO_ATTRIBUTION`). Used as the fallback whenever the wire omits or
    /// blanks the field so the licence obligation is honoured unconditionally.
    public static let defaultAttribution = "Weather data by Open-Meteo.com"

    /// The Open-Meteo homepage the attribution links to (CC BY 4.0 requires a
    /// link back to the source). Not a UI string — a fixed licence URL.
    public static let attributionURL = URL(string: "https://open-meteo.com/")

    /// The CC BY 4.0 licence deed the credit is issued under.
    public static let licenseURL = URL(string: "https://creativecommons.org/licenses/by/4.0/")

    public init(
        home: EnvironmentHomeDTO?,
        travel: [EnvironmentTravelDTO],
        context: EnvironmentContextSummaryDTO,
        attribution: String
    ) {
        self.home = home
        self.travel = travel
        self.context = context
        self.attribution = attribution
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        home = try c.decodeIfPresent(EnvironmentHomeDTO.self, forKey: .home)
        // Lossy travel list: a malformed override row drops out instead of
        // failing the whole overview.
        let rows = try c.decodeIfPresent([LossyTravelRow].self, forKey: .travel) ?? []
        travel = rows.compactMap(\.value)
        context = try c.decodeIfPresent(EnvironmentContextSummaryDTO.self, forKey: .context)
            ?? EnvironmentContextSummaryDTO(days: 0, latestDate: nil, latestFetchedAt: nil)
        // LICENCE: never let the Open-Meteo credit be empty. A missing / blank
        // wire field falls back to the canonical string.
        let wire = try c.decodeIfPresent(String.self, forKey: .attribution)
        attribution = (wire?.isEmpty == false) ? (wire ?? Self.defaultAttribution) : Self.defaultAttribution
    }

    private enum CodingKeys: String, CodingKey {
        case home, travel, context, attribution
    }

    /// Decodes one travel row, yielding `nil` instead of throwing so one bad row
    /// cannot blank the list. Boxed (rather than a `try?` in an unkeyed loop) so a
    /// failed decode cannot desync the container cursor onto the next row.
    private struct LossyTravelRow: Decodable {
        let value: EnvironmentTravelDTO?

        init(from decoder: Decoder) throws {
            value = try? EnvironmentTravelDTO(from: decoder)
        }
    }
}
