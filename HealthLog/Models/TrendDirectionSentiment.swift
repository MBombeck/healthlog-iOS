import Foundation

/// Which way a change counts as progress — the server's
/// `TrendDirectionSentiment` (`src/lib/insights/trend-sentiment.ts`, v1.39).
///
/// On the wire today as `tiles.weightTrend.direction` of the dashboard
/// snapshot (`"up-good" | "up-bad" | "hold"`), judged against the person's own
/// stored target. v1.39 added `hold`: the value sits inside the target band,
/// so staying level is the good outcome and a move either way is neutral —
/// never a setback. The app renders this verdict; it does not derive it.
///
/// #115 · 1.7 — tolerant like every server-owned enum: a word this build does
/// not know lands on ``unknown`` and colours nothing.
public enum TrendDirectionSentiment: String, Codable, Sendable, Equatable, CaseIterable, TolerantServerEnum {
    /// A rise is progress.
    case upGood = "up-good"
    /// A fall is progress (also the server's reading when no target is stored).
    case upBad = "up-bad"
    /// A rise and a fall weigh the same (web-only today, part of the type).
    case neutral
    /// Inside the band: level is progress, a move either way is neutral.
    case hold
    /// A sentiment this build does not know.
    case unknown

    public static let unknownFallback = TrendDirectionSentiment.unknown
    public static let wireVocabulary: StaticString = "trend direction sentiment"

    /// How a change in a given direction reads.
    public enum ChangeTone: Equatable, Sendable {
        case favorable
        case adverse
        case neutral
    }

    /// The observed change's direction.
    public enum Change: Equatable, Sendable {
        case rising
        case falling
        case level
    }

    /// The tone for a change, straight from the server's verdict. Nothing is
    /// recomputed here — this is only the colour table the verdict implies.
    public func tone(for change: Change) -> ChangeTone {
        switch (self, change) {
        case (.upGood, .rising), (.upBad, .falling), (.hold, .level):
            .favorable
        case (.upGood, .falling), (.upBad, .rising):
            .adverse
        case (.upGood, .level), (.upBad, .level), (.hold, .rising), (.hold, .falling),
             (.neutral, _), (.unknown, _):
            .neutral
        }
    }
}
