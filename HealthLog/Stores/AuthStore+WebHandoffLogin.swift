import Foundation
#if canImport(AuthenticationServices)
    import AuthenticationServices
#endif

// Moved out of `AuthStore.swift` (file_length-Disziplin, PROJECT_GUIDE.md).
// 13-02 gave the web-handoff leg its dead-end handling, and the store crossed
// SwiftLint's `file_length` ERROR ceiling of 1,000 lines. The leg holds no
// stored state of its own — `oidcAuthenticator` stays in the type body with
// the OIDC leg it shares — so it is a pure relocation: same bodies, same call
// sites, one nesting level shallower.

#if canImport(AuthenticationServices)
    extension AuthStore {
        // MARK: - Web-handoff login (#65 / v1.32.11 self-hosted web sign-in)

        /// #65 — starts the native web-handoff login flow for a self-hosted
        /// instance. Generates app-side PKCE (S256), opens
        /// `…/api/auth/native/login?code_challenge=…` in an
        /// `ASWebAuthenticationSession` (where the instance's own passkeys +
        /// password managers work, because the browser is on the right origin —
        /// the native form cannot bind them), and finalizes the returned
        /// `healthlog://login-callback?…` into a token exchange or a surfaced
        /// error. Reuses the SAME flow-agnostic `oidcAuthenticator` driver wired
        /// at `AppContainer` (it takes `loginURL` + `callbackScheme` as
        /// parameters), so no second driver exists.
        ///
        /// The PKCE `codeVerifier` lives only in this stack frame until the
        /// one-shot token exchange — never persisted, never logged. A
        /// user-cancelled sheet is benign (no banner), mirroring the SSO/passkey
        /// handling.
        public func loginWithWebLogin(anchor: ASPresentationAnchorProvider) async {
            guard let authenticator = oidcAuthenticator else {
                // `publishError`, not a direct assignment: `lastError`'s setter
                // is file-private and this leg now lives in its own file. Same
                // writer the rest of the store uses, no behaviour change.
                publishError(.unknown(String(localized: "onboarding.sso.unavailable")))
                HLLog.auth.error("Web-login requested but no web-auth driver is wired.")
                return
            }
            // Opened before the sheet and carried into the callback — see
            // ``loginWithSSO(anchor:)``, which this mirrors exactly.
            let attempt = beginAuthAttempt()
            defer { finishAuthAttempt(attempt) }

            // App-generated PKCE (S256). The verifier is held in memory only.
            let pkce = OidcPKCE.generate()
            // Siehe `loginWithSSO` — fehlende Adresse und kaputte Adresse sind
            // zwei verschiedene Befunde und bekommen zwei verschiedene Saetze.
            guard let baseURL = AppEnvironment.currentBaseURL(keychain: keychain) else {
                failAttempt(.serverNotConfigured, for: attempt)
                HLLog.auth.error("Web-login requested without a configured server.")
                return
            }
            guard let loginURL = WebLoginNativeFlow.loginURL(baseURL: baseURL, codeChallenge: pkce.codeChallenge) else {
                failAttempt(.unknown(String(localized: "onboarding.webLogin.error.generic")), for: attempt)
                HLLog.auth.error("Web-login could not build the login URL.")
                return
            }

            let outcome = await authenticator.authenticate(
                loginURL: loginURL,
                callbackScheme: WebLoginNativeFlow.callbackScheme,
                anchor: anchor
            )
            switch outcome {
            case .canceled:
                // Benign user dismissal — no banner (mirrors the SSO cancel).
                // 13-02: the form still opens. A user who dismissed the sheet
                // BECAUSE it showed an error page needs the way back to be
                // there when they look; an unexplained banner they did not ask
                // for is a different matter, and stays absent.
                acceptBenignCancellation(for: attempt)
                revealPasswordFallback(for: attempt)
            case .failed:
                failAttempt(.unknown(String(localized: "onboarding.webLogin.error.generic")), for: attempt)
                revealPasswordFallback(for: attempt)
                HLLog.auth.warning("Web-login web-auth session failed to complete.")
            case let .callback(url):
                // 13-02 — the session came back with an address instead of our
                // callback. That is what a dead end looks like from in here:
                // the sheet navigated somewhere it could not follow (#96 sends
                // it to the server's own bind address) and handed us the page
                // it died on. Classified, never corrected.
                if WebLoginRedirectPolicy.isDeadEnd(target: url, configuredHost: baseURL.host) {
                    failAttempt(.unknown(String(localized: "onboarding.webLogin.error.deadEnd")), for: attempt)
                    revealPasswordFallback(for: attempt)
                    HLLog.auth.warning("Web-login ended on a non-routable host.")
                    return
                }
                await handleWebLoginCallback(url, codeVerifier: pkce.codeVerifier, attempt: attempt)
            }
        }

        /// #65 — routes the parsed `healthlog://login-callback` into the correct
        /// finalization path. `codeVerifier` is the in-memory PKCE verifier from
        /// ``loginWithWebLogin(anchor:)``; it is consumed exactly once here and
        /// never logged. `internal` (not `private`) so the flow-routing test can
        /// drive it directly with a canned callback URL. **No MFA branch** — the
        /// second factor is handled inside the browser session, so the native
        /// side only ever sees a finished `code`.
        /// - Parameter attempt: as in ``handleSSOCallback(_:codeVerifier:attempt:)``.
        func handleWebLoginCallback(_ url: URL, codeVerifier: String, attempt: AuthAttempt? = nil) async {
            guard await beginAuthenticationTransition() else { return }
            defer { finishAuthenticationTransition() }
            let leg = attempt ?? beginAuthAttempt()
            defer { if attempt == nil { finishAuthAttempt(leg) } }
            switch WebLoginCallback.parse(url) {
            case let .code(code):
                do {
                    // Exchange exactly once → the standard native bundle, stored +
                    // rotated through the existing keychain persistence so refresh
                    // works identically to password/passkey/OIDC login.
                    let session = try await auth.webLoginTokenExchange(code: code, codeVerifier: codeVerifier)
                    acceptSession(session, for: leg)
                } catch let err as HLError where err == .canceled {
                    acceptBenignCancellation(for: leg)
                } catch {
                    // A consumed/expired/mismatched code (single generic 401) is a
                    // login failure — surface it, never a web page. The
                    // code/verifier/token never appear in any log line.
                    failAttempt(.unknown(String(localized: "onboarding.webLogin.exchangeFailed")), for: leg)
                    revealPasswordFallback(for: leg)
                    HLLog.auth.error(
                        "Web-login token exchange failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                    )
                }
            case let .error(reason):
                // `stale_session` etc. → speaking copy; no silent ambient-session
                // retry (the copy tells the user to sign in fresh in the sheet).
                failAttempt(.unknown(reason.localizedMessage), for: leg)
                revealPasswordFallback(for: leg)
                // `logLabel` is operator-grade: a closed-set reason word (no PII,
                // no token) — safe as `.public`.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.auth.warning("Web-login callback error: \(reason.logLabel, privacy: .public)")
            case .unrecognized:
                failAttempt(.unknown(String(localized: "onboarding.webLogin.error.generic")), for: leg)
                revealPasswordFallback(for: leg)
                HLLog.auth.warning("Web-login callback carried no recognised parameters.")
            }
        }
    }
#endif
