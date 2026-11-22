import Foundation
import Synchronization

/// **#188 (1) — a budgeted pass may start a reload, it must not own it.**
///
/// Waits for `task` (a reload running in its own, unstructured task) until it
/// finishes or until the *caller* is cancelled, whichever comes first. The
/// caller's cancellation never reaches `task`: the 250 ms foreground deadline
/// stops waiting, the reload keeps running and still delivers its result to
/// the store. Awaiting `task.value` directly would not do: it ignores the
/// caller's cancellation and would hold the foreground pass open until the
/// network answered.
enum OwnedReloadWait {
    static func untilDoneOrCancelled(_ task: Task<Void, Never>) async {
        let gate = Gate()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if gate.park(continuation) { continuation.resume() }
                Self.resumeWhenDone(task, gate: gate)
            }
        } onCancel: {
            gate.open()
        }
    }

    /// Built outside any actor so the watcher closure is not `@MainActor`.
    private static func resumeWhenDone(_ task: Task<Void, Never>, gate: Gate) {
        Task {
            await task.value
            gate.open()
        }
    }

    /// One continuation, resumed exactly once, by whichever side comes first.
    final class Gate: Sendable {
        private struct State {
            var opened = false
            var parked: CheckedContinuation<Void, Never>?
        }

        private let state = Mutex(State())

        /// Parks `continuation`; `true` when the gate is already open and the
        /// caller must resume it itself.
        func park(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
            state.withLock { state in
                if state.opened { return true }
                state.parked = continuation
                return false
            }
        }

        func open() {
            let parked = state.withLock { state -> CheckedContinuation<Void, Never>? in
                guard !state.opened else { return nil }
                state.opened = true
                defer { state.parked = nil }
                return state.parked
            }
            parked?.resume()
        }
    }
}
