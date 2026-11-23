import Foundation

extension AppContainer {
    /// Tells the background coordinator what a wake may do. Read at every
    /// wake, so a sign-in, a sign-out or a late HealthKit setup takes effect
    /// on the next one. The token check reads the Keychain directly because a
    /// wake can arrive before the auth store has resolved its phase.
    func wireBackgroundWakeScope(backgroundSync: BackgroundSyncCoordinator) {
        let keychain = keychain
        let healthKitAvailable = healthKit != nil
        backgroundSync.attachWakeScopeProvider { [weak hkReadinessStore, weak authStore] in
            let signedIn = keychain.getString(forKey: KeychainKey.authToken) != nil
            let (requested, signedOut) = await MainActor.run {
                let signedOut = if case .unauthenticated? = authStore?.phase { true } else { false }
                return (hkReadinessStore?.hasEverRequestedAuthorization ?? false, signedOut)
            }
            return BackgroundWakeScope.resolve(
                signedIn: signedIn,
                healthKitAvailable: healthKitAvailable,
                healthKitRequested: requested,
                sessionSaysSignedOut: signedOut
            )
        }
    }
}
