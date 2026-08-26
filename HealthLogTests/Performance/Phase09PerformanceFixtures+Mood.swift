import Foundation
@testable import HealthLog

// **Phase 09 Wave 0 — the deterministic Mood history fixtures.**
//
// Split out of `Phase09PerformanceFixtures.swift` by Plan 09-02 (a pure move,
// not one line changed) when that file crossed the 600-line `file_length`
// ceiling. A scoped disable would have hidden the growth from the next plan
// that needs room here; splitting on a seam the file already had — archives,
// Mood histories, counting doubles — leaves each part under its own budget.
//
// The rules that govern it are unchanged: nothing here carries anything
// patient-like. Scores come from a pure index formula, ids are
// `phase09-mood-000123`, tags come from a synthetic `phase09-factor-*`
// catalogue, and notes are always `nil`.

enum Phase09MoodFixture {
    /// Deterministic synthetic Mood history, newest entry at `endingAt`.
    ///
    /// Scores follow a fixed index formula rather than a random draw so the
    /// baseline and the post-change capture analyse byte-identical input. The
    /// formula deliberately produces an uneven day distribution (some days hold
    /// two entries, some hold none) because a same-day collapse and an empty
    /// day are the two shapes the analysis engine actually has to handle.
    static func entries(
        count: Int,
        endingAt end: Date = Date(timeIntervalSince1970: 1_770_000_000),
        calendar: Calendar = .current
    ) -> [MoodEntry] {
        (0 ..< count).map { index in
            let dayOffset = -(index * 3 / 4) // four entries per three days
            let day = calendar.date(byAdding: .day, value: dayOffset, to: end) ?? end
            let recordedAt = day.addingTimeInterval(Double((index % 4) * 3600))
            return MoodEntry(
                id: String(format: "phase09-mood-%06d", index),
                recordedAt: recordedAt,
                score: 1 + (index * 7 % 5),
                tags: [],
                tagKeys: tagKeys(for: index),
                note: nil
            )
        }
    }

    static func entries(depth: Phase09Fixture.MoodHistoryDepth) -> [MoodEntry] {
        entries(count: depth.rawValue)
    }

    /// A synthetic factor catalogue. Nothing here is a real mood factor; the
    /// names exist so the tag-delta detector has more than one bucket to sort.
    private static func tagKeys(for index: Int) -> [String] {
        switch index % 3 {
        case 0: ["phase09-factor-a"]
        case 1: ["phase09-factor-b", "phase09-factor-c"]
        default: []
        }
    }
}

/// **Phase 09 / plan 09-04 — the invocation ledger the whole plan is stated in.**
///
/// The budgets this plan's flows carry are a 1 ms cache hit, a 50 ms cold
/// analysis and a 5 ms main-thread ceiling — all durations, none of them
/// claimable off a simulator. What *is* claimable is a count, so this ledger
/// records one row per engine invocation with the two facts a count can carry
/// honestly: which analysis was asked for, and whether the thread that answered
/// was the one that draws.
///
/// It is a second type rather than a stored property added to 09-01's
/// `Phase09CountingAnalysisEngine`: that one lives in
/// `Phase09PerformanceFixtures.swift`, which sits at 558 lines against a 600-line
/// ceiling with 09-05 still to come, and a stored thread census cannot be added
/// from an extension.
final class Phase09MoodAnalysisLedger: @unchecked Sendable {
    /// One engine invocation.
    struct Invocation: Sendable, Equatable {
        let scope: MoodAnalysisRequest.Scope
        /// How many entries the engine was actually handed — the windowed slice
        /// for `.windowed`, the whole history for `.fullHistory`.
        let entryCount: Int
        /// Recorded at the moment the work began. "The analysis left the main
        /// actor" is a statement about *where*, which a simulator can answer.
        let wasMainThread: Bool
    }

    private let lock = NSLock()
    private var recorded: [Invocation] = []

    var invocations: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var computeCount: Int {
        invocations.count
    }

    var mainThreadComputeCount: Int {
        invocations.filter(\.wasMainThread).count
    }

    func computeCount(scope: MoodAnalysisRequest.Scope) -> Int {
        invocations.filter { $0.scope == scope }.count
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        recorded.removeAll()
    }

    private func record(_ invocation: Invocation) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(invocation)
    }

    /// The engine seam, wired to the real computation. The ledger never changes
    /// what is computed — a counting engine that returned a different answer
    /// would make every semantic-equivalence assertion in this plan a lie.
    var engine: MoodAnalysisEngine {
        MoodAnalysisEngine(
            isCached: { _ in false },
            compute: { [self] request in
                record(
                    Invocation(
                        scope: request.scope,
                        entryCount: request.entries.count,
                        wasMainThread: Thread.isMainThread
                    )
                )
                return MoodInsights.compute(
                    entries: request.entries,
                    now: request.now,
                    calendar: request.calendar,
                    enrichment: request.enrichment
                )
            }
        )
    }
}

/// Records the section indices a `MoodAnalysisContent` body actually emitted.
///
/// This is the second witness 09-03 had to learn the hard way: "the render
/// performed no analysis" is also the honest report of a body that never ran.
/// The decorator closure is called *from inside* the body for each of the seven
/// sections, so a non-zero count is proof the body evaluated — proof a view
/// count could not give, because SwiftUI draws different states into the same
/// `UIView`s.
final class Phase09MoodSectionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int] = []

    var indices: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ index: Int) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(index)
    }
}
