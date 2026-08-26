import Foundation

// MARK: - 21-03 (D-14-06-C) — the bounded attach

/// The machinery behind `RefreshIntent.userInitiated`, in its own file.
///
/// Not a stylistic split: folding it into `SWRCoordinator.swift` pushed the
/// actor's declaration past SwiftLint's `type_body_length` threshold, which
/// would have meant recording a 291st accepted warning. An extension in a
/// separate file does not count toward the main declaration's body, so the
/// gate stays at 290/0 and the coordinator's core stays readable.
extension SWRCoordinator {
    /// How long a `.userInitiated` refresh will attach to an in-flight winner
    /// before issuing its own request.
    ///
    /// The number is a judgement, so it is stated rather than tuned: below
    /// about a second a pull that would have been served by a winner landing
    /// imminently starts costing a duplicate round-trip for nothing; much above
    /// two and the pull is back to being indistinguishable from a pull that did
    /// nothing, which is the entire complaint. 1.5 s sits between those, and is
    /// long enough that a healthy request (Phase 20 measured 0.266 s for 25
    /// parallel requests against the real server) is always attached rather
    /// than duplicated.
    public static let userInitiatedAttachBound: Duration = .milliseconds(1500)

    /// Holds a winner's outcome across the boundary between the task observing
    /// it and the caller deciding whether to keep waiting.
    private final class AttachBox: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: Result<any Sendable, any Error>?

        func finish(_ result: Result<any Sendable, any Error>) {
            lock.lock()
            defer { lock.unlock() }
            if outcome == nil { outcome = result }
        }

        func take() -> Result<any Sendable, any Error>? {
            lock.lock()
            defer { lock.unlock() }
            return outcome
        }
    }

    /// Await `winner` for at most `bound`. Returns its value if it lands in
    /// time, rethrows its error if it fails in time, and returns `nil` if the
    /// bound expires first.
    ///
    /// **The winner is never cancelled.** `Task.value` is not a cancellation
    /// point for the *awaiting* task, so a structured race would not release
    /// this caller at all — hence the observing task plus a box. When the bound
    /// expires the observer is cancelled (which does nothing to the winner, by
    /// design) and the winner runs on for its other waiters.
    nonisolated static func attach(
        to winner: Task<any Sendable, Error>,
        within bound: Duration
    ) async throws -> (any Sendable)? {
        let box = AttachBox()
        let observer = Task {
            do {
                try await box.finish(.success(winner.value))
            } catch {
                box.finish(.failure(error))
            }
        }
        defer { observer.cancel() }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: bound)
        while clock.now < deadline {
            if let outcome = box.take() { return try outcome.get() }
            try? await Task.sleep(for: .milliseconds(20))
        }
        // One last look: the winner may have landed inside the final interval.
        if let outcome = box.take() { return try outcome.get() }
        return nil
    }

    /// Says what a revalidation actually did, in closed words, so a later
    /// diagnosis can read it off a console instead of inferring it. The three
    /// modes are the three outcomes: `winner` ran the request, `attached`
    /// reused somebody else's, `issued` gave up waiting and ran its own.
    nonisolated static func logRefresh(mode: String, key: CacheKey) {
        // Cache keys are enum-shaped canonical paths (no user data) — operator-grade.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.cache.info(
            "swr-refresh mode=\(mode, privacy: .public) key=\(key.canonicalString, privacy: .public)"
        )
    }
}
