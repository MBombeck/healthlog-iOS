import Foundation

/// **1.5 BP-TOD (#161, server #1331, v1.47.0)** — the answer of
/// `GET /api/measurements/blood-pressure/time-of-day?days=`.
///
/// Every figure is the server's. It assigns each paired reading to a part of
/// the day in the record's own time zone (morning 04:00 to 11:59, midday 12:00
/// to 17:59, evening 18:00 to 03:59, so 01:15 is the evening before), forms
/// the whole-mmHg means and the morning-minus-evening difference. The app
/// buckets nothing and recomputes nothing; a `nil` mean is the server saying
/// "below `minReadings`", never a gap to fill.
///
/// Decoding is tolerant where a newer server could grow: a part whose name
/// this build does not know is skipped rather than failing the whole card.
public struct BloodPressureTimeOfDay: Decodable, Sendable, Equatable {
    public enum Part: String, Sendable, CaseIterable {
        case morning
        case midday
        case evening
    }

    public struct PartSummary: Sendable, Equatable {
        public let part: Part
        /// First local hour of the part (inclusive).
        public let startHour: Int
        /// Local hour the part ends at (exclusive); smaller than `startHour`
        /// when the part runs past midnight (evening: 18 to 4).
        public let endHour: Int
        public let readingCount: Int
        /// Whole mmHg; `nil` while `readingCount` is below `minReadings`.
        public let systolic: Int?
        public let diastolic: Int?
        public let pulseReadingCount: Int
        /// Whole bpm; `nil` while `pulseReadingCount` is below `minReadings`.
        public let pulse: Int?

        /// Both means present: the part shows its pair, otherwise "too few".
        public var hasMean: Bool {
            systolic != nil && diastolic != nil
        }
    }

    public struct Difference: Decodable, Sendable, Equatable {
        public let systolic: Int
        public let diastolic: Int
    }

    public let days: Int
    public let timeZone: String
    public let minReadings: Int
    public let readingCount: Int
    /// In the server's order (morning, midday, evening); unknown parts dropped.
    public let parts: [PartSummary]
    /// `nil` until morning and evening both reach `minReadings`.
    public let morningEveningDifference: Difference?

    /// No paired reading in the window at all: the card's empty state.
    public var isEmpty: Bool {
        readingCount == 0
    }

    private enum CodingKeys: String, CodingKey {
        case days, timeZone, minReadings, readingCount, parts, morningEveningDifference
    }

    public init(
        days: Int,
        timeZone: String,
        minReadings: Int,
        readingCount: Int,
        parts: [PartSummary],
        morningEveningDifference: Difference?
    ) {
        self.days = days
        self.timeZone = timeZone
        self.minReadings = minReadings
        self.readingCount = readingCount
        self.parts = parts
        self.morningEveningDifference = morningEveningDifference
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        days = try container.decode(Int.self, forKey: .days)
        timeZone = try container.decodeIfPresent(String.self, forKey: .timeZone) ?? ""
        minReadings = try container.decode(Int.self, forKey: .minReadings)
        readingCount = try container.decode(Int.self, forKey: .readingCount)
        let rows = try container.decode([LossyPart].self, forKey: .parts)
        parts = rows.compactMap(\.value)
        morningEveningDifference = try container.decodeIfPresent(Difference.self, forKey: .morningEveningDifference)
    }

    /// One `parts[]` row; `value == nil` for a part name this build does not
    /// model, so a newer server cannot break the card.
    private struct LossyPart: Decodable {
        let value: PartSummary?

        private enum Keys: String, CodingKey {
            case part, startHour, endHour, readingCount, systolic, diastolic, pulseReadingCount, pulse
        }

        init(from decoder: Decoder) throws {
            let row = try decoder.container(keyedBy: Keys.self)
            guard let part = try Part(rawValue: row.decode(String.self, forKey: .part)) else {
                value = nil
                return
            }
            value = try PartSummary(
                part: part,
                startHour: row.decode(Int.self, forKey: .startHour),
                endHour: row.decode(Int.self, forKey: .endHour),
                readingCount: row.decode(Int.self, forKey: .readingCount),
                systolic: row.decodeIfPresent(Int.self, forKey: .systolic),
                diastolic: row.decodeIfPresent(Int.self, forKey: .diastolic),
                pulseReadingCount: row.decodeIfPresent(Int.self, forKey: .pulseReadingCount) ?? 0,
                pulse: row.decodeIfPresent(Int.self, forKey: .pulse)
            )
        }
    }
}
