import Foundation

// MARK: - R-A2 (1.4) — the two opt-in HealthKit observers start at launch

extension AppContainer {
    /// Arms the Apple Health dose observer and the State-of-Mind observer from
    /// the launch path instead of from `RootView`.
    ///
    /// **Why.** HealthKit wakes an app in the background for an observer query
    /// only when that query is registered again on every launch, early (Apple:
    /// set observer queries up in `application(_:didFinishLaunchingWithOptions:)`).
    /// Up to 1.3 both observers were armed from `RootView`'s phase task, after
    /// eight awaits, network calls among them, and only once a view had
    /// appeared. A launch without a scene never got there, so a dose logged in
    /// Apple Health waited for the next time someone opened the app.
    ///
    /// **When.** Once while the container is built, if this installation holds
    /// a signed-in account, and again on every authenticated admission
    /// (bootstrap, login), which covers an account whose id had to be healed
    /// first. Both stores arm only while their toggle is on, and both are
    /// idempotent, so the second call is a no-op rather than a second observer.
    /// Logout stops them through the stores' own `deactivateOnLogout()`.
    func armOptInHealthObserversAtLaunch() {
        authenticatedSessionRegistry.observeAdmissions { [weak self] _ in
            Task { @MainActor [weak self] in await self?.armOptInHealthObservers() }
        }
        Task { @MainActor [weak self] in await self?.armOptInHealthObservers() }
    }

    /// One arming pass. A process without a signed-in account arms nothing,
    /// exactly as `RootView` armed nothing outside `.authenticated`.
    func armOptInHealthObservers() async {
        guard let token = keychain.getString(forKey: KeychainKey.authToken), !token.isEmpty,
              let userID = keychain.getString(forKey: KeychainKey.userID), !userID.isEmpty else { return }
        await moodHealthSyncStore.activateIfEnabled()
        await medicationHealthSyncStore.startObservingIfEnabled()
    }
}
