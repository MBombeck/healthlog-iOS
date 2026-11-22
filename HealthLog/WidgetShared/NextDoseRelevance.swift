import Foundation

/// **Smart Stack relevance of the next-dose widget and complication.**
///
/// High from 30 minutes before a dose is due until 60 minutes after, low
/// otherwise, zero when no dose is open. The window is half open: the score
/// turns high exactly at its start and low again exactly at its end, so the
/// two boundaries are the only instants a timeline needs an extra entry for.
public enum NextDoseRelevance {
    public static let leadWindow: TimeInterval = 30 * 60
    public static let trailWindow: TimeInterval = 60 * 60

    public static let highScore: Float = 100
    public static let lowScore: Float = 10
    public static let noDoseScore: Float = 0

    /// Relevance at `now` for the open dose due at `scheduledAt`. A dose the
    /// widget already took care of (`settled`) is not open any more.
    public static func relevance(for scheduledAt: Date?, now: Date, settled: Bool = false) -> Float {
        guard let scheduledAt, !settled else { return noDoseScore }
        let opens = scheduledAt.addingTimeInterval(-leadWindow)
        let closes = scheduledAt.addingTimeInterval(trailWindow)
        return now >= opens && now < closes ? highScore : lowScore
    }

    /// The instants after `now` at which ``relevance(for:now:)`` changes.
    public static func boundaries(for scheduledAt: Date?, after now: Date) -> [Date] {
        guard let scheduledAt else { return [] }
        return [
            scheduledAt.addingTimeInterval(-leadWindow),
            scheduledAt.addingTimeInterval(trailWindow)
        ].filter { $0 > now }
    }

    /// Timeline frames with the relevance boundaries added. Each boundary
    /// inherits the armed state of the frame before it, so the two-tap confirm
    /// timing is unchanged.
    public static func frames(
        _ base: [(date: Date, armed: Bool)],
        scheduledAt: Date?,
        now: Date
    ) -> [(date: Date, armed: Bool)] {
        var frames = base
        for boundary in boundaries(for: scheduledAt, after: now)
            where !base.contains(where: { $0.date == boundary })
        {
            let before = base.filter { $0.date <= boundary }.max { $0.date < $1.date }
            frames.append((boundary, before?.armed ?? false))
        }
        return frames.sorted { $0.date < $1.date }
    }
}
