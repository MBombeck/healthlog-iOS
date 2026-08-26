import Foundation
import Observation

/// Coordinates the transient "Eintrag entfernt — Rückgängig" affordance the
/// `AuthenticatedShell` renders via `HLUndoToast`. Stores enqueue an action
/// on their optimistic-delete path, the coordinator surfaces it for a
/// bounded TTL window, and the user can either tap `Rückgängig` (closure
/// runs) or let the window expire (action silently drops).
///
/// **Single-slot.** Only one action is live at a time; enqueueing a new one
/// cancels the previous TTL task and replaces `current`. The dropped action
/// is treated as "implicitly accepted" — its undo closure does not run, the
/// previous destructive intent stands.
///
/// **TTL mechanics.** A `Task.sleep(for:)` covers the countdown; expiry
/// fires inside the same MainActor so observers see a single `current`
/// transition. Replace/dismiss/perform all cancel the in-flight task so we
/// never get a delayed "ghost" auto-expire kicking back in after the user
/// already acted.
///
/// **Sendable contract.** The undo closure is `@Sendable async () -> Void`
/// because stores typically restore optimistic snapshots from inside an
/// already-async call site; the closure is owned by the action and runs on
/// whatever actor the store is bound to (stores are `@MainActor`).
@MainActor
@Observable
public final class UndoCoordinator {
    /// Reason an action is leaving the surface. Surfaces use this to decide
    /// whether to fire follow-up affordances; the toast itself doesn't
    /// branch on it (it just animates out).
    public enum DismissReason: Sendable {
        /// User tapped `Rückgängig` — `performUndo` ran the closure.
        case undone
        /// TTL elapsed — closure did NOT run; deletion stands.
        case expired
        /// User tapped outside the pill — closure did NOT run.
        case userDismissed
        /// Store cleared the action manually (replaced by a different
        /// store, logout, or a downstream failure that means the
        /// optimistic delete needs to roll back without an undo prompt).
        case cancelled
    }

    /// Snapshot of the affordance the toast is currently showing. Stores
    /// the actual undo body so `performUndo()` doesn't need to look up
    /// the queue separately.
    public struct Action: Identifiable, Sendable {
        public let id: UUID
        /// Localized message body — already resolved by the caller so the
        /// toast doesn't need to know about translation keys.
        public let message: String
        /// Original TTL the action was scheduled with; the toast renders it
        /// in the VoiceOver label without re-deriving from `expiresAt`.
        public let ttl: TimeInterval
        /// Absolute deadline; helpful for tests that want to verify the
        /// expiry was scheduled in the future.
        public let expiresAt: Date
        /// Closure that rolls the optimistic delete back. Runs on whatever
        /// actor the closure was defined against.
        public let undo: @Sendable () async -> Void

        public init(
            id: UUID,
            message: String,
            ttl: TimeInterval,
            expiresAt: Date,
            undo: @escaping @Sendable () async -> Void
        ) {
            self.id = id
            self.message = message
            self.ttl = ttl
            self.expiresAt = expiresAt
            self.undo = undo
        }
    }

    /// Live action the host should render. `nil` when no undo affordance is
    /// active. Observers (the shell view) react to changes via SwiftUI's
    /// `@Observable` tracking.
    public private(set) var current: Action?

    /// Last dismissal reason, surfaced for tests. Wraps to allow the host
    /// to react to a particular reason if it ever needs to (no production
    /// caller does today — `current = nil` is the only signal the view
    /// needs).
    public private(set) var lastDismissReason: DismissReason?

    /// In-flight TTL countdown. Cancellation is the source of truth for
    /// "no auto-expire is scheduled"; we deliberately do NOT also track a
    /// boolean so the cancellation path stays the only invalidation rule.
    private var expirationTask: Task<Void, Never>?

    public init() {}

    /// Enqueue an undoable action. Cancels any pre-existing action's
    /// countdown without invoking its closure (previous deletion stands).
    /// Returns the freshly enqueued action so call-sites can correlate the
    /// id back to their own tracking (the existing store paths don't need
    /// the id today, but the return shape keeps the API symmetric with
    /// future replay-loop integrations).
    @discardableResult
    public func enqueue(
        message: String,
        ttl: TimeInterval = 5,
        undo: @escaping @Sendable () async -> Void
    ) -> Action {
        // Cancel the previous countdown without firing the previous undo.
        // Whatever the previous action represented, its deletion is now
        // implicitly accepted — UI affordance for it is gone.
        expirationTask?.cancel()
        expirationTask = nil

        let id = UUID()
        let now = Date.now
        let action = Action(
            id: id,
            message: message,
            ttl: ttl,
            expiresAt: now.addingTimeInterval(ttl),
            undo: undo
        )
        current = action
        lastDismissReason = nil
        scheduleExpiration(for: id, ttl: ttl)
        return action
    }

    /// Run the currently-queued undo closure and clear the slot. No-op when
    /// no action is queued. Cancels the in-flight countdown so a late
    /// auto-expire can't double-dismiss after the user already tapped
    /// undo.
    public func performUndo() async {
        guard let action = current else { return }
        expirationTask?.cancel()
        expirationTask = nil
        current = nil
        lastDismissReason = .undone
        await action.undo()
    }

    /// Drop the current action without invoking its undo closure. Used by
    /// the toast's outside-tap dismissal, by stores that need to clear the
    /// slot after a network failure already rolled the optimistic state
    /// back, and by the shell on logout / account-deletion cleanup.
    public func dismiss(reason: DismissReason = .userDismissed) {
        guard current != nil else { return }
        expirationTask?.cancel()
        expirationTask = nil
        current = nil
        lastDismissReason = reason
    }

    // MARK: - Internals

    private func scheduleExpiration(for actionID: UUID, ttl: TimeInterval) {
        // Convert TimeInterval to nanoseconds. The `Duration` API would
        // require iOS 16 + millisecond granularity which is fine, but
        // staying on the nanoseconds variant keeps the call ergonomic
        // when the TTL comes back as a TimeInterval. Negative / zero
        // TTLs flush immediately, which makes the value space safe for
        // tests that pass `ttl: 0` to assert "no auto-expire is ever
        // scheduled".
        let nanos: UInt64 = ttl > 0 ? UInt64(ttl * 1_000_000_000) : 0
        expirationTask = Task { @MainActor [weak self] in
            if nanos > 0 {
                try? await Task.sleep(nanoseconds: nanos)
            }
            // Cancellation = a replace or manual dismiss already ran;
            // bail without touching state so we don't clobber the new
            // current value.
            if Task.isCancelled { return }
            guard let self else { return }
            // Identity-check the action id — a replace that landed
            // between sleep end and this runloop pass would have set
            // a new `current`; we must not wipe it.
            guard current?.id == actionID else { return }
            current = nil
            lastDismissReason = .expired
            expirationTask = nil
        }
    }
}
