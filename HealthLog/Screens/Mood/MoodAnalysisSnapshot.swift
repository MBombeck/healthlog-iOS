import Foundation

/// **Phase 09 / plan 09-04 — what a Mood analysis is a function of.**
///
/// Before this key existed, `MoodAnalysisContent` recomputed the whole insight
/// set from `store.entries` on every read of a computed property, six or seven
/// times per body evaluation, with no way to say whether two of those reads were
/// asking the same question. The key names the question: two requests that agree
/// on every member below must produce byte-identical insights, and two that
/// disagree on any member must not be served from one another.
///
/// Each member is here because changing it changes the answer:
///
/// - `revision` — `MoodStore`'s monotonic counter, advanced only by a mutation
///   that actually changed the history. This is the O(1) stand-in for hashing
///   the entry array, which is the thing the plan forbids doing in `body`.
/// - `scope` — the windowed slice and the full-history spine (B18's heatmap
///   decoupling) are different analyses even when the entry sets coincide.
/// - `periodDays` — the trailing window the period control selects, `nil` for
///   the full-history spine, which deliberately does *not* move with it.
/// - `dayStart` — local midnight. Every window in `MoodInsights.compute` is
///   day-granular (`avg30`, the prior period, all three slopes), so the day
///   boundary is exactly the resolution at which "now" changes the answer, and
///   a cached result stops being valid when the day turns over.
/// - `calendar` — carries its own identifier, time zone, locale and first
///   weekday. All four reach the day bucketing or the weekday detectors, so the
///   whole value is the key member rather than a pair of identifier strings.
/// - `enrichment` — the authoritative `/api/mood/analytics` override. When it
///   is present it replaces three slopes and the prior-period mean, so an
///   analysis computed without it may not be served to a caller that has it.
struct MoodAnalysisKey: Hashable, Sendable {
    /// `MoodStore.entriesRevision` at the moment the render captured its input.
    let revision: Int
    /// Windowed slice vs. the full-history spine.
    let scope: MoodAnalysisRequest.Scope
    /// Trailing window in days; `nil` for the full-history spine.
    let periodDays: Int?
    /// Local midnight of the day the render belongs to.
    let dayStart: Date
    /// The calendar every bucketing decision is taken in.
    let calendar: Calendar
    /// The server override, when the caller has one.
    let enrichment: MoodAnalyticsEnrichment?

    /// Derived, so a test can assert the calendar *identifier* is a real
    /// dimension of the key without the key carrying a second copy of it.
    var calendarIdentifier: Calendar.Identifier {
        calendar.identifier
    }

    /// Derived, for the same reason: the time zone moves local midnight, and a
    /// snapshot computed in one zone is not the snapshot for another.
    var timeZoneIdentifier: String {
        calendar.timeZone.identifier
    }
}

/// One immutable, `Sendable` analysis result plus everything the render draws
/// from it. Built off the main actor and handed across a single time.
///
/// It deliberately does **not** carry the entries it was computed from: a cache
/// that retained four entry arrays of a 10,000-entry history would trade the
/// recomputation for a memory bound nobody asked for. What it keeps is derived
/// and bounded by the number of *days*, not the number of entries.
struct MoodAnalysisSnapshot: Sendable {
    /// The exact question this is the answer to.
    let key: MoodAnalysisKey
    /// The insight set, identical to what `MoodInsights.compute` returns for
    /// the same slice, day boundary, calendar and enrichment.
    let insights: MoodInsights
    /// The trend series, pre-sorted and pre-mapped, so no body evaluation sorts
    /// a 10,000-entry history to draw a chart.
    let trend: [MoodTrendChart.Entry]
}

/// **The main-actor gate the analysis is published through.**
///
/// The cache computes off the main actor, which means a result can come back
/// after the thing that asked for it stopped being the thing on screen — the
/// period moved, an entry was logged, the day turned over. Publishing that
/// result would paint an answer to a question nobody is asking any more, and it
/// would do so *silently*, because a stale insight set is a perfectly plausible
/// one.
///
/// So publication is not an assignment; it is a comparison against the key the
/// view most recently adopted, taken on the main actor. ``adopt(windowed:fullHistory:)``
/// runs synchronously before any `await`, which is precisely what makes a
/// slower, older result recognisable as stale when it finally lands.
///
/// The worker never touches this type. The cache hands back a value; the main
/// actor decides whether that value is still the answer.
@MainActor
@Observable
final class MoodAnalysisPresenter {
    /// The windowed analysis currently on screen, `nil` until the first
    /// publication lands.
    private(set) var windowed: MoodAnalysisSnapshot?
    /// The full-history spine the heatmap reads when it is decoupled from the
    /// period control. Stays `nil` for a host that drives the heatmap by period.
    private(set) var fullHistory: MoodAnalysisSnapshot?

    @ObservationIgnored private var adoptedWindowed: MoodAnalysisKey?
    @ObservationIgnored private var adoptedFullHistory: MoodAnalysisKey?

    /// Adopt the keys the view is displaying *now*. Synchronous by contract.
    func adopt(windowed windowedKey: MoodAnalysisKey, fullHistory fullHistoryKey: MoodAnalysisKey?) {
        adoptedWindowed = windowedKey
        adoptedFullHistory = fullHistoryKey
    }

    /// Publish only if this snapshot still answers the adopted key and the
    /// caller has not been cancelled. Returns whether it published, so the
    /// refusal is observable rather than merely invisible.
    @discardableResult
    func publish(_ snapshot: MoodAnalysisSnapshot) -> Bool {
        guard !Task.isCancelled else { return false }
        switch snapshot.key.scope {
        case .windowed:
            guard snapshot.key == adoptedWindowed else { return false }
            windowed = snapshot
        case .fullHistory:
            guard snapshot.key == adoptedFullHistory else { return false }
            fullHistory = snapshot
        }
        return true
    }

    /// Adopt, compute off-main, publish what is still current. The one path the
    /// render uses, and the one a test drives.
    func load(
        windowed windowedKey: MoodAnalysisKey,
        fullHistory fullHistoryKey: MoodAnalysisKey?,
        entries: [MoodEntry],
        engine: MoodAnalysisEngine,
        cache: MoodAnalysisCache
    ) async {
        adopt(windowed: windowedKey, fullHistory: fullHistoryKey)
        await publish(cache.snapshot(for: windowedKey, entries: entries, engine: engine))
        guard let fullHistoryKey else { return }
        await publish(cache.snapshot(for: fullHistoryKey, entries: entries, engine: engine))
    }
}
