import os
import OSLog
import SwiftUI

/// v0.11 perf instrumentation — `OSSignposter` coverage for the perceptual
/// budgets the Quality-Doctrine demands but that were previously unmeasured in
/// the UI layer (only `Services/HealthKit/HKSyncDiagnostics.swift` referenced
/// signposts, and only in a comment).
///
/// Mirrors the `os.signpost` import pattern used elsewhere in the app. These
/// signposts are inspectable in Instruments → "os_signpost" / "Points of
/// Interest" so the operator can prove the PROJECT_GUIDE.md budgets on-device:
///
/// - **Cold-launch first-paint** ≤ 300 ms p95 — event (`dashboardFirstPaint`)
/// - **Tap-to-detail first-paint** ≤ 200 ms p95 (from cache) — interval
/// - **Tile cache-paint** ≤ 100 ms p95 — event (`tileCachePaint`)
/// - **scenePhase-foreground revalidate** ≤ 300 ms p95 — interval
///
/// v0.14 audit #17 closed the last two budgets: `tapToDetail` and
/// `scenePhaseRevalidate` are now measured as `beginInterval`/`endInterval`
/// durations (not point events), so all four PROJECT_GUIDE.md budgets are provable in
/// Instruments.
///
/// **Phase 09 extension — the eight measured boundaries.** Phase 9 optimises
/// six flows, and every one of them had to become measurable *before* it was
/// touched. The Phase-9 cases below are that vocabulary, and the exact same
/// strings appear in `09-PERFORMANCE-EVIDENCE.md` and in the Instruments
/// Points-of-Interest track, so a trace, a document and a test can be compared
/// without translation.
///
/// Two rules govern what an interval may carry:
///
/// - **Categorical only.** ``Magnitude`` buckets a size into small/medium/large
///   and the byte or entry count never leaves the bucketing function. A byte
///   count of somebody's health export is a weak fingerprint of that person;
///   "large" is not.
/// - **Balanced by construction.** ``measure(_:magnitude:_:)`` closes the
///   interval in a `defer` it owns, and the token form (``open(_:magnitude:)``
///   plus ``close(_:completed:)``) exists for the async and cross-task sites
///   where a closure cannot span the boundary. Both distinguish a completed run
///   from a cancelled one from a thrown one, because "the interval never closed"
///   and "the work was cancelled" look identical in a trace otherwise.
///
/// Zero behavioural effect: signposts compile to no-ops when the subsystem
/// isn't being traced, so this is safe to leave in release builds. The
/// test-observation recorder is `#if DEBUG` only, so a Release build carries no
/// part of it.
enum HLPerfSignpost {
    /// Shared signposter on the app subsystem, "Perf" category. "Points of
    /// Interest" surfaces these prominently in the Instruments timeline.
    static let signposter = OSSignposter(
        subsystem: "dev.healthlog.app",
        category: .pointsOfInterest
    )

    /// Named intervals so call-sites stay typo-safe and the trace reads cleanly.
    enum Interval: StaticString {
        /// Dashboard root body → first content paint (cold-launch budget).
        case dashboardFirstPaint = "dashboard.first-paint"
        /// A dashboard tile painting from cache (tile cache-paint budget).
        case tileCachePaint = "tile.cache-paint"
        /// Tap on a tile → detail screen first paint (tap-to-detail budget).
        case tapToDetail = "tap-to-detail"
        /// scenePhase → `.active` → foreground revalidation settles
        /// (scenePhase-foreground revalidate budget).
        case scenePhaseRevalidate = "scenephase.revalidate"

        // MARK: Phase 09 — measured before optimised

        /// Building the Apple-Health multipart body, before any byte is sent.
        case appleImportPrepare = "apple-import.prepare"
        /// The Apple-Health upload request itself.
        case appleImportUpload = "apple-import.upload"
        /// A Mood analysis that had to compute.
        case moodAnalysisCold = "mood-analysis.cold"
        /// A Mood analysis served from a resident snapshot.
        case moodAnalysisHit = "mood-analysis.hit"
        /// Writing export bytes to protected storage.
        case exportPersist = "export.persist"
        /// Writing the widget snapshot to the App Group container.
        case widgetPersist = "widget.persist"
        /// Opening the persistent outbox store.
        case outboxOpen = "outbox.open"
        /// One foreground pass, from `.active` to the settled revalidation.
        case foregroundPass = "foreground.pass"
    }

    /// The categorical size of the work an interval covers.
    ///
    /// This is the only quantitative thing a Phase-9 signpost is allowed to
    /// carry. The bucketing functions take a count and return a class; the count
    /// itself is never stored, never emitted and never logged.
    enum Magnitude: String, Sendable {
        case unspecified
        case small
        case medium
        case large

        /// Buckets a payload size. Thresholds match the frozen fixtures: the
        /// 16 MiB archive is small, the 256 MiB archive is medium, and the
        /// 1.5 GiB archive is large.
        static func of(byteCount: Int) -> Magnitude {
            switch byteCount {
            case ..<67_108_864: .small
            case ..<536_870_912: .medium
            default: .large
            }
        }

