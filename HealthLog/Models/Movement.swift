import Foundation

/// **1.5 MOVE (#133)** — the Dawarich connection as `GET /api/dawarich/status`
/// reports it (server v1.43). Only what the "Unterwegs" section needs is read:
/// whether the account is connected, and the first and last day the server
/// holds movement for. Every field is tolerant, so a shape this build does not
/// know reads as "not connected" instead of failing the section.
public struct DawarichStatus: Decodable, Sendable, Equatable {
    public let connected: Bool
    /// The oldest stored day, `YYYY-MM-DD`, or `nil` when none is stored.
    public let oldestDay: String?
    /// The newest stored day, `YYYY-MM-DD`, or `nil` when none is stored.
    public let latestDay: String?

    public init(connected: Bool, oldestDay: String? = nil, latestDay: String? = nil) {
        self.connected = connected
        self.oldestDay = oldestDay
        self.latestDay = latestDay
    }

    private enum CodingKeys: String, CodingKey {
        case connected, oldestDay, latestDay
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connected = (try? c.decodeIfPresent(Bool.self, forKey: .connected)) ?? false
        oldestDay = MovementDay.validKey(try? c.decodeIfPresent(String.self, forKey: .oldestDay))
        latestDay = MovementDay.validKey(try? c.decodeIfPresent(String.self, forKey: .latestDay))
    }
}

/// The `movement` block of `GET /api/day/{date}` (`DayMovement`, server v1.43).
///
/// The server rounds distances to one decimal in `distance.unit` (resolved
/// from the account's unit preference) and sends `null` for anything it does
/// not know. A `null` is never zero: `awayFromHomeMinutes == nil` means the day
/// has no coverage, not a day spent at home. The app shows what is there and
/// leaves the rest out.
public struct DayMovement: Decodable, Sendable, Equatable {
    public struct Distance: Sendable, Equatable {
        /// `km` or `mi`, shown as given.
        public let unit: String
        public let total: Double?
        public let driving: Double?
        public let train: Double?

        public init(unit: String, total: Double?, driving: Double?, train: Double?) {
            self.unit = unit
            self.total = total
            self.driving = driving
            self.train = train
        }
    }

    public struct Travel: Sendable, Equatable {
        public let isTravelDay: Bool
        /// ISO 3166 alpha-2, or `nil` when the server does not know the country.
        public let countryCode: String?

        public init(isTravelDay: Bool, countryCode: String?) {
            self.isTravelDay = isTravelDay
            self.countryCode = countryCode
        }
    }

    public let distance: Distance?
    public let placesVisited: Int?
    public let awayFromHomeMinutes: Int?
    public let travel: Travel?

    public init(distance: Distance?, placesVisited: Int?, awayFromHomeMinutes: Int?, travel: Travel?) {
        self.distance = distance
        self.placesVisited = placesVisited
        self.awayFromHomeMinutes = awayFromHomeMinutes
        self.travel = travel
    }

    /// Whether the day carries any value the section can show. A day the
    /// server knows nothing about reads "no values" instead of a list of
    /// empty rows.
    public var hasValues: Bool {
        distance?.total != nil || distance?.driving != nil || distance?.train != nil
            || placesVisited != nil || awayFromHomeMinutes != nil || travel?.isTravelDay == true
    }

    private enum CodingKeys: String, CodingKey {
        case distance, placesVisited, awayFromHomeMinutes, travel
    }

    private enum DistanceKeys: String, CodingKey {
        case unit, total, driving, train
    }

    private enum TravelKeys: String, CodingKey {
        case isTravelDay, countryCode
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let d = try? c.nestedContainer(keyedBy: DistanceKeys.self, forKey: .distance),
           let unit = try? d.decodeIfPresent(String.self, forKey: .unit), !unit.isEmpty
        {
            distance = Distance(
                unit: unit,
                total: try? d.decodeIfPresent(Double.self, forKey: .total),
                driving: try? d.decodeIfPresent(Double.self, forKey: .driving),
                train: try? d.decodeIfPresent(Double.self, forKey: .train)
            )
        } else {
            // Without a unit no number can be shown honestly.
            distance = nil
        }
        placesVisited = try? c.decodeIfPresent(Int.self, forKey: .placesVisited)
        awayFromHomeMinutes = try? c.decodeIfPresent(Int.self, forKey: .awayFromHomeMinutes)
        if let t = try? c.nestedContainer(keyedBy: TravelKeys.self, forKey: .travel),
           let isTravelDay = try? t.decodeIfPresent(Bool.self, forKey: .isTravelDay)
        {
            let code = try? t.decodeIfPresent(String.self, forKey: .countryCode)
            travel = Travel(isTravelDay: isTravelDay, countryCode: code?.isEmpty == true ? nil : code)
        } else {
            travel = nil
        }
    }
}

/// The slice of `GET /api/day/{date}` this build reads: the `movement` block
/// and nothing else. Absent, `null` and malformed all read as `nil` (a server
/// before v1.43, a delegate, the module off, no Dawarich connection).
public struct DayMovementPayload: Decodable, Sendable, Equatable {
    public let movement: DayMovement?

    public init(movement: DayMovement?) {
        self.movement = movement
    }

    private enum CodingKeys: String, CodingKey {
        case movement
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        movement = try? c.decodeIfPresent(DayMovement.self, forKey: .movement)
    }
}

/// Day-key arithmetic for the section's day switcher. Day keys are local
/// calendar dates (`YYYY-MM-DD`) as the server cuts them; stepping is done
/// on a fixed Gregorian UTC calendar so a month or year boundary or a clock
/// change never skips or repeats a day.
public enum MovementDay {
    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return cal
    }()

    private static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f
    }

    /// The UTC midnight of a valid day key, `nil` for anything else.
    public static func date(_ key: String) -> Date? {
        guard key.count == 10 else { return nil }
        return formatter().date(from: key)
    }

    /// `key` when it is a real calendar day, otherwise `nil`.
    static func validKey(_ key: String?) -> String? {
        guard let key, date(key) != nil else { return nil }
        return key
    }

    /// The day `offset` days from `key`; `nil` for an invalid key.
    public static func shift(_ key: String, by offset: Int) -> String? {
        guard let day = date(key), let moved = calendar.date(byAdding: .day, value: offset, to: day) else { return nil }
        return formatter().string(from: moved)
    }

    /// Today's key in the device's own calendar and time zone, the upper
    /// bound of the switcher (never a day in the future).
    public static func today(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let parts = local.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
