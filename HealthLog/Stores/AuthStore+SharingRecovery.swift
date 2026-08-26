import Foundation

public extension AuthStore {
    /// Reconciles the actor payload obtained by `APIClient` after a stable
    /// sharing refusal. Cache cleanup happens before the refreshed actor becomes
    /// observable, so stale selected-record snapshots cannot repaint beneath it.
    func handleSharingRecovery(_ event: SharingRecoveryEvent) async {
        // A reconciliation can suspend on `/auth/me`. If the operator signs
        // into another account while it is in flight, the old actor must never
        // clear or overwrite the replacement account's state.
        if let user = event.reconciledUser {
            switch phase {
            case let .authenticated(current), let .authenticating(current):
                guard current.id == user.id else { return }
            case .unknown, .unauthenticated, .standalone:
                return
            }
        }

        await sharingScopeCleanupHook?()
        guard let user = event.reconciledUser else { return }
        applySharingRecoveryUser(user)
    }
}
