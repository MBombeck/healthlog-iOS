// **Phase 09 / plan 09-07 — one harness, six flows.**
//
// The convergence claim is only worth making if all six flows are driven the
// same way, so the harness owns the whole shape: a real `AuthService` over the
// scripted transport, a real `AuthStore`, and one `complete()` call per flow
// that ends in an accepted session. `prepare()` exists for the single flow that
// needs a first leg (MFA has to be challenged before it can be verified).

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    /// The six production flows that can end in an `AuthSession`.
    enum Phase09AuthFlow: String, CaseIterable, Sendable {
        case password
        case mfa
        case register
        case passkey
        case nativeSSO
        case hostedWebLogin

        /// The path whose response carries the accepted session home — the one
        /// hop a barrier has to park to hold every flow at the same place.
        var acceptancePath: String {
            switch self {
            case .password, .register: "/api/auth/login"
            case .mfa: "/api/auth/mfa/verify"
            case .passkey: "/api/auth/passkey/login-verify"
            case .nativeSSO: "/api/auth/oidc/native/token"
            case .hostedWebLogin: "/api/auth/native/token"
            }
        }

        /// The mapped error each flow publishes for a terminal server failure.
        /// The four native flows surface the transport error itself; the two
        /// web-handoff exchanges deliberately replace it with their own copy so
        /// a consumed code never renders as a raw server string.
        func mappedTerminalError(status: Int, message: String) -> HLError {
            switch self {
            case .password, .mfa, .register, .passkey:
                .server(status: status, code: nil, message: message)
            case .nativeSSO:
                .unknown(String(localized: "onboarding.sso.exchangeFailed"))
            case .hostedWebLogin:
                .unknown(String(localized: "onboarding.webLogin.exchangeFailed"))
            }
        }

        var callbackURL: URL? {
            switch self {
            case .nativeSSO:
                URL(string: "healthlog://oidc-callback?code=hlh_conv0000000000000000000000000000000000000")
            case .hostedWebLogin:
                URL(string: "healthlog://login-callback?code=hlh_conv0000000000000000000000000000000000000")
            case .password, .mfa, .register, .passkey:
                nil
            }
        }
    }

    @MainActor
    final class Phase09AuthHarness {
        static let email = "convergence@example.com"
        static let password = "correct-horse-battery-staple"

        let flow: Phase09AuthFlow
        let userID: String
        let keychain: any KeychainStoring
        let api = Phase09AuthScriptedAPI()
        let passkey: Phase09AuthStubPasskey
        let authenticator: Phase09AuthStubWebAuthenticator
        let anchor = Phase09AuthStubAnchor()
        let store: AuthStore

        /// The state every flow must land in once its session is accepted.
        var expectedUser: User {
            User(id: userID, email: nil, username: "convergence", displayName: nil, createdAt: nil)
        }

        init(
            flow: Phase09AuthFlow,
            acceptanceGate: Phase09Gate? = nil,
            sheetGate: Phase09Gate? = nil,
            acceptanceStatus: Int = 200,
            acceptanceMessage: String = "scripted failure",
            passkeyError: (any Error)? = nil,
            webAuthOutcome: OidcAuthOutcome? = nil,
            keychain: (any KeychainStoring)? = nil
        ) {
            self.flow = flow
            userID = "user-\(flow.rawValue)"
            self.keychain = keychain ?? InMemoryKeychain()
            passkey = Phase09AuthStubPasskey(assertionError: passkeyError)
            // The browser leg builds its URL from `AppEnvironment.currentBaseURL`,
            // which is nil without a configured server — the app ships no
            // built-in host.
            try? self.keychain.setString("https://test.healthlog.local", forKey: KeychainKey.serverURL)
            let service = AuthService(api: api, keychain: self.keychain, passkey: passkey)
            store = AuthStore(auth: service, keychain: self.keychain)
            authenticator = Phase09AuthStubWebAuthenticator(
                outcome: webAuthOutcome ?? .callback(flow.callbackURL ?? URL(string: "healthlog://login-callback")!),
                gate: sheetGate
            )
            store.oidcAuthenticator = authenticator
            installScripts(acceptanceGate: acceptanceGate, status: acceptanceStatus, message: acceptanceMessage)
        }

        private func installScripts(acceptanceGate: Phase09Gate?, status: Int, message: String) {
            let bundle = Phase09AuthBody.bundle(userID: userID)
            let accepting = Phase09AuthScriptedAPI.Response(
                status: status,
                body: bundle,
                message: message,
                gate: acceptanceGate
            )
            // Every leg is scripted; only the acceptance hop carries the barrier
            // and the failure status, so one harness serves all six flows.
            api.script("/api/auth/register", .init(body: Phase09AuthBody.accepted))
            api.script("/api/auth/passkey/login-options", .init(body: Phase09AuthBody.passkeyOptions))
            api.script("/api/auth/mfa/webauthn/verify/options", .init(body: Phase09AuthBody.mfaWebauthnOptions))
            api.script("/api/auth/mfa/webauthn/verify", .init(body: bundle))
            for path in [
                "/api/auth/login",
                "/api/auth/mfa/verify",
                "/api/auth/passkey/login-verify",
                "/api/auth/oidc/native/token",
                "/api/auth/native/token"
            ] {
                api.script(path, .init(body: bundle))
            }
            // The MFA flow's first leg must challenge rather than resolve.
            if flow == .mfa {
                api.script("/api/auth/login", .init(body: Phase09AuthBody.mfaChallenge))
            }
            api.script(flow.acceptancePath, accepting)
        }

        /// The leg that runs *before* the barrier — MFA has to be challenged
        /// before it can be verified. Every other flow prepares nothing.
        func prepare() async {
            guard flow == .mfa else { return }
            await store.login(email: Self.email, password: Self.password)
        }

        /// The one call per flow that ends in an accepted session.
        func complete() async {
            switch flow {
            case .password:
                await store.login(email: Self.email, password: Self.password)
            case .mfa:
                await store.verifyMFA(method: .totp, code: "123456")
            case .register:
                await store.register(email: Self.email, username: "convergence", password: Self.password)
            case .passkey:
                await store.loginWithPasskey(anchor: anchor)
            case .nativeSSO:
                await store.loginWithSSO(anchor: anchor)
            case .hostedWebLogin:
                await store.loginWithWebLogin(anchor: anchor)
            }
        }

        func run() async {
            await prepare()
            await complete()
        }

        /// Re-scripts the acceptance hop, so a harness that has just published a
        /// failure can be driven a second time to a success.
        func rescriptAcceptance(status: Int = 200, gate: Phase09Gate? = nil) {
            api.script(
                flow.acceptancePath,
                .init(status: status, body: Phase09AuthBody.bundle(userID: userID), gate: gate)
            )
        }

        var storedBearer: String? {
            keychain.getString(forKey: KeychainKey.authToken)
        }
    }

#endif // !SWIFT_PACKAGE
