import Foundation

/// **Phase 09 Wave 0 — the measured Mood-analysis boundary.**
///
/// `MoodAnalysisContent` used to call `MoodInsights.compute` directly from two
/// computed properties, which meant there was no place to stand: no way to count
/// how often the engine actually ran, no way to tell a recomputation from a
/// reuse, and therefore no way to state before-and-after numbers for the change
/// Plan 09-04 is going to make. This type is that place to stand, and it changes
/// nothing about what is computed today.
///
/// **Why `isCached` exists before any cache does.** The measurement needs two
/// separately named intervals — `mood-analysis.cold` and `mood-analysis.hit` —
/// and an interval must be named at the moment it opens, not when it closes. So
/// the seam has to answer "is this result already resident?" *before* it
/// computes. That is not an artificial shape invented for the trace: it is
/// exactly how a keyed cache works, an O(1) key probe followed by either a serve
/// or a compute. The live engine has no cache yet and answers `false` every
/// time, so production only ever opens the cold interval today. Plan 09-04
/// replaces the two closures and nothing else in the app has to move.
struct MoodAnalysisEngine: Sendable {
    /// O(1) probe: would this request be served without computing? The live
    /// implementation answers `false` because there is nothing to serve from.
    var isCached: @Sendable (MoodAnalysisRequest) -> Bool
    /// Produce the insights. The live implementation is the existing pure
    /// engine, called with the existing arguments.
    var compute: @Sendable (MoodAnalysisRequest) -> MoodInsights

    /// Production default — byte-for-byte the computation the two Mood hosts
    /// performed inline before Phase 9 touched anything.
    static let live = MoodAnalysisEngine(
        isCached: { _ in false },
        compute: {
            MoodInsights.compute(
                entries: $0.entries,
                now: $0.now,
                calendar: $0.calendar,
                enrichment: $0.enrichment
            )
        }
    )

    /// The measured entry point. Opens exactly one balanced interval, named for
    /// what actually happened, and carries only the categorical size of the
    /// history — never a score, never a note, never an entry.
    ///
    /// **Plan 09-04 — the `resident` parameter.** A keyed cache knows the answer
    /// is already in hand *before* it asks the engine, and knowing it is exactly
    /// what makes `mood-analysis.hit` reachable without computing anything. When
    /// `resident` is supplied the seam opens the hit interval and returns it; the
    /// engine's own `isCached` probe is not consulted, because the caller is a
    /// better-informed probe than the closure. When it is `nil` — every call site
    /// 09-01 wrote, and every uncached call — nothing changes.
    func insights(_ request: MoodAnalysisRequest, resident: MoodInsights? = nil) -> MoodInsights {
        if let resident {
            return HLPerfSignpost.measure(.moodAnalysisHit, magnitude: .of(entryCount: resident.entryCount)) {
                resident
            }
        }
        let interval: HLPerfSignpost.Interval = isCached(request) ? .moodAnalysisHit : .moodAnalysisCold
        return HLPerfSignpost.measure(interval, magnitude: .of(entryCount: request.entries.count)) {
            compute(request)
        }
    }
}

/// One analysis request. `scope` distinguishes the period-windowed slice from
/// the full-history spine the heatmap needs, because they are different keys
/// even when they happen to hold the same entries.
///
/// **Plan 09-04** added `now`, `calendar` and `enrichment`. They were implicit
/// before — `MoodInsights.compute` read `Date.now` and `Calendar.current` from
/// its own defaults on every call — and an implicit input cannot be a cache key.
/// The defaults reproduce the pre-09-04 call exactly, so `MoodAnalysisRequest`'s
/// existing two-argument construction is unchanged.
struct MoodAnalysisRequest: Sendable {
    enum Scope: String, Sendable, Hashable {
        /// The slice the period control selects.
        case windowed
        /// The whole history, decoupled from the period control (B18).
        case fullHistory
    }

    let entries: [MoodEntry]
    let scope: Scope
    /// The reference "today" every trailing window is measured back from.
    let now: Date
    /// The calendar every day bucket and weekday detector is taken in.
    let calendar: Calendar
    /// The authoritative `/api/mood/analytics` override, when the caller has one.
    let enrichment: MoodAnalyticsEnrichment?

    init(
        entries: [MoodEntry],
        scope: Scope,
        now: Date = .now,
        calendar: Calendar = .current,
        enrichment: MoodAnalyticsEnrichment? = nil
    ) {
        self.entries = entries
        self.scope = scope
        self.now = now
        self.calendar = calendar
        self.enrichment = enrichment
    }
}
