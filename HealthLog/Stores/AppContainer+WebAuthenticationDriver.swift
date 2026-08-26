import Foundation
#if canImport(AuthenticationServices)
    import AuthenticationServices
#endif

#if canImport(AuthenticationServices)
    extension AppContainer {
        /// **13-04.** The one web-auth driver both interactive legs share — OIDC
        /// SSO (#49) and the web-handoff login (#65) — resolved in one place so
        /// there is exactly one statement about which driver a build gets.
        ///
        /// Production always gets the real `ASWebAuthenticationSession` driver.
        /// A DEBUG build additionally honours `-uitest-weblogin-outcome`, which
        /// installs a stub that returns a canned outcome without opening a
        /// sheet — the only way a UI test can reach the code *after* the
        /// browser, since the sheet is presented out of process. The whole
        /// branch is `#if DEBUG` and the stub type itself is `#if DEBUG`, so a
        /// Release build neither links nor can reach it.
        @MainActor
        static func webAuthenticationDriver() -> any OidcAuthenticating {
            #if DEBUG
                if let outcome = HermeticUITestSupport.webLoginOutcome {
                    return StubbedWebAuthenticationOutcome(outcome: stubbedOutcome(for: outcome))
                }
            #endif
            return OidcWebAuthenticationSessionDriver()
        }

        #if DEBUG
            private static func stubbedOutcome(
                for outcome: HermeticUITestSupport.WebLoginOutcome
            ) -> OidcAuthOutcome {
                switch outcome {
                case .deadEnd:
                    // The session hands back the address it died on instead of
                    // `healthlog://login-callback` — healthlog-iOS#96's shape.
                    guard let url = URL(string: HermeticUITestSupport.deadEndCallbackURL) else {
                        return .failed
                    }
                    return .callback(url)
                case .failed:
                    return .failed
                case .cancelled:
                    return .canceled
                }
            }
        #endif
    }
#endif
