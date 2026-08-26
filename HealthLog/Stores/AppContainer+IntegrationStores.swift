import Foundation

// MARK: - Third-party integration stores phase

extension AppContainer {
    /// Bundle of the Settings-surface third-party integration stores
    /// (passkey-management, Withings, WHOOP, Oura, Polar, Fitbit, Nightscout,
    /// self-hosted avatar). Each wraps its already-built repo so the screens go
    /// through Store→Repo, not in-View API. The `public let` handles stay on
    /// `AppContainer` (this just feeds them) so call-sites are unchanged.
    struct IntegrationStoresBundle {
        let passkeyManagement: PasskeyManagementStore
        /// Parity 2.2 — active sessions. Grouped with the passkey store because
        /// both back the same account-security surface.
        let sessions: SessionsStore
        /// Parity 2.3 — forced second-factor enrolment gate.
        let mfaEnrollmentGate: MfaEnrollmentGateStore
        let withings: WithingsIntegrationStore
        let whoop: WhoopIntegrationStore
        let oura: OuraIntegrationStore
        let polar: PolarIntegrationStore
        let fitbit: FitbitIntegrationStore
        let strava: StravaIntegrationStore
        let nightscout: NightscoutIntegrationStore
        let avatar: AvatarStore
    }

    /// Factory — constructs the integration stores VERBATIM from the prior
    /// inline `init` block (same args, same order, same captures), so the move
    /// is behaviour-identical. `@MainActor` because the stores are
    /// `@MainActor @Observable`.
    ///
    /// `whoopBaseURL` is captured by value (as before): `reloadEnvironment()`
    /// only fires at onboarding, long before the WHOOP connect surface is
    /// reachable, so a value capture is safe. The avatar store's
    /// `refreshProfile` weakly captures the passed-in `settingsStore` so an
    /// upload / delete re-loads the profile (flipped `?v=` cache-buster).
    @MainActor
    static func makeIntegrationStores(
        passkeyRepo: PasskeyRepository,
        sessionsRepo: SessionsRepository,
        mfaEnrollmentRepo: MfaEnrollmentRepository,
        withingsRepo: WithingsRepository,
        whoopRepo: WhoopRepository,
        whoopBaseURL: URL?,
        authenticatedSessionRegistry: AuthenticatedSessionLeaseRegistry,
        userIDProvider: @escaping @MainActor () -> String?,
        ouraRepo: OAuthIntegrationRepository,
        polarRepo: OAuthIntegrationRepository,
        fitbitRepo: OAuthIntegrationRepository,
        stravaRepo: OAuthIntegrationRepository,
        nightscoutRepo: NightscoutRepository,
        avatarRepo: AvatarRepository,
        settingsStore: SettingsStore
    ) -> IntegrationStoresBundle {
        let settingsStoreReference = settingsStore
        return IntegrationStoresBundle(
            passkeyManagement: PasskeyManagementStore(repo: passkeyRepo),
            sessions: SessionsStore(repo: sessionsRepo),
            mfaEnrollmentGate: MfaEnrollmentGateStore(repo: mfaEnrollmentRepo),
            withings: WithingsIntegrationStore(repo: withingsRepo),
            // WHOOP connect runs in an in-app `ASWebAuthenticationSession` (B5
            // cookie round-trip — open `/api/whoop/connect` itself as the start URL).
            whoop: WhoopIntegrationStore(
                repo: whoopRepo,
                connector: WhoopConnectService(),
                baseURLProvider: { whoopBaseURL },
                authenticatedSessionRegistry: authenticatedSessionRegistry,
                userIDProvider: userIDProvider
            ),
            // v1.18.7 web-parity (❌-7) — Oura / Polar / Fitbit / Nightscout stores.
            oura: OuraIntegrationStore(repo: ouraRepo),
            polar: PolarIntegrationStore(repo: polarRepo),
            fitbit: FitbitIntegrationStore(repo: fitbitRepo),
            strava: StravaIntegrationStore(repo: stravaRepo),
            nightscout: NightscoutIntegrationStore(repo: nightscoutRepo),
            // v0.8.0 W11 — avatar store. `refreshProfile` re-loads the user
            // profile after an upload / delete so the new `avatarUrl` (with the
            // flipped `?v=` cache-buster) propagates to the display surfaces.
            avatar: AvatarStore(
                repo: avatarRepo,
                refreshProfile: { [weak settingsStoreReference] in
                    await settingsStoreReference?.load()
                }
            )
        )
    }
}
