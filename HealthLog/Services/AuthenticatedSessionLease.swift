import Foundation
import Synchronization

/// Immutable identity currency captured before authenticated work suspends.
///
/// Later plans consume this value immediately before every observable or
/// external effect. Cancellation and registry currency are intentionally
/// checked together so cooperative task cancellation is never the only fence.
struct AuthenticatedSessionLease: Sendable {
    let ownerID: String
    let generation: UInt64

    private let current: @Sendable () -> Bool

    init(
        ownerID: String,
        generation: UInt64,
        current: @escaping @Sendable () -> Bool
    ) {
        self.ownerID = ownerID
        self.generation = generation
        self.current = current
    }

    var isCurrent: Bool {
        !Task.isCancelled && current()
    }

    /// **14-06 — registry currency ALONE, deliberately without the cancellation
    /// fold that ``isCurrent`` applies.**
    ///
    /// ``isCurrent`` answers "may this effect publish DATA?", and folding
    /// cancellation in is right for that question: a cancelled effect's result
    /// is not wanted. But it makes two very different situations
    /// indistinguishable, and settling a loading flag needs to tell them apart:
    ///
    /// - **cancelled, generation unchanged** — this load raised the flag and
    ///   nobody else has taken ownership of it. It MUST lower it, or the
    ///   skeleton stays up for the life of the process. That is the operator's
    ///   blank medications list.
    /// - **generation moved on** — a newer authenticated owner is here and its
    ///   own load is in flight. This one must publish NOTHING, including "not
    ///   loading": lowering the flag would clear a skeleton the *new* account is
    ///   legitimately showing. That is a retired generation publishing, which
    ///   09-06's invariant forbids.
    ///
    /// 13-03 lowered the flag unconditionally, which is correct for the first
    /// case and wrong for the second. The distinction was never expressible
    /// because the only predicate available folded the two together — which is
    /// the same root cause the medications strand has.
    var ownsRegistryGeneration: Bool {
        current()
    }

    func requireCurrent() throws {
        try Task.checkCancellation()
        guard current() else { throw CancellationError() }
    }
}

/// Lock-isolated source of authenticated owner/generation leases.
///
final class AuthenticatedSessionLeaseRegistry: Sendable {
    private struct State: Sendable {
        var generation: UInt64 = 0
        var ownerID: String?
    }

    private let state = Mutex(State())
    /// **09-03 — the admission signal, for composition-owned state that has to
    /// re-open when a new authenticated owner appears.**
    ///
    /// ``activate(ownerID:)`` is the one statement every login path in the app
    /// reaches (`AuthStore.phase`'s `didSet` since 07-09), so it is the only
    /// place a "the next authenticated composition has begun" fact exists
    /// without a per-login-path list that a new path can forget to join.
    private let admissionObservers = Mutex<[@Sendable (String) -> Void]>([])

    /// Subscribe to authenticated admissions. Observers fire after the registry
    /// state is committed, outside the lock, in registration order.
    func observeAdmissions(_ observer: @escaping @Sendable (_ ownerID: String) -> Void) {
        admissionObservers.withLock { $0.append(observer) }
    }

    @discardableResult
    func activate(ownerID: String) -> AuthenticatedSessionLease? {
        guard !ownerID.isEmpty else { return nil }
        let generation = state.withLock { state in
            state.generation &+= 1
            state.ownerID = ownerID
            return state.generation
        }
        for observer in admissionObservers.withLock({ $0 }) {
            observer(ownerID)
        }
        return AuthenticatedSessionLease(
            ownerID: ownerID,
            generation: generation,
            current: { [weak self] in
                self?.isCurrent(ownerID: ownerID, generation: generation) ?? false
            }
        )
    }

    func capture(ownerID: String) -> AuthenticatedSessionLease? {
        guard !ownerID.isEmpty else { return nil }
        guard let generation = state.withLock({ state in
            state.ownerID == ownerID ? state.generation : nil
        }) else {
            return nil
        }
        return AuthenticatedSessionLease(
            ownerID: ownerID,
            generation: generation,
            current: { [weak self] in
                self?.isCurrent(ownerID: ownerID, generation: generation) ?? false
            }
        )
    }

    func invalidate() {
        state.withLock { state in
            state.generation &+= 1
            state.ownerID = nil
        }
    }

    private func isCurrent(ownerID: String, generation: UInt64) -> Bool {
        state.withLock { state in
            state.ownerID == ownerID && state.generation == generation
        }
    }
}

/// Composition-owned primitives that Plan 06-05 will order around terminal
/// cleanup. This plan exposes the surface only; it does not wire a logout,
/// deletion, unauthorized, or server-switch path.
struct AuthenticatedSessionBoundaryHooks: Sendable {
    let invalidate: @Sendable () -> Void
    let awaitQuiescence: @Sendable () async -> Void
    let activate: @Sendable (_ ownerID: String) -> Void
}
