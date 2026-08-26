import Foundation

/// Multi-night sleep-stage composition — the `sleepStages` block of
/// `GET /api/analytics` (parity Build 4 · item 4.7).
///
/// **Why this endpoint.** The web multi-night stacked bar
/// (`W/src/components/insights/sleep-stage-stacked-bar.tsx`) reads exactly this
/// block; there is no dedicated `/api/sleep/stages` route. The server computes
/// it through the SAME canonical `reconstructSleepNights` engine the hypnogram
/// and the Sleep Score use, so a per-night total here can never contradict the
/// single-night view. iOS renders it; it never re-clusters or re-dedups.
///
/// `perNight` is a trailing-30-day series, ascending, keyed on the wake day in
/// the USER's timezone (`dayKey`, `YYYY-MM-DD`). The 7 / 14 / 30-day toggle is
/// a pure client-side tail slice of that one array — no extra round-trip.
public struct SleepStageBreakdownDTO: Decodable, Sendable, Equatable {
    /// The server's read window in days (30 today).
    public let windowDays: Int
    /// Nights with at least one stage minute in the window.
    public let nights: Int
    /// Sum of every stage minute in the window.
    public let totalMinutes: Int
    /// Window totals per stage. PARTIAL — a stage the user's source never
    /// reports is simply absent; unknown wire keys are dropped on decode.
    public let stages: [SleepStage: Int]
    /// Per-night breakdown, ascending by `dayKey`.
    public let perNight: [SleepStageNight]

    private enum CodingKeys: String, CodingKey {
        case windowDays, nights, totalMinutes, stages, perNight
    }

    public init(
        windowDays: Int,
        nights: Int,
        totalMinutes: Int,
        stages: [SleepStage: Int],
        perNight: [SleepStageNight]
    ) {
        self.windowDays = windowDays
        self.nights = nights
        self.totalMinutes = totalMinutes
        self.stages = stages
        self.perNight = perNight
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windowDays = try SleepRhythmDecoding.minutes(c, .windowDays) ?? 30
        nights = try SleepRhythmDecoding.minutes(c, .nights) ?? 0
        totalMinutes = try SleepRhythmDecoding.minutes(c, .totalMinutes) ?? 0
        let rawStages = try c.decodeIfPresent([String: Double].self, forKey: .stages)
        stages = SleepStageMinutes.decode(rawStages)
        perNight = try c.decodeIfPresent([SleepStageNight].self, forKey: .perNight) ?? []
    }
}

/// One night of the multi-night composition series.
public struct SleepStageNight: Decodable, Sendable, Equatable, Identifiable {
    /// Wake-day key (`YYYY-MM-DD`) in the user's server-resolved timezone.
    /// Doubles as the stable `ForEach` identity — the server emits one entry
    /// per wake day.
    public var id: String {
        dayKey
    }

    public let dayKey: String
    /// Per-stage minutes for this night. PARTIAL, same tolerance as the
    /// window totals.
    public let stages: [SleepStage: Int]

    private enum CodingKeys: String, CodingKey {
        case dayKey, stages
    }

    public init(dayKey: String, stages: [SleepStage: Int]) {
        self.dayKey = dayKey
        self.stages = stages
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dayKey = try c.decode(String.self, forKey: .dayKey)
        let rawStages = try c.decodeIfPresent([String: Double].self, forKey: .stages)
        stages = SleepStageMinutes.decode(rawStages)
    }

    /// Total stacked minutes for this night — the same sum the stacked column
    /// height and the tooltip total use (``SleepStageComposition/stackOrder``,
    /// so `IN_BED` is excluded).
    public var stackedMinutes: Int {
        SleepStageComposition.stackOrder.reduce(0) { $0 + (stages[$1] ?? 0) }
    }
}

/// Envelope for the one field this read wants off the wide `/api/analytics`
/// payload. Deliberately narrow: decoding the full analytics envelope here
/// would couple the sleep page to summaries, correlations and the health
/// score, none of which it renders.
struct AnalyticsSleepStagesEnvelope: Decodable {
    let sleepStages: SleepStageBreakdownDTO?
}

// MARK: - Stage minute decoding

