import Foundation

#if canImport(AuthenticationServices)
    import AuthenticationServices

    /// Actor-isolated surface used by the OIDC and integration drivers. The
    /// Apple object remains behind this narrow adapter so tests can control
    /// start/callback/cancel ordering without opening authentication UI.
    @MainActor
    public protocol WebAuthenticationSession: AnyObject {
        var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)? { get set }
        var prefersEphemeralWebBrowserSession: Bool { get set }

        func start() -> Bool
        func cancel()
    }

    /// Construction seam for `ASWebAuthenticationSession`. The production
    /// implementation passes Apple's completion handler through unchanged,
    /// preserving the framework's callback queue and error values.
    @MainActor
    public protocol WebAuthenticationSessionCreating: Sendable {
        func makeSession(
            url: URL,
            callbackURLScheme: String?,
            completionHandler: @escaping (URL?, Error?) -> Void
        ) -> any WebAuthenticationSession

        func makeSession(
            url: URL,
            returnRoute: OidcReturnRoute,
            completionHandler: @escaping (URL?, Error?) -> Void
        ) -> any WebAuthenticationSession
    }

    public extension WebAuthenticationSessionCreating {
        /// SEC — a session for the native SSO return (``OidcReturnRoute``).
        /// The default (test factories) builds the scheme session, with no
        /// scheme for the `https` return; the system factory below implements
        /// the real `https` callback.
        func makeSession(
            url: URL,
            returnRoute: OidcReturnRoute,
            completionHandler: @escaping (URL?, Error?) -> Void
        ) -> any WebAuthenticationSession {
            makeSession(url: url, callbackURLScheme: returnRoute.customScheme, completionHandler: completionHandler)
        }
    }

    @MainActor
    public struct SystemWebAuthenticationSessionFactory: WebAuthenticationSessionCreating {
        public init() {}

        /// SEC — the scheme return builds exactly the session 1.4 built; only
        /// the `https` return uses the callback initializer (iOS 17.4, below
        /// the 18.0 target), which matches host and path.
        public func makeSession(
            url: URL,
            returnRoute: OidcReturnRoute,
            completionHandler: @escaping (URL?, Error?) -> Void
        ) -> any WebAuthenticationSession {
            guard case .https = returnRoute else {
                return makeSession(url: url, callbackURLScheme: returnRoute.customScheme, completionHandler: completionHandler)
            }
            return SystemWebAuthenticationSession(
                session: ASWebAuthenticationSession(
                    url: url,
                    callback: returnRoute.sessionCallback,
                    completionHandler: completionHandler
                )
            )
        }

        public func makeSession(
            url: URL,
            callbackURLScheme: String?,
            completionHandler: @escaping (URL?, Error?) -> Void
        ) -> any WebAuthenticationSession {
            SystemWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackURLScheme,
                completionHandler: completionHandler
            )
        }
    }

    @MainActor
    private final class SystemWebAuthenticationSession: WebAuthenticationSession {
        private let session: ASWebAuthenticationSession

        init(
            url: URL,
            callbackURLScheme: String?,
            completionHandler: @escaping (URL?, Error?) -> Void
        ) {
            session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackURLScheme,
                completionHandler: completionHandler
            )
        }

        init(session: ASWebAuthenticationSession) {
            self.session = session
        }

        var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)? {
            get { session.presentationContextProvider }
            set { session.presentationContextProvider = newValue }
        }

        var prefersEphemeralWebBrowserSession: Bool {
            get { session.prefersEphemeralWebBrowserSession }
            set { session.prefersEphemeralWebBrowserSession = newValue }
        }

        func start() -> Bool {
            session.start()
        }

        func cancel() {
            session.cancel()
        }
    }
#endif
