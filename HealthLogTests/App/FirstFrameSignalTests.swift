// This suite drives App-target symbols (`FirstFrameSignal`, the SwiftUI root
// composition, a real `UIWindow` host) that the SPM library build has no part of.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing

    /// **Phase 09 / plan 09-05 — the first frame, and the proof that it is one.**
    ///
    /// 09-05 moves the persistent outbox open off the launch-critical path by
    /// making ordinary foreground bootstrap wait for the app to draw. That claim
    /// is only worth something if "the app drew" is a fact rather than a
    /// heuristic, so this suite pins two separate things and keeps them apart.
    ///
    /// **The rendezvous** — one-shot, resumes every waiter, serves a late
    /// arrival immediately, and survives a cancelled waiter. Behavioural cases
    /// against ``FirstFrameSignal`` itself.
    ///
    /// **The wiring** — that the production app root actually emits it, from a
    /// real SwiftUI render callback, exactly once, and from exactly one place. A
    /// signal nobody emits is a launch that never proceeds; a signal two places
    /// emit is two definitions of "first frame" that can drift apart.
    ///
    /// Serialized because the render cases drive a real `UIWindow` through
    /// `Phase09RenderHarness`, and two of those running concurrently would each
    /// be laying out inside the other's run loop.
    @Suite("FirstFrameSignalTests — the first frame as an awaitable fact", .serialized)
    struct FirstFrameSignalTests {
        // MARK: - The rendezvous

        @Test("one emit resumes every parked waiter, and a late waiter never parks")
        func oneEmitResumesEveryWaiterAndLateArrivalsAreServed() async {
            let signal = FirstFrameSignal()
            #expect(!signal.hasEmitted)

            let resumed = Phase09Counter()
            let waiters = (0 ..< 100).map { index in
                Task {
                    await signal.wait()
                    resumed.record("waiter-\(index)")
                }
            }
            // Every waiter must actually be parked before the emit, or the case
            // would be satisfied by 100 late arrivals taking the fast path.
            let allParked = await phase09Settle { signal.waitingCount == 100 }
            #expect(allParked, "100 waiters must park on an unemitted signal")

            signal.emit()
            for waiter in waiters {
                await waiter.value
            }
            #expect(resumed.count == 100)
            #expect(signal.hasEmitted)
            #expect(signal.waitingCount == 0)

            // A waiter arriving after the frame returns without parking.
            await signal.wait()
            #expect(signal.waitingCount == 0)
        }

        @Test("a second emit is counted but resumes nothing — the frame happens once")
        func aSecondEmitIsCountedAndChangesNothing() async {
            let signal = FirstFrameSignal()
            signal.emit()
            signal.emit()
            signal.emit()
            #expect(signal.emitCount == 3)
            #expect(signal.hasEmitted)
            await signal.wait()
            #expect(signal.waitingCount == 0)
        }

        @Test("a cancelled waiter resumes and does not strand the others")
        func aCancelledWaiterDoesNotStrandTheOthers() async {
            let signal = FirstFrameSignal()
            // The waiter runs in its OWN unstructured task. A case that cancels
            // the task it is running on cancels Swift Testing's task: the
            // framework reports a skip, the run prints "N tests passed" and
            // exits 0, and this contract goes unchecked (09-02's finding).
            let doomed = Task { await signal.wait() }
            #expect(await phase09Settle { signal.waitingCount == 1 })
            doomed.cancel()
            await doomed.value
            #expect(signal.waitingCount == 0)
            #expect(!signal.hasEmitted, "a cancellation is not a first frame")
            #expect(!Task.isCancelled, "the test's own task must still be alive")

            let survivor = Task { await signal.wait() }
            #expect(await phase09Settle { signal.waitingCount == 1 })
            signal.emit()
            await survivor.value
            #expect(signal.waitingCount == 0)
        }

        // MARK: - The wiring

        @MainActor
        @Test("the app root emits the first-frame signal from one real render callback")
        func rootRenderCallbackEmitsExactlyOnce() async throws {
            // Half one: the modifier really is driven by a render, not by the
            // test calling it.
            let signal = FirstFrameSignal()
            _ = Phase09RenderHarness.render(
                Text(verbatim: "phase09-first-frame").hlEmitFirstFrame(signal),
                size: CGSize(width: 120, height: 60)
            )
            #expect(await phase09Settle { signal.emitCount >= 1 })
            #expect(signal.emitCount == 1, "one view lifetime is one first frame")
            #expect(signal.hasEmitted)

            // Half two: production actually applies it, to `RootView()`, from
            // exactly one place. Every verdict is bound to a `Bool` first — a
            // `#expect` on `source.contains(…)` pastes the whole file into the
            // failure log, and a production-source paste inside a RED log is how
            // a behavioural gate comes to look like a compile failure to the
            // regex that reads it.
            let root = try Phase09SignpostContractTests.declarationBody(
                "HealthLog/App/HealthLogApp.swift",
                containing: "var rootView"
            )
            let appliesToRootView = Self.occurrences(of: "RootView()", in: root) == 1
                && Self.occurrences(of: "hlEmitFirstFrame(", in: root) == 1
            let usesTheSharedSignal = Self.occurrences(of: "FirstFrameSignal.shared", in: root) == 1
            let emitters = try Self.productionFiles(naming: "hlEmitFirstFrame(")
            let oneEmitterBesideItsDefinition = emitters == [
                "HealthLog/App/FirstFrameSignal.swift",
                "HealthLog/App/HealthLogApp.swift"
            ]
            let rootEmitsTheFirstFrameSignal =
                appliesToRootView && usesTheSharedSignal && oneEmitterBesideItsDefinition
            #expect(rootEmitsTheFirstFrameSignal, "EXPECTED_RED: RootView did not emit the first-frame signal")
        }

        @MainActor
        @Test("a render without the modifier emits nothing — the modifier is what emits")
        func aRenderWithoutTheModifierEmitsNothing() async {
            let signal = FirstFrameSignal()
            _ = Phase09RenderHarness.render(
                Text(verbatim: "phase09-no-first-frame"),
                size: CGSize(width: 120, height: 60)
            )
            _ = await phase09Settle(yields: 200) { signal.emitCount >= 1 }
            #expect(signal.emitCount == 0)
            #expect(!signal.hasEmitted)
        }

        // MARK: - Helpers

        /// Count, never a short-circuiting probe: a `contains` that answers
        /// `true` and stops cannot tell one call site from two.
        static func occurrences(of needle: String, in haystack: String) -> Int {
            haystack.components(separatedBy: needle).count - 1
        }

        /// Production files whose comment-stripped source names `needle`,
        /// relative to the repository root, sorted.
        ///
        /// The stripper is local rather than borrowed from
        /// `Phase09SignpostContractTests`: that one records an issue when a file
        /// gains a block comment, which is a sound clause for the eight files it
        /// bounds and a thousand spurious issues on a repository-wide walk.
        static func productionFiles(naming needle: String) throws -> [String] {
            let production = Phase09SignpostContractTests.repositoryRoot()
                .appendingPathComponent("HealthLog")
            guard let walker = FileManager.default.enumerator(atPath: production.path) else { return [] }
            var hits: [String] = []
            for case let relative as String in walker where relative.hasSuffix(".swift") {
                let url = production.appendingPathComponent(relative)
                guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if occurrences(of: needle, in: Self.withoutCommentLines(source)) > 0 {
                    hits.append("HealthLog/\(relative)")
                }
            }
            return hits.sorted()
        }

        /// Drops whole-line comments. A doc comment that merely *names* a symbol
        /// must not satisfy a clause asking whether the symbol is called —
        /// including this suite's own prose, which names everything it forbids.
        static func withoutCommentLines(_ source: String) -> String {
            source
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.hasPrefix("*") && !$0.hasPrefix("/*") }
                .joined(separator: "\n")
        }
    }

#endif // !SWIFT_PACKAGE