/// Tolerant `[String: Double]` → `[SleepStage: Int]` mapping, shared by the
/// window totals and the per-night entries.
///
/// Mirrors ``SleepSession``'s decoder exactly: the wire values are float sums
/// of second-precision segments, an unknown FUTURE stage key is dropped rather
/// than thrown, and a non-finite value drops just its own key
/// (`Int(safeServer:)`, W-CRASHGUARD).
enum SleepStageMinutes {
    static func decode(_ raw: [String: Double]?) -> [SleepStage: Int] {
        (raw ?? [:]).reduce(into: [:]) { mapped, entry in
            if let stage = SleepStage(rawValue: entry.key), let minutes = Int(safeServer: entry.value) {
                mapped[stage] = minutes
            }
        }
    }
}

// MARK: - Composition maths (pure, unit-tested)

/// Pure stage-composition maths behind the multi-night chart + the stage
/// percentage rows. Kept out of the view so the arithmetic is testable
/// without a render host.
enum SleepStageComposition {
    /// Stack order, bottom → top, mirroring the web `STAGE_ORDER`
    /// (`sleep-stage-stacked-bar.tsx`): deepest restorative stage first so a
    /// reader scanning upward reads quality before context.
    ///
    /// **`IN_BED` is deliberately NOT a member.** It is the TOTAL time in bed
    /// (≈ CORE + DEEP + REM + AWAKE), so stacking it alongside those phases
    /// doubles every column and inflates the percentages — the exact bug the
    /// web component documents at its own `STAGE_ORDER`. The `IN_BED` token
    /// survives for the single-night hypnogram, which paints the bed span.
    static let stackOrder: [SleepStage] = [.deep, .rem, .core, .asleep, .awake]

    /// One stage's share of a composition.
    struct Share: Equatable, Identifiable {
        var id: SleepStage {
            stage
        }

        let stage: SleepStage
        let minutes: Int
        /// `minutes / total`, `0…1`. Exact — round only for display.
        let fraction: Double
        /// The display percentage, rounded half-away-from-zero to match the
        /// web's `Math.round(minutes / total * 100)` exactly.
        let percent: Int
    }

    /// Per-stage shares of a minute map, ordered by ``stackOrder``.
    ///
    /// Stages with zero (or absent) minutes are omitted — a night the source
    /// reported no REM for shows four rows, not a "REM 0 %" row that reads as
    /// a measurement. Returns `[]` when nothing sums above zero, which the
    /// caller renders as the honest "no stage data" state.
    ///
    /// **Rounding is per-stage and independent**, matching the web tooltip. The
    /// percentages can therefore sum to 99 or 101; that is deliberate parity —
    /// a largest-remainder redistribution would put a different number on iOS
    /// than the web shows for the same night.
    static func shares(of stages: [SleepStage: Int]) -> [Share] {
        let present = stackOrder.compactMap { stage -> (SleepStage, Int)? in
            guard let minutes = stages[stage], minutes > 0 else { return nil }
            return (stage, minutes)
        }
        let total = present.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return [] }
        return present.map { stage, minutes in
            let fraction = Double(minutes) / Double(total)
            return Share(
                stage: stage,
                minutes: minutes,
                fraction: fraction,
                percent: Int((fraction * 100).rounded())
            )
        }
    }

    /// Element-wise sum of the per-night stage maps — the input the window
    /// percentage rows use for the ACTIVE toggle window.
    ///
    /// Summing the sliced nights (rather than reading the server's 30-day
    /// `stages` totals) is what makes the percentages agree with the columns
    /// actually on screen: pick "7 days" and the rows describe those seven
    /// nights, not a 30-day average the chart is not showing.
    static func totals(of nights: [SleepStageNight]) -> [SleepStage: Int] {
        nights.reduce(into: [:]) { totals, night in
            for (stage, minutes) in night.stages {
                totals[stage, default: 0] += minutes
            }
        }
    }

    /// The trailing `days` nights of an ascending series — the client-side
    /// slice behind the 7 / 14 / 30 toggle. Shorter series pass through whole.
    static func trailing(_ nights: [SleepStageNight], days: Int) -> [SleepStageNight] {
        guard days > 0, nights.count > days else { return nights }
        return Array(nights.suffix(days))
    }
}
