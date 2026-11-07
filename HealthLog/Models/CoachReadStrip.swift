import Foundation

/// **1.5 LAB-LINES, from COACH-R point 5 (#126 3.9)** — line one of
/// `GET /api/insights/coach-read?metric=` (`CoachReadStrip.baseline`): the
/// person's usual range for the metric and where the latest reading sits.
///
/// Only the baseline is read. The second line (`driver`) is a correlation
/// sentence the metric page already shows under "Zusammenhänge", and the
/// page stays calm without it twice. Every field is the server's; the app
/// only converts units and words the sentence.
public struct CoachReadStrip: Decodable, Sendable, Equatable {
    public let baseline: Baseline?

    public struct Baseline: Decodable, Sendable, Equatable {
        public enum Placement: String, Sendable, Equatable {
            case within, above, below
        }

        /// Edges of the usual range, in the stored unit.
        public let low: Double
        public let high: Double
        /// The latest reading, in the stored unit.
        public let latest: Double
        /// `YYYY-MM-DD` of the latest reading in the record's zone.
        public let latestDate: String?
        /// `true` when ``latestDate`` is today in the record's zone (v1.41).
        /// `nil` on an older server: then the app says nothing, because it
        /// cannot tell today's reading from an older one.
        public let latestIsToday: Bool?
        public let placement: Placement
        /// `true` for a glucose day still in progress: ``latest`` is today's
        /// mean so far and the range the one for the same hours.
        public let isSameHours: Bool

        public init(
            low: Double,
            high: Double,
            latest: Double,
            latestDate: String?,
            latestIsToday: Bool?,
            placement: Placement,
            isSameHours: Bool = false
        ) {
            self.low = low
            self.high = high
            self.latest = latest
            self.latestDate = latestDate
            self.latestIsToday = latestIsToday
            self.placement = placement
            self.isSameHours = isSameHours
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            low = try container.decode(Double.self, forKey: .low)
            high = try container.decode(Double.self, forKey: .high)
            latest = try container.decode(Double.self, forKey: .latest)
            latestDate = try? container.decodeIfPresent(String.self, forKey: .latestDate)
            latestIsToday = try? container.decodeIfPresent(Bool.self, forKey: .latestIsToday)
            let word = try container.decode(String.self, forKey: .placement)
            guard let placement = Placement(rawValue: word) else {
                throw DecodingError.dataCorruptedError(forKey: .placement, in: container, debugDescription: "unknown placement")
            }
            self.placement = placement
            isSameHours = (try? container.decodeIfPresent(String.self, forKey: .basis)) == "sameHours"
        }

        private enum CodingKeys: String, CodingKey {
            case low, high, latest, latestDate, latestIsToday, placement, basis
        }
    }

    public init(baseline: Baseline?) {
        self.baseline = baseline
    }

    /// An unreadable baseline (an unknown placement word) is no baseline.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseline = try? container.decodeIfPresent(Baseline.self, forKey: .baseline)
    }

    private enum CodingKeys: String, CodingKey {
        case baseline
    }
}
