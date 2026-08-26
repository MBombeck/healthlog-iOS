import Foundation
import Synchronization

/// **Phase 09 / plan 09-04 — where the Mood analysis runs, and how often.**
///
/// An `actor` is taken here for the same reason 09-03 took one for the export
/// and widget writes: not primarily to serialize, but because it has an executor
/// that is not the main one. The whole insight set — the daily-average spine,
/// three least-squares slopes, the stability std-dev, the tag deltas and the
/// eight correlation detectors — is O(n) to O(n log n) in the history, and the
/// history the plan has to survive is 10,000 entries.
///
/// **Why the residency is behind a `Mutex` rather than actor isolation.** The
/// account boundary has to be able to say "gone" *synchronously*: `MoodStore`'s
/// `clearOnLogout()` is a synchronous call inside a registry loop, and a purge
/// that had to be awaited would either need a drain in the logout cascade or a
/// fire-and-forget `Task` racing the next composition. A `let Mutex` on an actor
/// is reachable without isolation, so the purge is a plain call that has already
/// happened by the time `clearOnLogout()` returns. The `generation` inside it is
/// 09-03's epoch, for the one interleaving that remains: a compute that started
/// before a purge must not insert its result after one.
///
/// **Bounded.** Memoization without a bound is a leak with good manners. Four
/// keys is the working set a Mood surface actually has, and the residency holds
/// only *derived* values — daily averages, deltas, findings — never the entry
/// arrays they came from, so its size is bounded by the number of days rather
/// than by the number of entries.
///
/// **Single-flight.** Two hosts, two sections and a re-entered screen can all
/// ask for the same key at the same instant. The in-flight table is written
/// *synchronously* before the first `await`, which is what makes a second
/// arrival find it; 09-03's lesson — an actor method that awaits is reentrant —
/// applies here in the direction of coalescing rather than of clobbering.
actor MoodAnalysisCache {
    /// The residency bound. Four is the working set a Mood surface actually
    /// has: a windowed analysis and a full-history spine for the period the
    /// operator is on, and the same pair for the one they just came from.
    static let capacity = 4

    /// The bounded residency, most-recently-used last, plus the account epoch
    /// that lets a purge overtake a compute that is already running.
    private struct Residency {
        var generation = 0
        var entries: [(key: MoodAnalysisKey, snapshot: MoodAnalysisSnapshot)] = []
    }

    private let residency = Mutex(Residency())

    /// One task per key in flight. Actor-isolated, because coalescing is the
    /// one thing here that genuinely needs the actor's serialization.
    private var inFlight: [MoodAnalysisKey: Task<MoodAnalysisSnapshot, Never>] = [:]

    /// How many keys are resident.
    nonisolated func residentKeyCount() -> Int {
        residency.withLock { $0.entries.count }
    }

    /// Whether this exact key would be served without computing.
    nonisolated func isResident(_ key: MoodAnalysisKey) -> Bool {
        residency.withLock { state in state.entries.contains { $0.key == key } }
    }

    /// Drop everything, synchronously. The logout path calls this so a
    /// signed-out account's derived analysis does not sit in memory waiting for
    /// the next one. Advancing the generation is the other half: a computation
    /// that started before the purge must not insert its result after it.
    nonisolated func removeAll() {
        residency.withLock { state in
            state.generation &+= 1
            state.entries.removeAll()
        }
    }

    /// Take the resident answer, promoting it to most-recently-used.
    private nonisolated func resident(_ key: MoodAnalysisKey) -> MoodAnalysisSnapshot? {
        residency.withLock { state in
            guard let index = state.entries.firstIndex(where: { $0.key == key }) else { return nil }
            let hit = state.entries.remove(at: index)
            state.entries.append(hit)
            return hit.snapshot
        }
    }

    private nonisolated func currentGeneration() -> Int {
        residency.withLock { $0.generation }
    }

    private nonisolated func retain(_ snapshot: MoodAnalysisSnapshot, generation: Int) {
        residency.withLock { state in
            guard state.generation == generation else { return }
            state.entries.removeAll { $0.key == snapshot.key }
            state.entries.append((snapshot.key, snapshot))
            if state.entries.count > Self.capacity {
                state.entries.removeFirst(state.entries.count - Self.capacity)
            }
        }
    }

    /// The one entry point. Answers `key` from `entries`, computing through the
    /// measured `engine` seam when it has to.
    ///
    /// The resident branch performs no work at all: `entries` is handed to the
    /// engine only so the seam can name its interval, and the `resident:`
    /// argument is what makes `mood-analysis.hit` the interval it opens.
    func snapshot(
        for key: MoodAnalysisKey,
        entries: [MoodEntry],
        engine: MoodAnalysisEngine
    ) async -> MoodAnalysisSnapshot {
        if let hit = resident(key) {
            return MoodAnalysisSnapshot(
                key: key,
                insights: engine.insights(
                    MoodAnalysisRequest(
                        entries: entries,
                        scope: key.scope,
                        now: key.dayStart,
                        calendar: key.calendar,
                        enrichment: key.enrichment
                    ),
                    resident: hit.insights
                ),
                trend: hit.trend
            )
        }
        if let existing = inFlight[key] {
            return await existing.value
        }
        let generation = currentGeneration()
        let work = Task { Self.compute(key: key, entries: entries, engine: engine) }
        // Synchronous, before the first suspension: a second arrival for this
        // key has to be able to find it.
        inFlight[key] = work
        let snapshot = await work.value
        inFlight[key] = nil
        retain(snapshot, generation: generation)
        return snapshot
    }

    /// The pure derivation. Everything it needs is in the key, which is what
    /// makes "the same key produces the same snapshot" a property rather than a
    /// hope: the window bound, the reference day, the calendar and the
    /// enrichment all come from the key, never from `Date.now` or
    /// `Calendar.current` read a second time inside the worker.
    static func compute(
        key: MoodAnalysisKey,
        entries: [MoodEntry],
        engine: MoodAnalysisEngine
    ) -> MoodAnalysisSnapshot {
        let scoped = scopedEntries(key: key, entries: entries)
        let request = MoodAnalysisRequest(
            entries: scoped,
            scope: key.scope,
            now: key.dayStart,
            calendar: key.calendar,
            enrichment: key.enrichment
        )
        return MoodAnalysisSnapshot(
            key: key,
            insights: engine.insights(request),
            trend: scoped
                .sorted { $0.recordedAt < $1.recordedAt }
                .map { MoodTrendChart.Entry(date: $0.recordedAt, score: $0.score) }
        )
    }

    /// The period window, reproduced from the key. This is `MoodPeriod.filter`
    /// evaluated at `key.dayStart` — the same cutoff arithmetic, on the same
    /// calendar, against the same inclusive lower bound.
    private static func scopedEntries(key: MoodAnalysisKey, entries: [MoodEntry]) -> [MoodEntry] {
        guard let days = key.periodDays,
              let cutoff = key.calendar.date(byAdding: .day, value: -days, to: key.dayStart) else { return entries }
        return entries.filter { $0.recordedAt >= cutoff }
    }
}
