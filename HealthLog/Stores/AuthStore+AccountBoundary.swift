import Foundation
import Synchronization

/// Serializes authentication against account-deletion reconciliation. The lock
/// spans network admission and every asynchronous deletion cleanup stage, so a
/// replacement session cannot persist state while its predecessor still owns a
/// destructive cache/outbox/consent cascade.
@MainActor
final class AuthAccountBoundaryTransition {
    enum Owner: Equatable {
        case authentication
        case deletedAccount
    }

    private struct Waiter {
        let id: UUID
        let owner: Owner
        let cancellation: CancellationSignal
        let continuation: CheckedContinuation<Bool, Never>
    }

    private final class CancellationSignal: Sendable {
        private let cancelled = Mutex(false)

        var isCancelled: Bool {
            cancelled.withLock { $0 }
        }

        func cancel() {
            cancelled.withLock { $0 = true }
        }
    }

    private var owner: Owner?
    private var waiters: [Waiter] = []

    var deletionOwnsTransition: Bool {
        owner == .deletedAccount
    }

    /// Returns explicit ownership. A cancelled queued task completes with
    /// `false`; only a `true` result may install a matching `defer release`.
    func acquireOwnership(_ requestedOwner: Owner) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard owner != nil else {
            owner = requestedOwner
            return true
        }

        let id = UUID()
        let cancellation = CancellationSignal()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, !cancellation.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waiters.append(
                    Waiter(
                        id: id,
                        owner: requestedOwner,
                        cancellation: cancellation,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            // Mark synchronously so `release` can never hand ownership to this
            // waiter, even if its MainActor cleanup is queued behind release.
            cancellation.cancel()
            Task { @MainActor [weak self] in
                self?.cancelWaiter(id: id)
            }
        }
    }

    /// Compatibility surface for existing deterministic boundary probes.
    /// Production admission uses `acquireOwnership` so cancellation can be
    /// handled explicitly before installing a matching release.
    func acquire(_ requestedOwner: Owner) async {
        _ = await acquireOwnership(requestedOwner)
    }

    func release(_ releasingOwner: Owner) {
        precondition(owner == releasingOwner, "account-boundary transition released by a non-owner")
        owner = nil
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            guard !next.cancellation.isCancelled else {
                next.continuation.resume(returning: false)
                continue
            }
            owner = next.owner
            next.continuation.resume(returning: true)
            break
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }
}

extension AuthStore {
    func beginDeletedAccountTransition() async -> Bool {
        await accountBoundaryTransition.acquireOwnership(.deletedAccount)
    }

    func finishDeletedAccountTransition() {
        accountBoundaryTransition.release(.deletedAccount)
    }

    func beginAuthenticationTransition() async -> Bool {
        await accountBoundaryTransition.acquireOwnership(.authentication)
    }

    func finishAuthenticationTransition() {
        accountBoundaryTransition.release(.authentication)
    }

    var deletionOwnsAccountBoundary: Bool {
        accountBoundaryTransition.deletionOwnsTransition
    }
}