        /// Buckets a record count. The 365-entry history is small and the
        /// 10,000-entry stress history is large.
        static func of(entryCount: Int) -> Magnitude {
            switch entryCount {
            case ..<1000: .small
            case ..<5000: .medium
            default: .large
            }
        }
    }

    /// How an interval ended. A cancelled interval is not a failed one, and
    /// neither is a hung one — without this they are indistinguishable in a
    /// trace, which is how a cancellation-latency budget becomes unprovable.
    enum Outcome: String, Sendable {
        case completed
        case cancelled
        case failed
    }

    /// An open interval. Hand it back to ``close(_:completed:)``; the interval
    /// name and magnitude travel with it so a call-site cannot close the wrong
    /// one.
    struct Token {
        let interval: Interval
        let magnitude: Magnitude
        let state: OSSignpostIntervalState
    }

    /// Emit a one-shot event at a moment in time (e.g. "first paint happened").
    static func event(_ interval: Interval) {
        signposter.emitEvent(interval.rawValue)
    }

    /// Open a duration interval. The returned ``OSSignpostIntervalState`` must be
    /// handed back to ``end(_:_:)`` to close it. The signpost ID stays on the
    /// stack of the caller — no retained state in this enum, keeping the
    /// instrument cheap (audit #17).
    static func begin(_ interval: Interval) -> OSSignpostIntervalState {
        let id = signposter.makeSignpostID()
        return signposter.beginInterval(interval.rawValue, id: id)
    }

    /// Close a duration interval opened with ``begin(_:)``.
    static func end(_ interval: Interval, _ state: OSSignpostIntervalState) {
        signposter.endInterval(interval.rawValue, state)
    }

    // MARK: - Phase 09 — balanced intervals

    /// Open a Phase-9 interval that will be closed by ``close(_:completed:)``.
    ///
    /// Prefer ``measure(_:magnitude:_:)`` where the work fits in one closure.
    /// This token form exists for the `async` and cross-task sites — an upload
    /// awaiting the network, a foreground pass whose end lives in another task —
    /// where a closure cannot span the boundary without changing the isolation
    /// of the work being measured, which would change the thing being measured.
    static func open(_ interval: Interval, magnitude: Magnitude = .unspecified) -> Token {
        Token(
            interval: interval,
            magnitude: magnitude,
            state: signposter.beginInterval(interval.rawValue, id: signposter.makeSignpostID())
        )
    }

    /// Close a Phase-9 interval. `completed` distinguishes a finished run from
    /// an abandoned one; an abandoned run is further split into cancelled and
    /// failed by asking the task, so a user-initiated cancel does not read as an
    /// error in the trace.
    static func close(_ token: Token, completed: Bool) {
        let outcome: Outcome = completed ? .completed : (Task.isCancelled ? .cancelled : .failed)
        signposter.endInterval(
            token.interval.rawValue,
            token.state,
            "\(token.magnitude.rawValue, privacy: .public)/\(outcome.rawValue, privacy: .public)"
        )
        #if DEBUG
            recorder?.record(interval: token.interval, magnitude: token.magnitude, outcome: outcome)
        #endif
    }

    /// Run `work` inside a balanced interval.
    ///
    /// The interval closes on return, on `throw`, and on cancellation, because
    /// the `defer` is the only exit. That is the whole reason this exists: eight
    /// hand-written begin/end pairs are eight chances to forget the end on the
    /// path nobody tested, and an interval that never closes is worse than no
    /// interval at all — it silently poisons the p95 of everything around it.
    static func measure<T>(
        _ interval: Interval,
        magnitude: Magnitude = .unspecified,
        _ work: () throws -> T
    ) rethrows -> T {
        let token = open(interval, magnitude: magnitude)
        var completed = false
        defer { close(token, completed: completed) }
        let result = try work()
        completed = true
        return result
    }

    // MARK: - Phase 09 — the foreground pass

    //
    // The two foreground intervals used to be opened together by a paired
    // helper here, because until 09-06 the foreground was a loose set of sibling
    // tasks and the only thing that could be said to have "settled" was the
    // existing revalidation chain. Plan 09-06 moved `foreground.pass` onto
    // `ForegroundCoordinator.run`, where it is opened once per pass and closed
    // from a `defer` with an outcome, and left `scenephase.revalidate` on the
    // HealthKit-stats → dashboard-summary leg, where it goes on measuring
    // exactly the chain the PROJECT_GUIDE.md budget has always named. The two
    // are therefore no longer co-extensive, which is what 09-01's evidence note
    // said this plan would make true — and it matters: the pass is bounded by
    // construction at 250 ms + 50 ms, so a `scenephase.revalidate` that shared
    // its span would meet its own 300 ms budget by truncation rather than by
    // being fast, which is a measurement that cannot fail.
    //
    // The paired helper was retired with the fan-out it existed for. The token
    // form (`open`/`close`) and the plain form (`begin`/`end`) are what the
    // coordinator and its legs use directly.

