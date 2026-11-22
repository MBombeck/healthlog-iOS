#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    /// **Die Tests, die gefehlt haben.**
    ///
    /// b249 hat die eingebaute Serveradresse entfernt; seither kommt sie
    /// ausschliesslich aus `KeychainKey.serverURL`. Der Umbau war fuer den
    /// frischen Start gedacht und ist an der BESTEHENDEN Installation
    /// gescheitert: wer bis dahin den eingebauten Standard benutzt hat, hatte
    /// dort nie etwas hinterlegt und stand nach dem Update ohne Adresse da —
    /// mit gueltiger Anmeldung, aber vor einem Anmeldeformular, dessen jeder
    /// Knopf an `HLError.serverNotConfigured` scheitern musste.
    ///
    /// Der Fehler ist ausgeliefert worden, weil KEIN Test ein Update
    /// simuliert hat: jeder bestehende Test startet entweder mit sauberem
    /// Zustand oder mit gesetztem Schluesselbund. Genau diese Luecke schliesst
    /// diese Datei — der Ausgangszustand ist ueberall „angemeldet, aber ohne
    /// Adresse".
    @Suite("R1 — Installation ohne Serveradresse", .mockURLSession)
    struct NoServerRecoveryTests {
        // MARK: - Erkennen

        @MainActor
        @Suite("Erkennen: ohne Adresse fuehrt jeder Weg zur Adressfrage")
        struct Detection {
            @Test("Anmeldeschritt ohne Adresse wird zum Adress-Schritt")
            func authWithoutAddressBecomesServerURL() {
                #expect(
                    OnboardingFlow.resolveStep(.auth, hasServerAddress: false) == .serverURL,
                    "Ohne Adresse darf kein Anmeldeversuch angeboten werden, von dem die App weiss, dass er scheitert."
                )
            }

            @Test("Mit Adresse bleibt der Anmeldeschritt der Anmeldeschritt")
            func authWithAddressStays() {
                #expect(
                    OnboardingFlow.resolveStep(.auth, hasServerAddress: true) == .auth
                )
            }

            @Test("Kein anderer Schritt wird umgeleitet")
            func otherStepsUntouched() {
                for step in [
                    OnboardingFlow.Step.welcome, .serverURL,
                    .healthKit, .notifications, .aiSource, .anamnesis, .baselineProfile, .done
                ] {
                    #expect(
                        OnboardingFlow.resolveStep(step, hasServerAddress: false) == step,
                        "Nur der Anmeldeschritt haengt an der Adressfrage."
                    )
                }
            }

            @Test("Angemeldet ohne Adresse: das Produkt bekommt ein Gate davor")
            func authenticatedWithoutAddressIsGated() {
                let user = User(id: "u1", email: nil, username: nil, displayName: nil, createdAt: .now)
                #expect(
                    RootView.needsServerAddressGate(phase: .authenticated(user), hasServerAddress: false),
                    "Eine angemeldete Installation ohne Adresse darf nicht in eine Huelle laufen, in der jede Flaeche scheitert."
                )
                #expect(
                    RootView.needsServerAddressGate(phase: .authenticated(user), hasServerAddress: true) == false
                )
            }

            @Test("Vor der Anmeldung uebernimmt der Onboarding-Flow, nicht das Gate")
            func preAuthPhasesAreNotGated() {
                let user = User(id: "u1", email: nil, username: nil, displayName: nil, createdAt: .now)
                #expect(RootView.needsServerAddressGate(phase: .unauthenticated, hasServerAddress: false) == false)
                #expect(RootView.needsServerAddressGate(phase: .unknown, hasServerAddress: false) == false)
                #expect(
                    RootView.needsServerAddressGate(phase: .authenticating(user), hasServerAddress: false) == false
                )
            }
        }

        // MARK: - Die Uebernahme beim Update

        @MainActor
        @Suite("Update: bestehende Anmeldung ohne Adresse", .serialized)
        struct UpgradeFromBundledServer {
            /// Der Zustand, den b249 erzeugt hat und den kein Test hatte: der
            /// Schluesselbund traegt Token + User-ID (die Installation war
            /// angemeldet), aber KEINE `serverURL` — die alte App brauchte
            /// keine, weil sie eine eingebaute mitbrachte.
            private func upgradedInstallKeychain() -> InMemoryKeychain {
                let keychain = InMemoryKeychain()
                try? keychain.setString("bearer-from-b248", forKey: KeychainKey.authToken)
                try? keychain.setString("user-abc-123", forKey: KeychainKey.userID)
                return keychain
            }

            @Test("Nach dem Update gibt es keine Adresse mehr")
            func resolveHasNoAddressAfterUpgrade() {
                let env = AppEnvironment.resolve(
                    keychain: upgradedInstallKeychain(),
                    bundle: Bundle(for: NoServerBundleAnchor.self)
                )
                #expect(env.isServerConfigured == false)
            }

            @Test("Die Anmeldung ueberlebt das Update — und fuehrt trotzdem zur Adressfrage")
            func sessionSurvivesAndIsRoutedToTheAddressQuestion() async {
                let keychain = upgradedInstallKeychain()
                let env = AppEnvironment.resolve(keychain: keychain, bundle: Bundle(for: NoServerBundleAnchor.self))
                let api = APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
                let store = AuthStore(
                    auth: AuthService(api: api, keychain: keychain, passkey: NoopPasskey()),
                    keychain: keychain
                )

                await store.bootstrap()

                // 1. Die Sitzung bleibt. Es fehlt eine Adresse, nicht eine Anmeldung.
                guard case .authenticated = store.phase else {
                    Issue.record("Ein bestehender Token darf durch eine fehlende Adresse nicht entwertet werden.")
                    return
                }
                #expect(keychain.getString(forKey: KeychainKey.authToken) != nil)

                // 2. Trotzdem sieht der Nutzer die Adressfrage, nicht das Produkt.
                #expect(
                    RootView.needsServerAddressGate(
                        phase: store.phase,
                        hasServerAddress: env.isServerConfigured
                    )
                )
            }

            @Test("Sobald die Adresse eingetragen ist, faellt das Gate")
            func gateClosesOnceTheAddressIsEntered() throws {
                let keychain = upgradedInstallKeychain()
                let availability = BackendAvailability(
                    authStore: nil,
                    hasServerAddress: AppEnvironment
                        .resolve(keychain: keychain, bundle: Bundle(for: NoServerBundleAnchor.self))
                        .isServerConfigured
                )
                #expect(availability.hasServerAddress == false)

                // Was der Nutzer im Adress-Schritt eintraegt, kanonisiert durch
                // dieselbe Validierung, die der Schritt selbst benutzt.
                let entered = try AppEnvironment.validate(serverURLString: "meinserver.example.com")
                try AppEnvironment.setCustomBaseURL(entered, keychain: keychain)
                let reloaded = AppEnvironment.resolve(keychain: keychain, bundle: Bundle(for: NoServerBundleAnchor.self))
                availability.setHasServerAddress(reloaded.isServerConfigured)

                #expect(availability.hasServerAddress)
                let user = User(id: "u1", email: nil, username: nil, displayName: nil, createdAt: .now)
                #expect(
                    RootView.needsServerAddressGate(
                        phase: .authenticated(user),
                        hasServerAddress: availability.hasServerAddress
                    ) == false
                )
            }
        }

        // MARK: - Nicht abmelden, wenn nur die Adresse fehlt

        @MainActor
        @Suite("serverNotConfigured meldet niemanden ab", .serialized)
        struct MissingAddressNeverSignsOut {
            @Test("Ein Anmeldeversuch ohne Adresse laesst Sitzung und Token unberuehrt")
            func failedRequestKeepsSession() async throws {
                let keychain = InMemoryKeychain()
                try keychain.setString("bearer-from-b248", forKey: KeychainKey.authToken)
                try keychain.setString("user-abc-123", forKey: KeychainKey.userID)
                let env = AppEnvironment.resolve(keychain: keychain, bundle: Bundle(for: NoServerBundleAnchor.self))
                #expect(env.isServerConfigured == false)
                let api = APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
                let store = AuthStore(
                    auth: AuthService(api: api, keychain: keychain, passkey: NoopPasskey()),
                    keychain: keychain
                )
                await store.bootstrap()
                let phaseBefore = store.phase

                await store.login(email: "wer@example.com", password: "egal-egal")

                #expect(store.lastError == .serverNotConfigured)
                #expect(store.phase == phaseBefore, "Eine fehlende Adresse ist kein Auth-Urteil.")
                #expect(
                    keychain.getString(forKey: KeychainKey.authToken) != nil,
                    "Der Token gehoert nicht der Adresse. Wer beides verliert, verliert mehr als noetig."
                )
                #expect(keychain.getString(forKey: KeychainKey.userID) != nil)
            }

            @Test("Die Refresh-Einstufung sieht darin keinen Auth-Fehler")
            func refreshClassificationIsTransient() {
                let missingAddress: HLError = .serverNotConfigured
                #expect(RefreshOutcome.classify(missingAddress) == .transient)
            }
        }

        /// `AuthService.init` verlangt die Passkey-Abhaengigkeit; keiner der
        /// Tests hier laeuft je durch eine Passkey-Zeremonie.
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
    }

    /// Leerer Bundle-Anker fuer `Bundle(for:)` — ein Test-Bundle ohne `HLBaseURL`,
    /// also „keine eingebaute Adresse", genau wie der ausgelieferte Build.
    private final class NoServerBundleAnchor {}

#endif
