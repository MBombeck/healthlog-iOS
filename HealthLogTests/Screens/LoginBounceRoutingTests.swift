// Phase 24 / plan 24-02 — D-24-01-A, the login lock-out.
//
// The behavioural proof of this defect is `HealthLogUITests/LoginBounceUITests`,
// and it has to be: every part of the trap is view lifecycle, and the store is
// behaving correctly throughout. What lives here is the half a UI test cannot
// pin — the decision the fix introduced, stated as a table — and the half a UI
// test should not have to re-derive: the MECHANISM, driven through the shipped
// stores from the state a signed-out install is actually in.
//
// The mechanism, in one sentence: every credential door funnels into one
// `acceptSession` → `admitAuthenticating`, there is exactly one
// `onChange(of: authStore.phase)` in the whole app, and a repeat sign-in with
// the same account assigns an EQUAL `Phase` — so the trap can neither be
// specific to a credential type nor recover itself.

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    @MainActor
    @Suite("Phase 24 login bounce — the forward route survives a remount")
    struct LoginBounceRoutingTests {
        // MARK: - The vocabulary this suite reasons over

        /// Every step, once. Totality is enforced by the compiler rather than by
        /// this array: ``OnboardingFlow/Step/isPreAuthentication`` switches
        /// exhaustively with no `default`, so a new step cannot be added without
        /// answering which side of the login it stands on. The array exists so
        /// the tables below can be read as tables.
        private static let allSteps: [OnboardingFlow.Step] = [
            .welcome, .mode, .serverURL, .auth,
            .checkingCompletion, .completionUnavailable,
            .healthKit, .notifications, .aiSource, .anamnesis, .baselineProfile, .done
        ]

        private static let operatorUser = User(
            id: "usr_operator_real",
            email: "operator@example.com",
            username: "operator",
            displayName: "Alex",
            createdAt: nil
        )

        // MARK: - The surface: a live session never sees a sign-in door

        /// The four steps a remounted flow can be re-created on resolve to the
        /// post-authentication lookup, not to a door the user has already walked
        /// through. This is what makes the FIRST render after a remount correct,
        /// so the fix does not depend on any effect arriving in time.
        @Test("no pre-authentication surface is ever resolved over an accepted session")
        func noPreAuthenticationSurfaceIsResolvedOverAnAcceptedSession() {
            let accepted = AuthStore.Phase.authenticating(Self.operatorUser)
            for step in Self.allSteps {
                let resolved = OnboardingFlow.resolveStep(
                    step,
                    chosenMode: .server,
                    hasServerAddress: true,
                    phase: accepted
                )
                if step.isPreAuthentication {
                    #expect(
                        resolved == .checkingCompletion,
                        "\(step) stands in front of a login that has already happened"
                    )
                } else {
                    #expect(resolved == step, "\(step) is past the boundary and must be left alone")
                }
            }
            // And the classification itself is the four the remount can produce.
            #expect(Self.allSteps.filter(\.isPreAuthentication) == [.welcome, .mode, .serverURL, .auth])
            #expect(OnboardingFlow.initialStep.isPreAuthentication, "the mount position is one of them by definition")
        }

        /// R1 is untouched. Every phase that has NOT accepted a session gets the
        /// address answer it got before this plan, and a caller that names no
        /// phase gets it too — which is why the parameter is defaulted.
        @Test("the address question is unchanged for every phase that holds no session")
        func theAddressQuestionIsUnchangedWithoutASession() {
            let unaccepted: [AuthStore.Phase] = [
                .unknown, .unauthenticated, .standalone, .authenticated(Self.operatorUser)
            ]
            for phase in unaccepted {
                #expect(
                    OnboardingFlow.resolveStep(
                        .auth, chosenMode: .server, hasServerAddress: false, phase: phase
                    ) == .serverURL,
                    "R1: no address, no login step — \(phase)"
                )
                #expect(
                    OnboardingFlow.resolveStep(
                        .auth, chosenMode: .server, hasServerAddress: true, phase: phase
                    ) == .auth
                )
            }
            // The defaulted call, byte for byte the pre-24-02 contract.
            #expect(
                OnboardingFlow.resolveStep(.auth, chosenMode: .server, hasServerAddress: false) == .serverURL
            )
            #expect(
                OnboardingFlow.resolveStep(.welcome, chosenMode: .server, hasServerAddress: false) == .welcome
            )
        }

        // MARK: - The effect: which flow owes the decision

        /// The whole table. A phase that has not accepted a session owes nothing;
        /// an accepted one is owed the decision by any flow in front of the
        /// boundary — including one re-created at `.welcome` — and by the retry
        /// surface. `.checkingCompletion` is refused, which is the guarantee the
        /// old inline `onChange` guard carried: a lookup in flight is never
        /// restarted by a repeated notification.
        @Test("the forward decision is a function of the current phase, and is total")
        func theForwardDecisionIsAFunctionOfTheCurrentPhase() {
            let accepted = AuthStore.Phase.authenticating(Self.operatorUser)
            let owed: Set<OnboardingFlow.Step> = [.welcome, .mode, .serverURL, .auth, .completionUnavailable]
            for step in Self.allSteps {
                #expect(
                    OnboardingFlow.shouldResolvePostAuthenticationRoute(step: step, phase: accepted)
                        == owed.contains(step),
                    "\(step) under an accepted session"
                )
                for phase in [
                    AuthStore.Phase.unknown,
                    .unauthenticated,
                    .standalone,
                    .authenticated(Self.operatorUser)
                ] {
                    #expect(
                        !OnboardingFlow.shouldResolvePostAuthenticationRoute(step: step, phase: phase),
                        "\(step) under \(phase) owes no post-authentication decision"
                    )
                }
            }
        }

        // MARK: - The mechanism, driven through the shipped stores

        /// **Why the trap is permanent, and why it cannot be about passkeys.**
        ///
        /// From the state a signed-out install is genuinely in — `logout()`
        /// removes the five session keys and the name hint and leaves the server
        /// address (`AuthService.invalidateAndWipeSessionCredentials`), which is
        /// exactly what the operator's device held — this drives the REAL stores
        /// through two doors and three sign-ins, and reads the phase after each.
        ///
        /// Three facts, none of them assumed:
        ///
        /// 1. A password sign-in publishes `.authenticating(user)`.
        /// 2. A **second** sign-in with the same account publishes an **equal**
        ///    value. `onChange` compares before it calls, so nothing fires — the
        ///    operator's repeat attempt could not have rescued him.
        /// 3. The **passkey** door publishes the same value as the password
        ///    door. The trap is downstream of every credential type, which is
        ///    why his report has both paths failing.
        @Test("every door publishes the same phase, and a repeat sign-in publishes an equal one")
        func everyDoorPublishesTheSamePhaseAndARepeatPublishesAnEqualOne() async throws {
            let keychain = InMemoryKeychain()
            // What a logout leaves behind: no token, no user id, no name hint —
            // and the server address, which is NOT in `requiredKeys`.
            try keychain.setString("https://healthlog.example", forKey: KeychainKey.serverURL)
            #expect(keychain.getString(forKey: KeychainKey.authToken) == nil)
            #expect(keychain.getString(forKey: KeychainKey.userID) == nil)

            let transport = MockURLProtocolSession()
            defer { transport.invalidate() }
            transport.install { request in
                let path = request.url?.path ?? ""
                if path == "/api/auth/passkey/login-options" {
                    return try Self.ok(request, Self.passkeyOptionsBody())
                }
                return try Self.ok(request, Self.sessionBody())
            }

            let environment = AppEnvironment(
                baseURL: transport.baseURL,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            let api = APIClient(
                environment: environment,
                keychain: keychain,
                sessionConfiguration: transport.configuration
            )
            let service = AuthService(api: api, keychain: keychain, passkey: StubPasskey())
            let suite = "login-bounce-routing.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            defer { defaults.removePersistentDomain(forName: suite) }
            let authStore = AuthStore(auth: service, keychain: keychain, syncMode: nil, defaults: defaults)

            // 1 — the password door.
            await authStore.login(email: "operator@example.com", password: "pw")
            let afterFirst = authStore.phase
            #expect(afterFirst == .authenticating(Self.operatorUser))

            // 2 — the operator's second attempt. The value is EQUAL, so the one
            // `onChange(of: authStore.phase)` in the app cannot fire.
            await authStore.login(email: "operator@example.com", password: "pw")
            #expect(
                authStore.phase == afterFirst,
                """
                A repeat sign-in must assign an equal phase — that is the half that makes the trap permanent. \
                If this ever stops being true, the second-attempt reasoning in 24-02 has to be re-derived.
                """
            )

            // 3 — the passkey door, driven for real through `AuthService.passkeyLogin`.
            await authStore.loginWithPasskey(anchor: StubAnchor())
            #expect(
                authStore.phase == afterFirst,
                "the passkey door publishes the same phase as the password door — the trap cannot be credential-specific"
            )
            #expect(authStore.lastError == nil, "the passkey leg must have completed, not failed into the same phase")
            #expect(keychain.getString(forKey: KeychainKey.authToken) == "hlk_bearer_FRESH")

            // And the flow a remount re-creates at `.welcome` over exactly this
            // phase owes the post-authentication decision. This is the join
            // between the mechanism above and the repair.
            #expect(
                OnboardingFlow.shouldResolvePostAuthenticationRoute(step: .welcome, phase: authStore.phase)
            )
            #expect(
                OnboardingFlow.resolveStep(
                    .welcome, chosenMode: .server, hasServerAddress: true, phase: authStore.phase
                ) == .checkingCompletion
            )
        }

        // MARK: - The structural fence

        /// **The property that must not be quietly undone.**
        ///
        /// The defect was not a wrong value: it was a recovery that existed only
        /// inside a change notification. So the fence is about WHERE the decision
        /// is asked from. `onChange` may keep asking it — it is the fast path —
        /// but a mount must ask it too, or the flow is one scene deactivation
        /// away from the trap again.
        @Test("the flow asks the phase on appearance, not only on a change")
        func theFlowAsksThePhaseOnAppearanceNotOnlyOnAChange() throws {
            let flow = try Self.source("HealthLog/Screens/Onboarding/OnboardingFlow.swift")

            // There is exactly one observer of the phase in the whole app, so
            // "the notification was missed" has no second chance anywhere else.
            var observers: [String] = []
            for url in try Self.appSources() {
                let text = try String(contentsOf: url, encoding: .utf8)
                for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.contains("onChange(of: authStore.phase)") else { continue }
                    // A doc comment naming the symbol is not the symbol — the
                    // same rule this repo's other source contracts apply, and
                    // the reason this file's own history is quotable in one.
                    guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { continue }
                    observers.append("\(url.lastPathComponent):\(index + 1)")
                }
            }
            #expect(
                observers.count == 1,
                "the app has \(observers.count) phase observers (\(observers.joined(separator: ", "))); the reasoning here assumes exactly one"
            )

            // The mount trigger, inside the `onAppear` block and not inside the
            // `onChange` one.
            let onAppearBlock = try #require(
                flow.range(of: ".onAppear {").map { String(flow[$0.upperBound...].prefix(400)) },
                "the flow no longer has an onAppear block to carry the resume"
            )
            #expect(
                onAppearBlock.contains("resumePostAuthenticationRouteIfNeeded()"),
                "the post-authentication route must be re-asked when the flow appears"
            )
            #expect(
                flow.contains("private func resumePostAuthenticationRouteIfNeeded() {"),
                "the resume must be a named statement, not an inline reconstruction"
            )

            // And the rendered surface is decided from the phase too, so the
            // first frame after a remount never shows a door to a live session.
            #expect(flow.contains("phase: authStore.phase"))
            #expect(
                flow.contains("Self.shouldResolvePostAuthenticationRoute(step: step, phase: newPhase)"),
                "the admissible steps must come from the pure decision, not from an inline step comparison"
            )
        }

        // MARK: - Fixtures and doubles

        private nonisolated static func ok(_ request: URLRequest, _ body: Data) throws -> (HTTPURLResponse, Data?) {
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url, statusCode: 200, httpVersion: nil, headerFields: nil
                  ) else
            {
                throw HLError.unknown("the mock transport was handed a request it cannot answer")
            }
            return (response, body)
        }

        /// The shipped `POST /api/auth/login` and `…/passkey/login-verify` shape
        /// — both decode `NativeLoginResponse`, which is why one body serves the
        /// two doors this suite compares.
        private nonisolated static func sessionBody() -> Data {
            Data("""
            {
              "data": {
                "user": {
                  "id": "usr_operator_real",
                  "email": "operator@example.com",
                  "username": "operator",
                  "displayName": "Alex"
                },
                "token": "hlk_bearer_FRESH",
                "tokenExpiresAt": "2027-06-01T12:00:00Z",
                "refreshToken": "hlr_refresh_FRESH",
                "refreshTokenExpiresAt": "2027-07-31T12:00:00Z"
              },
              "error": null
            }
            """.utf8)
        }

        private nonisolated static func passkeyOptionsBody() -> Data {
            Data("""
            {
              "data": {
                "challengeId": "chl_operator",
                "options": {
                  "challenge": "Y2hhbGxlbmdl",
                  "rpId": "healthlog.example",
                  "allowCredentials": [{ "id": "cred_operator", "type": "public-key" }],
                  "userVerification": "preferred"
                }
              },
              "error": null
            }
            """.utf8)
        }

        /// A passkey service that answers the assertion the system sheet would
        /// have answered. The sheet itself is out of process and cannot be driven
        /// here — but everything the app does with its ANSWER can be.
        private final class StubPasskey: PasskeyServiceProtocol, @unchecked Sendable {
            @MainActor func register(
                challenge _: String, rpId _: String, rpName _: String,
                userID _: String, userName _: String, displayName _: String,
                anchor _: ASPresentationAnchorProvider
            ) async throws -> PasskeyRegistration {
                throw HLError.unknown("registration is not this suite's subject")
            }

            @MainActor func assert(
                challenge _: String, rpId _: String, allowCredentialIDs _: [String],
                anchor _: ASPresentationAnchorProvider
            ) async throws -> PasskeyAssertion {
                PasskeyAssertion(
                    credentialID: "cred_operator",
                    clientDataJSON: "Y2xpZW50",
                    authenticatorData: "YXV0aA==",
                    signature: "c2ln",
                    userHandle: "dXNlcg=="
                )
            }
        }

        @MainActor
        private final class StubAnchor: ASPresentationAnchorProvider {
            func anchor() -> ASPresentationAnchor {
                ASPresentationAnchor()
            }
        }

        // MARK: - Source access

        private static let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        private static func source(_ relativePath: String) throws -> String {
            try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
        }

        private static func appSources() throws -> [URL] {
            let root = repositoryRoot.appendingPathComponent("HealthLog")
            let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            var urls: [URL] = []
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                urls.append(url)
            }
            return urls
        }
    }

#endif
