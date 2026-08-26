import Foundation

/// **W-B180 — pure hypnogram layout decisions** behind ``SleepHypnogramScreen``.
///
/// RCA "alle Phasen-Balken kleben rechts": the chart always mapped each
/// segment's real `start`/`end` (render-verified) — but a SUMMARY-shaped
/// source (e.g. WHOOP, `mapSleep` in the server repo) stores one row per
/// stage with `measuredAt = sleep END` for ALL stages. The server's
/// reconstruction derives `start = end − minutes`, so every stage becomes a
/// single span ending at the wake instant → all bars share the right edge.
/// Those nights carry NO within-night timing; the screen must not render a
/// fake timeline for them.
///
/// This enum keeps the two decisions pure + unit-testable:
/// - ``isSummaryShaped(_:)`` — detect the totals-only shape.
/// - ``positionedSegments(for:)`` — the stage segments a real timeline
///   renders: `IN_BED` excluded (the top lane paints the full bed span from
///   the session bounds), spans clamped to the bed span so a stray segment
///   can never stretch the pinned x domain.
/// - ``distribution(for:)`` — proportional per-stage shares for the
///   summary-shaped fallback band.
enum SleepHypnogramLayout {
    /// Tolerance for "all segments end at the same instant". Real hypnogram
    /// segments are sequential (each next stage begins where the previous
    /// ended), so two or more segments sharing one end instant can only be
    /// per-stage totals.
    private static let sharedEndTolerance: TimeInterval = 90

    /// `true` when the night's segments are per-stage TOTALS (no timing):
    /// at least two segments and every end instant within
    /// ``sharedEndTolerance`` of the latest one.
    static func isSummaryShaped(_ segments: [SleepSegment]) -> Bool {
        guard segments.count >= 2,
              let latestEnd = segments.map(\.end).max() else { return false }
        return segments.allSatisfy {
            abs($0.end.timeIntervalSince(latestEnd)) <= sharedEndTolerance
        }
    }

    /// The segments the timeline chart renders: `IN_BED` rows excluded (the
    /// synthetic top lane paints the whole bed span), every span clamped to
    /// `[session.start, session.end]`, empty/inverted spans dropped.
    static func positionedSegments(for session: SleepSession) -> [SleepSegment] {
        session.segments.compactMap { segment in
            guard segment.stage != .inBed else { return nil }
            let start = max(segment.start, session.start)
            let end = min(segment.end, session.end)
            guard end > start else { return nil }
            return SleepSegment(
                stage: segment.stage,
                start: start,
                end: end,
                minutes: segment.minutes
            )
        }
    }

    /// One stage's share of the summary-distribution band.
    struct DistributionItem: Equatable {
        let stage: SleepStage
        let fraction: CGFloat
    }

    /// Proportional per-stage shares for the fallback band, deep→shallow
    /// left→right (darkest ink first), `IN_BED` excluded (it is the
    /// container, not a phase). Empty when the night carries no stage
    /// minutes.
    static func distribution(for session: SleepSession) -> [DistributionItem] {
        let entries = session.stages
            .filter { $0.key != .inBed && $0.value > 0 }
            .sorted { $0.key.depthRank > $1.key.depthRank }
        let total = entries.reduce(0) { $0 + $1.value }
        guard total > 0 else { return [] }
        return entries.map {
            DistributionItem(stage: $0.key, fraction: CGFloat($0.value) / CGFloat(total))
        }
    }
}
