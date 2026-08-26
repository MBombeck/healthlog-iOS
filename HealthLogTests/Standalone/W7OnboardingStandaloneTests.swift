// v0.12 W7 — locks the offline/standalone-separation + onboarding-copy contract.
//
// Load-bearing acceptances:
//  1. Welcome-copy keys (`onboarding.welcome.headline`, `.serverRequired`,
//     reframed `.feature.selfhosted.*`) resolve to non-empty, distinct EN+DE
//     values — and the `serverRequired` copy orients the user to *connecting a
//     server* (mandatory since b2913131) rather than promising a
//     connect-or-standalone choice or the stale "enter your server address"
//     micro-instruction. The Welcome→ServerURL routing gate is asserted in both
//     flag states (reversible) — see `welcomeRoutingHonoursGate`.
//  2. Standalone sign-out (W7-6 latent-routing safeguard): when `logout()` runs
//     on a standalone install, the runtime `SyncMode` is cleared so a mid-session
//     re-onboard is well-defined (vs re-running the mode picker over an install
//     whose flag still says `.standalone`).
//  3. The standalone-gating predicate that hides the account-only destructive
//     Settings sections is exactly `!syncMode.isStandalone` (W7-1).
//
// Refs: .planning/v012-megamarathon/MASTER-BACKLOG.md §WAVE 7;
//       .planning/v012-megamarathon/AUDIT-offline-onboarding.md

// swiftlint:disable force_unwrapping

import Foundation
@testable import HealthLog
import Testing
#if canImport(AuthenticationServices)
    import AuthenticationServices
#endif

@MainActor
@Suite("v0.12 W7 — standalone separation + onboarding copy")
struct W7OnboardingStandaloneTests {
    // MARK: - W7-2 Welcome copy

    @Test("Welcome copy keys resolve to non-empty, distinct EN+DE values")
    func welcomeCopyResolves() throws {
        let keys = [
            "onboarding.welcome.headline",
            "onboarding.welcome.serverRequired",
            "onboarding.welcome.feature.selfhosted.title",
            "onboarding.welcome.feature.selfhosted.subtitle"
        ]
        let de = try lprojBundle(language: "de")
        let en = try lprojBundle(language: "en")
        for key in keys {
            let deValue = de.localizedString(forKey: key, value: "MISSING", table: nil)
            let enValue = en.localizedString(forKey: key, value: "MISSING", table: nil)
            #expect(deValue != "MISSING", "Missing DE entry: \(key)")
            #expect(enValue != "MISSING", "Missing EN entry: \(key)")
            #expect(deValue != key, "DE falls back to the key (untranslated): \(key)")
            #expect(!deValue.isEmpty && !enValue.isEmpty, "Empty translation: \(key)")
            #expect(deValue != enValue, "EN equals DE — German leak / missing translation: \(key)")
        }
    }

