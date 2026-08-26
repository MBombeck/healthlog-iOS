import Foundation

public extension AIConsentStore {
    /// Clears every user-scoped input that can resolve an AI mode when an
    /// authenticated session ends. External grants/declines are consent records;
    /// the on-device flag and pending intents are UI preferences, but they are
    /// still personal choices that a second user on the same device must not
    /// inherit. BYO key bytes remain the logout cascade's separate responsibility.
    func resetForSessionEnd() {
        setOnDeviceEnabled(false)
        setOnlineIntentPending(false)
        setBYOKeyIntentPending(false)
        for provider in AIProvider.allCases where provider != .unconfigured {
            revoke(for: provider)
        }
        revokeServerManaged()
        revokeAllBYO()
    }
}
