import SwiftUI
import Synchronization

/// **Phase 09 / plan 09-05 — the first frame, as something launch work can await.**
///
/// The launch tick used to open the persistent SwiftData outbox synchronously,
/// inside `AppContainer.init`, because `BGTaskScheduler.register` must run
/// before `applicationDidFinishLaunching` returns and the two were wired
/// together by convenience rather than by requirement. Plan 09-05 separates
/// them: registration stays synchronous, and the SQLite open moves behind a
/// single-flight handle that ordinary foreground bootstrap requests only once
/// the app has actually drawn.
///
/// "Once the app has actually drawn" has to be a *fact*, not a heuristic. A
/// `Task.yield`, a `DispatchQueue.main.async` hop, a short sleep, or the return
/// of `AppContainer.init` are all things that happen near the first frame and
/// none of them **is** the first frame — each one is satisfied by a launch that
/// never rendered at all, which is precisely the launch whose critical path this
/// plan is trying to shorten. This type carries the fact instead: it is resumed
/// from the one-shot SwiftUI render callback that owns first paint
/// (``SwiftUI/View/hlOnFirstPaint(_:)``, the same modifier behind
/// `hlSignpostFirstPaint`), and awaiting it is the only supported way to say
/// "after the app drew".
///
/// **One-shot, never re-armed.** A process has one first frame. `emit()` may be
/// called any number of times — a re-`onAppear` after a scene restoration, a
/// second window — and only the first one resumes waiters; every later call is
/// counted (``emitCount``) and otherwise ignored. A waiter that arrives *after*
/// the frame returns immediately rather than parking forever, which is the
/// difference between a rendezvous and a deadlock.
///
/// **Cancellation-safe.** A launch that is torn down before it draws must not
/// strand its bootstrap task. ``wait()`` installs a cancellation handler that
/// resumes the parked continuation, and the `cancelled` ticket set closes the
/// window where cancellation arrives before the continuation is installed.
final class FirstFrameSignal: Sendable {
    /// The process-wide signal. A process has exactly one first frame, so the
    /// production instance is a `let` on the type rather than a stored property
    /// on the composition root — the same shape `HLPerfSignpost.signposter`
    /// uses for the same reason. Tests never touch it: every seam that consumes
    /// a signal takes one as a parameter.
    static let shared = FirstFrameSignal()

    private struct State {
        var emitted = false
        var emitCount = 0
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        /// Tickets whose waiter was cancelled before it managed to park. Without
        /// this, a cancellation that lands between `wait()`'s entry and the
        /// continuation's installation would remove nothing and the waiter would
        /// park with nobody left to resume it.
        var cancelledTickets: Set<UUID> = []
    }

    private let state = Mutex(State())

    init() {}

    /// Whether the first frame has been reached.
    var hasEmitted: Bool {
        state.withLock { $0.emitted }
    }

    /// How many times a render callback reached this signal. The contract is
    /// that exactly one of them resumes waiters, not that exactly one arrives.
    var emitCount: Int {
        state.withLock { $0.emitCount }
    }

    /// Waiters currently parked. Read by tests to prove a bootstrap really is
    /// blocked on the frame rather than merely slow.
    var waitingCount: Int {
        state.withLock { $0.waiters.count }
    }

    /// Record that the app drew, and resume everyone waiting on it.
    func emit() {
        let parked: [CheckedContinuation<Void, Never>] = state.withLock { state in
            state.emitCount += 1
            guard !state.emitted else { return [] }
            state.emitted = true
            let waiting = Array(state.waiters.values)
            state.waiters.removeAll()
            return waiting
        }
        // Resumed outside the lock: a continuation resume can run arbitrary
        // caller code, and running it under a `Mutex` is how a re-entrant
        // waiter deadlocks a launch.
        for continuation in parked {
            continuation.resume()
        }
    }

    /// Suspend until the app has drawn. Returns immediately if it already has.
    func wait() async {
        if hasEmitted { return }
        let ticket = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeImmediately = state.withLock { state -> Bool in
                    if state.emitted { return true }
                    if state.cancelledTickets.remove(ticket) != nil { return true }
                    state.waiters[ticket] = continuation
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        } onCancel: {
            let parked = state.withLock { state -> CheckedContinuation<Void, Never>? in
                if let waiting = state.waiters.removeValue(forKey: ticket) { return waiting }
                if !state.emitted { state.cancelledTickets.insert(ticket) }
                return nil
            }
            parked?.resume()
        }
    }
}

extension View {
    /// Resume `signal` from this view's first real render.
    ///
    /// Built on ``SwiftUI/View/hlOnFirstPaint(_:)``, so the callback that
    /// resumes the signal is the very same one-shot render callback the
    /// first-paint signposts are emitted from — there is one notion of "this
    /// view drew" in the app, not two that can drift apart.
    func hlEmitFirstFrame(_ signal: FirstFrameSignal) -> some View {
        hlOnFirstPaint { signal.emit() }
    }
}