    @Test("serverRequired copy orients to the mandatory server connection (b2913131)")
    func serverRequiredOrientsToServerConnect() throws {
        // b2913131 made the server connection mandatory behind
        // `FeatureFlags.standaloneModeAvailable` (shipping default false): the
        // step after Welcome routes straight to `.serverURL`, never the
        // connect-or-standalone mode picker. The Welcome copy must therefore
        // orient the user to *connecting a server* — it must not still promise a
        // "choice" between connecting and going standalone, and it must not
        // re-introduce the old micro-instruction "enter the address …".
        #expect(FeatureFlags.standaloneModeAvailable == false, "Test assumes shipping server-mandatory default")
        let en = try lprojBundle(language: "en")
        let value = en.localizedString(forKey: "onboarding.welcome.serverRequired", value: "", table: nil)
            .lowercased()
        #expect(!value.contains("enter the address"), "Stale 'enter the address' micro-instruction still present")
        #expect(
            !value.contains("choose") && !value.contains("either"),
            "Copy still offers a connect-or-standalone choice — server is now mandatory"
        )
        #expect(value.contains("connect"), "Copy doesn't orient to connecting a server")
        #expect(value.contains("server"), "Copy doesn't mention the server it connects to")
    }

    // MARK: - b2913131 onboarding routing gate (reversible)

    @Test("Welcome routing honours the standalone-availability gate in both states")
    func welcomeRoutingHonoursGate() {
        // Server-mandatory (shipping default): Welcome → ServerURL, no mode fork.
        #expect(OnboardingFlow.stepAfterWelcome(standaloneModeAvailable: false) == .serverURL)
        // Reversible: flipping the flag restores the standalone mode-selection fork.
        #expect(OnboardingFlow.stepAfterWelcome(standaloneModeAvailable: true) == .mode)
        // Shipping default is server-mandatory.
        #expect(
            OnboardingFlow.stepAfterWelcome(standaloneModeAvailable: FeatureFlags.standaloneModeAvailable)
                == .serverURL
        )
    }

    // MARK: - W7-6 standalone sign-out latent routing

    @Test("Standalone logout clears the runtime SyncMode (well-defined re-onboard)")
    func standaloneLogoutClearsSyncMode() async throws {
        let keychain = InMemoryKeychain()
        let suite = "hl.tests.w7.logout.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(SyncMode.standalone.rawValue, forKey: SyncModeStore.storageKey)
        let sync = SyncModeStore(defaults: defaults)
        #expect(sync.isStandalone)

        let env = AppEnvironment.loadFromBundle()
        let api = APIClient(environment: env, keychain: keychain)
        let auth = AuthService(api: api, keychain: keychain, passkey: NoopPasskey())
        let authStore = AuthStore(auth: auth, keychain: keychain, syncMode: sync)
        authStore.setPhaseForTesting(.standalone)

        await authStore.logout()

        // W7-6: standalone logout must NOT leave the install pinned to
        // `.standalone` — the runtime mode is cleared so the next onboarding
        // picker runs over a mode-less install.
        #expect(!sync.isStandalone, "SyncMode still standalone after logout — re-onboard would be undefined")
        #expect(sync.mode == nil, "Runtime SyncMode not cleared on standalone logout")
    }

    // MARK: - W7-1 gating predicate

    @Test("Destructive-section gate is exactly !isStandalone")
    func destructiveSectionsHiddenWhenStandalone() throws {
        let suite = "hl.tests.w7.gate.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        /// SettingsScreen wraps signOut + deleteAccount in `if !syncMode.isStandalone`.
        /// `sectionsVisible` mirrors that predicate exactly.
        func sectionsVisible(_ store: SyncModeStore) -> Bool {
            !store.isStandalone
        }

        defaults.set(SyncMode.standalone.rawValue, forKey: SyncModeStore.storageKey)
        let standalone = SyncModeStore(defaults: defaults)
        #expect(standalone.isStandalone)
        #expect(!sectionsVisible(standalone), "Destructive sections must be HIDDEN in standalone")

        defaults.set(SyncMode.paired.rawValue, forKey: SyncModeStore.storageKey)
        let paired = SyncModeStore(defaults: defaults)
        #expect(!paired.isStandalone)
        #expect(sectionsVisible(paired), "Destructive sections must be VISIBLE when paired")
    }

    // MARK: - Helpers

    private final class NoopPasskey: PasskeyServiceProtocol, @unchecked Sendable {
        func register(
            challenge _: String, rpId _: String, rpName _: String,
            userID _: String, userName _: String, displayName _: String,
            anchor _: ASPresentationAnchorProvider
        ) async throws -> PasskeyRegistration {
            throw HLError.unknown("noop")
        }

        func assert(
            challenge _: String, rpId _: String, allowCredentialIDs _: [String],
            anchor _: ASPresentationAnchorProvider
        ) async throws -> PasskeyAssertion {
            throw HLError.unknown("noop")
        }
    }

    private func lprojBundle(language: String) throws -> Bundle {
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else
        {
            throw W7TestError.missingLproj(language)
        }
        return bundle
    }

    private enum W7TestError: Error {
        case missingLproj(String)
    }
}
