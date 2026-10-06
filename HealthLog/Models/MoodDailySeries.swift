import Foundation

/// `GET /api/mood/analytics` — the canonical daily mood series (server
/// `MoodDailySeries`, `docs/api/openapi.yaml` at `v1.39.0`): one mean per
/// profile-zone day (`YYYY-MM-DD`) plus the shared summary over the daily
/// means. #115 · 1.3 — the Mood analysis takes its day means from here.
///
/// The summary's `slope7` / `slope30` are `TrendSlope` objects on the wire
/// (`{ slope, direction, confidence }`); the decoder used to expect bare
/// numbers and failed on every real payload. It now reads the object's
/// `slope` and still accepts a bare number.
struct MoodAnalyticsEnrichment: Codable, Equatable, Hashable, Sendable {
    /// One server day.
    struct Day: Codable, Equatable, Hashable, Sendable {
        /// `YYYY-MM-DD` in the profile zone.
        let date: String
        /// The day's mean pleasantness, 1…5.
        let score: Double
        let samples: Int
    }

    let slope7: Double?
    let slope30: Double?
    let slope90: Double?
    let avg30LastMonth: Double?
    let avg30LastYear: Double?
    /// Oldest first. Empty on a payload without entries.
    let days: [Day]

    /// Memberwise init for tests / direct construction.
    init(
        slope7: Double?,
        slope30: Double?,
        slope90: Double?,
        avg30LastMonth: Double?,
        avg30LastYear: Double?,
        days: [Day] = []
    ) {
        self.slope7 = slope7
        self.slope30 = slope30
        self.slope90 = slope90
        self.avg30LastMonth = avg30LastMonth
        self.avg30LastYear = avg30LastYear
        self.days = days
    }

    private enum RootKeys: String, CodingKey { case entries, summary }
    private enum SummaryKeys: String, CodingKey {
        case slope7, slope30, slope90, avg30LastMonth, avg30LastYear
    }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        days = try root.decodeLossyArray(Day.self, forKey: .entries)
        if let summary = try? root.nestedContainer(keyedBy: SummaryKeys.self, forKey: .summary) {
            slope7 = Self.slope(summary, .slope7)
            slope30 = Self.slope(summary, .slope30)
            slope90 = Self.slope(summary, .slope90)
            avg30LastMonth = try? summary.decodeIfPresent(Double.self, forKey: .avg30LastMonth)
            avg30LastYear = try? summary.decodeIfPresent(Double.self, forKey: .avg30LastYear)
        } else {
            slope7 = nil
            slope30 = nil
            slope90 = nil
            avg30LastMonth = nil
            avg30LastYear = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var root = encoder.container(keyedBy: RootKeys.self)
        try root.encode(days, forKey: .entries)
        var summary = root.nestedContainer(keyedBy: SummaryKeys.self, forKey: .summary)
        try summary.encodeIfPresent(slope7, forKey: .slope7)
        try summary.encodeIfPresent(slope30, forKey: .slope30)
        try summary.encodeIfPresent(slope90, forKey: .slope90)
        try summary.encodeIfPresent(avg30LastMonth, forKey: .avg30LastMonth)
        try summary.encodeIfPresent(avg30LastYear, forKey: .avg30LastYear)
    }

    /// A `TrendSlope` object's `slope`, or a bare number (cache round trip).
    private static func slope(_ c: KeyedDecodingContainer<SummaryKeys>, _ key: SummaryKeys) -> Double? {
        if let object = try? c.decodeIfPresent(TrendSlope.self, forKey: key) { return object.slope }
        return try? c.decodeIfPresent(Double.self, forKey: key)
    }
}
