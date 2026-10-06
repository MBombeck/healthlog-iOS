import Foundation

/// #115 · 1.3 — the server's day-to-day mood stability (`GET /api/mood/insights`
/// → `stability`, `src/lib/insights/mood-patterns.ts` `computeMoodStability`).
/// The app used to compute its own score from the device-calendar daily means
/// with a different formula (`(1 − sd/2)·100`, five bands); the server's is
/// `100·(1 − min(sd, 1.5)/1.5)` over the profile-zone daily means of the last
/// year, four bands. Rendered verbatim; `nil` below the server's day floor.
public struct MoodStability: Equatable, Hashable, Sendable, Codable {
    public let score: Int
    public let stdDev: Double
    public let band: Band
    /// Daily points the score was computed over.
    public let days: Int

    public init(score: Int, stdDev: Double, band: Band, days: Int) {
        self.score = score
        self.stdDev = stdDev
        self.band = band
        self.days = days
    }

    private enum CodingKeys: String, CodingKey {
        case score, stdDev, band, days
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The server sends a whole number on the wire as a JSON number.
        score = try Int(c.decode(Double.self, forKey: .score).rounded())
        stdDev = try c.decode(Double.self, forKey: .stdDev)
        band = try c.decode(Band.self, forKey: .band)
        days = try c.decodeIfPresent(Int.self, forKey: .days) ?? 0
    }

    /// The server's descriptive bands (never "good"/"bad").
    public enum Band: String, Equatable, Hashable, Sendable, Codable, TolerantServerEnum {
        case verySteady
        case steady
        case variable
        case veryVariable
        case unknown

        public static let unknownFallback = Band.unknown
        public static let wireVocabulary: StaticString = "mood stability band"

        /// `true` when the band warms the gauge marker (DESIGN-B §3.4).
        public var isFlagged: Bool {
            self == .veryVariable
        }
    }
}
