import Foundation

// MARK: - KONTO (#151) — the deletion grace window for the confirmation screens

extension AuthStore {
    /// What the delete and reset screens may promise. The window length the
    /// server publishes (`accountDeletionGraceDays`, new in 1.46.0) decides
    /// first: its presence alone proves a server with the grace window, even
    /// before this installation has recorded the version. Without it the
    /// recorded version decides (unknown counts as older: erased at once).
    /// One read, no retry.
    func accountDeletionPolicy(defaults: UserDefaults = .standard) async -> AccountDeletionPolicy {
        if let days = await auth.accountDeletionGraceDays() {
            return AccountDeletionPolicy.resolve(serverHasGraceWindow: true, graceDays: days)
        }
        return AccountDeletionPolicy.initial(defaults: defaults)
    }
}
