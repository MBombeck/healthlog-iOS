// Drives real App-target screens through a real `AppContainer`; neither exists
// in the SPM library build.
#if !SWIFT_PACKAGE

    import AuthenticationServices
    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing

    /// **Phase 09 / plan 09-03 — the configured server is read once, not per frame.**
    ///
    /// Four audited surfaces resolved the configured server address out of the
    /// Keychain from inside a SwiftUI `body`: the onboarding auth step (three
    /// times per evaluation — the web-handoff gate twice and the privacy link
    /// once), Settings → About, Settings → Server (three times: the host row, the
    /// region row and the version task's identity) and Settings → Security. One
    /// `AppEnvironment.resolve` is up to two `SecItemCopyMatching` round-trips,
    /// and SwiftUI evaluates a body whenever it likes.
    ///
    /// These cases count the Keychain queries a render performs, and they count
    /// what the render produced, because zero queries is also what a body that
    /// never ran reports.
    @MainActor
    @Suite("Configured-server snapshot — audited render paths", .serialized)
    struct SettingsServerSnapshotTests {
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

        private static let configuredHost = "meinserver.example.com"

        /// About stacks four cards and the Links card is the third; a
        /// phone-height window leaves it below the fold, where a pixel witness
        /// would compare two identical images of the cards above it.
        private static let tallEnoughForEveryCard = CGSize(width: 393, height: 2200)

        /// Composes the container the way the app does: seed the Keychain, then
        /// resolve the environment from it exactly once — which is the boundary
        /// this plan says the resolution belongs at.
        private func makeContainer(
            host: String = configuredHost
        ) -> (AppContainer, Phase09CountingKeychain) {
            let keychain = Phase09CountingKeychain()
            keychain.seed("https://\(host)", forKey: KeychainKey.serverURL)
            let container = AppContainer(
                environment: AppEnvironment.resolve(keychain: keychain),
                keychain: keychain,
                passkey: NoopPasskey()
            )
            return (container, keychain)
        }

        // MARK: - The counted contract

        @Test("an audited SwiftUI body performs no Keychain read")
        func bodyPerformsNoKeychainRead() {
            let (container, keychain) = makeContainer()

            // Everything above is composition. The render is what is measured.
            keychain.arm()
            let painted = Phase09RenderHarness.render(
                NavigationStack { SettingsAboutScreen() }
                    .environment(\.appContainer, container),
                size: Self.tallEnoughForEveryCard
            )
            keychain.disarm()

            // **The render happened, and it consulted the configured server.**
            // "Zero Keychain reads" is also the honest report of a body that
            // never ran, so the same screen is rendered against a container with
            // no server configured: the privacy row is `@ViewBuilder`-gated on a
            // non-`nil` URL, so the configured render must lay out strictly more
            // than the unconfigured one.
            let unconfigured = AppContainer(
                environment: AppEnvironment.resolve(keychain: Phase09CountingKeychain()),
                keychain: Phase09CountingKeychain(),
                passkey: NoopPasskey()
            )
            let withoutServer = Phase09RenderHarness.render(
                NavigationStack { SettingsAboutScreen() }
                    .environment(\.appContainer, unconfigured),
                size: Self.tallEnoughForEveryCard
            )
            #expect(unconfigured.configuredServer.baseURL == nil)
            #expect(!painted.pixels.isEmpty)
            #expect(
                painted.pixels != withoutServer.pixels,
                "the configured render must paint the privacy link the unconfigured one omits"
            )

            let reads = keychain.readsWhileArmed
            #expect(
                reads.isEmpty,
                "EXPECTED_RED: SwiftUI body performed a Keychain read"
            )
        }

        // MARK: - …and the links it renders are still the configured server's

        @Test("the rendered links resolve against the configured server")
        func renderedLinksUseTheConfiguredServer() {
            let (container, _) = makeContainer()
            let server = container.configuredServer

            #expect(server.host == Self.configuredHost)
            #expect(server.privacyPolicyURL?.host == Self.configuredHost)
            #expect(server.privacyPolicyURL?.path == "/privacy")
            #expect(server.accountSecurityURL?.host == Self.configuredHost)
            #expect(server.accountSecurityURL?.path == "/settings/security")
            #expect(server.region == .selfHosted)
            // #65 — a self-hosted host this build carries no association for.
            #expect(server.supportsPasskeys == false)
            #expect(server.prefersWebHandoff)
        }

        @Test("the demo host keeps the native form and reads as its own region")
        func demoHostKeepsNativeForm() {
            let (container, _) = makeContainer(host: "demo.healthlog.dev")
            let server = container.configuredServer
            #expect(server.region == .demo)
            #expect(server.prefersWebHandoff == false)
        }

        /// The snapshot must not be a value frozen at launch: an explicit
        /// environment revision — what both write paths (`ServerURLStep` and
        /// `AppContainer.switchServer`) run after persisting a new address — has
        /// to move it, or the UI would show the previous host forever.
        @Test("an explicit environment revision moves the snapshot")
        func environmentRevisionMovesTheSnapshot() async {
            let (container, keychain) = makeContainer()
            #expect(container.configuredServer.host == Self.configuredHost)

            keychain.seed("https://zweiter.example.com", forKey: KeychainKey.serverURL)
            await container.reloadEnvironment()

            #expect(container.configuredServer.host == "zweiter.example.com")
            #expect(container.configuredServer.privacyPolicyURL?.host == "zweiter.example.com")
        }

        /// Without a container there is no configured instance, so the surfaces
        /// fall back to the build's own bundle answer — exactly what they did
        /// before the snapshot existed.
        @Test("no container falls back to the bundle answer, not to a guess")
        func noContainerFallsBackToTheBundle() {
            let bundleBase = AppEnvironment.loadFromBundle().baseURL
            #expect(ConfiguredServerSnapshot.bundleFallback.baseURL == bundleBase)
            #expect(ConfiguredServerSnapshot.unconfigured.privacyPolicyURL == nil)
            #expect(ConfiguredServerSnapshot.unconfigured.accountSecurityURL == nil)
            #expect(ConfiguredServerSnapshot.unconfigured.region == nil)
            #expect(ConfiguredServerSnapshot.unconfigured.prefersWebHandoff == false)
        }
    }

#endif // !SWIFT_PACKAGE