    // MARK: tap-to-detail — deferred begin/end across views

    /// In-flight tap-to-detail interval. `begin` is called on the tile tap
    /// (`DashboardScreen.openDetail` / Insights tile), `end` on the destination
    /// page's first content paint — two different views, so the interval handle
    /// is parked here. Holds only the lightweight `OSSignpostIntervalState`
    /// (audit #17: no broader retained state). MainActor-isolated because both
    /// the tap and the first-paint callback run on the main actor.
    @MainActor private static var pendingTapToDetail: OSSignpostIntervalState?

    /// Open the tap-to-detail interval from the tap site. A second tap before
    /// the first detail paints simply replaces the handle (the prior interval is
    /// abandoned — Instruments shows it unclosed, which is the honest signal the
    /// open never reached a paint).
    @MainActor static func beginTapToDetail() {
        pendingTapToDetail = begin(.tapToDetail)
    }

    /// Close the tap-to-detail interval from the destination's first paint.
    /// No-op if no tap is in flight (e.g. the page appeared via a deep link or
    /// tab restore rather than a tile tap).
    @MainActor static func endTapToDetailIfPending() {
        guard let state = pendingTapToDetail else { return }
        pendingTapToDetail = nil
        end(.tapToDetail, state)
    }

    // MARK: - Test observation

    #if DEBUG
        /// One begin/end pair, as observed by a test.
        ///
        /// `OSSignposter` writes into the trace buffer and nothing can read that
        /// back in-process, so proving an interval is balanced needs a second,
        /// cheap witness. This is that witness, and it exists only in DEBUG: a
        /// Release build has no recorder, no lock and no branch.
        struct Record: Sendable, Equatable {
            let interval: String
            let magnitude: Magnitude
            let outcome: Outcome
        }

        /// Collects closed intervals. Install one with ``installRecorder(_:)``
        /// and remove it in the same test.
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [Record] = []

            init() {}

            /// Synchronous on purpose: it is called from `defer` blocks inside
            /// `async` functions, where taking a lock inline is unavailable.
            func record(interval: Interval, magnitude: Magnitude, outcome: Outcome) {
                lock.lock()
                defer { lock.unlock() }
                storage.append(Record(interval: "\(interval.rawValue)", magnitude: magnitude, outcome: outcome))
            }

            var records: [Record] {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }

            func records(for interval: Interval) -> [Record] {
                let name = "\(interval.rawValue)"
                return records.filter { $0.interval == name }
            }
        }

        private final class RecorderBox: @unchecked Sendable {
            private let lock = NSLock()
            private var current: Recorder?

            func install(_ recorder: Recorder?) {
                lock.lock()
                defer { lock.unlock() }
                current = recorder
            }

            func value() -> Recorder? {
                lock.lock()
                defer { lock.unlock() }
                return current
            }
        }

        private static let recorderBox = RecorderBox()

        private static var recorder: Recorder? {
            recorderBox.value()
        }

        /// Install (or, with `nil`, remove) the test recorder.
        static func installRecorder(_ recorder: Recorder?) {
            recorderBox.install(recorder)
        }
    #endif
}

/// View modifier that runs a one-shot "first paint" side effect the first time
/// a view renders its content: an `OSSignposter` event, a resumed rendezvous, or
/// both. Attach to a root/tile/detail view to mark the budget moment without
/// threading state through the view body.
///
/// **Phase 09 / plan 09-05** generalised the payload from "an interval" to
/// "an interval and/or a callback" rather than adding a second modifier with the
/// same `@State`-guarded `onAppear` shape. There is one definition of "this view
/// drew" in the app; a copy of it is a second definition that can drift.
private struct HLFirstPaintSignpost: ViewModifier {
    let interval: HLPerfSignpost.Interval?
    let onFirstPaint: (() -> Void)?
    @State private var emitted = false

    func body(content: Content) -> some View {
        content.onAppear {
            guard !emitted else { return }
            emitted = true
            if let interval { HLPerfSignpost.event(interval) }
            onFirstPaint?()
        }
    }
}

extension View {
    /// Marks this view's first paint with an `OSSignposter` event so the
    /// perceptual budget is measurable in Instruments. One-shot per view
    /// lifetime; no behavioural effect.
    func hlSignpostFirstPaint(_ interval: HLPerfSignpost.Interval) -> some View {
        modifier(HLFirstPaintSignpost(interval: interval, onFirstPaint: nil))
    }

    /// Runs `body` exactly once, from this view's first real render callback.
    ///
    /// This is the callback the first-paint signposts are emitted from, and it
    /// is deliberately the only supported way for launch work to learn that the
    /// app drew: a `Task.yield`, a main-queue hop, a timer, or the return of a
    /// composition-root initializer all happen *near* the first frame without
    /// being it, and every one of them is satisfied by a launch that rendered
    /// nothing at all.
    func hlOnFirstPaint(_ body: @escaping () -> Void) -> some View {
        modifier(HLFirstPaintSignpost(interval: nil, onFirstPaint: body))
    }
}
