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
    }

    @MainActor
    public struct SystemWebAuthenticationSessionFactory: WebAuthenticationSessionCreating {
        public init() {}

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
