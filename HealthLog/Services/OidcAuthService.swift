import Foundation
#if canImport(AuthenticationServices)
    import AuthenticationServices
#endif

#if canImport(AuthenticationServices)

    /// #49 / v1.30.11 — terminal outcome of the native OIDC `ASWebAuthenticationSession`.
    public enum OidcAuthOutcome: Sendable {
        /// The session returned a `healthlog://oidc-callback?…` URL — parse it via
        /// ``OidcCallback/parse(_:)`` (code / mfa_ticket / error).
        case callback(URL)
        /// The user dismissed the sheet (`ASWebAuthenticationSessionError.canceledLogin`).
        /// Benign — no error banner.
        case canceled
        /// The session could not start or failed without a callback URL.
        case failed
    }

    /// Drives the native OIDC SSO authorize leg through `ASWebAuthenticationSession`.
    /// UIKit/`AuthenticationServices` is permitted here per PROJECT_GUIDE.md (auth flows).
    /// Injected into ``AuthStore`` by the composition root so it stays mockable in
    /// unit tests.
    @MainActor
    public protocol OidcAuthenticating: Sendable {
        /// Opens `loginURL` in an auth session bound to `callbackScheme` and
        /// resolves to the parsed terminal outcome.
        func authenticate(
            loginURL: URL,
            callbackScheme: String,
            anchor: ASPresentationAnchorProvider
        ) async -> OidcAuthOutcome
    }

    /// Concrete `ASWebAuthenticationSession` driver for the native OIDC flow.
    /// Mirrors `WhoopConnectService`'s session/anchor lifetime handling.
    @MainActor
    public final class OidcWebAuthenticationSessionDriver: OidcAuthenticating {
        private final class Operation {
            let id: UUID
            let session: any WebAuthenticationSession
            let context: OidcPresentationContextProvider
            var continuation: CheckedContinuation<OidcAuthOutcome, Never>?

            init(
                id: UUID,
                session: any WebAuthenticationSession,
                context: OidcPresentationContextProvider,
                continuation: CheckedContinuation<OidcAuthOutcome, Never>
            ) {
                self.id = id
                self.session = session
                self.context = context
                self.continuation = continuation
            }
        }

        /// The sole operation allowed to complete. Replacing it terminally
        /// cancels the prior continuation before the new session starts.
        private var operation: Operation?

        private let sessionFactory: any WebAuthenticationSessionCreating

        public init(
            sessionFactory: any WebAuthenticationSessionCreating = SystemWebAuthenticationSessionFactory()
        ) {
            self.sessionFactory = sessionFactory
        }

        public func authenticate(
            loginURL: URL,
            callbackScheme: String,
            anchor: ASPresentationAnchorProvider
        ) async -> OidcAuthOutcome {
            let id = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else {
                        continuation.resume(returning: .canceled)
                        return
                    }
                    cancelCurrentOperation()
                    let contextProvider = OidcPresentationContextProvider(anchorProvider: anchor)
                    let session = sessionFactory.makeSession(
                        url: loginURL,
                        callbackURLScheme: callbackScheme
                    ) { [weak self] callbackURL, error in
                        self?.complete(id: id, outcome: Self.outcome(callbackURL: callbackURL, error: error))
                    }
                    session.presentationContextProvider = contextProvider
                    session.prefersEphemeralWebBrowserSession = false
                    operation = Operation(
                        id: id,
                        session: session,
                        context: contextProvider,
                        continuation: continuation
                    )
                    guard session.start() else {
                        complete(id: id, outcome: .failed)
                        return
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancel(id: id)
                }
            }
        }

        private static func outcome(callbackURL: URL?, error: Error?) -> OidcAuthOutcome {
            if let callbackURL { return .callback(callbackURL) }
            if let error = error as? ASWebAuthenticationSessionError,
               error.code == .canceledLogin
            {
                return .canceled
            }
            return .failed
        }

        private func cancelCurrentOperation() {
            guard let operation else { return }
            operation.session.cancel()
            complete(id: operation.id, outcome: .canceled)
        }

        private func cancel(id: UUID) {
            guard operation?.id == id else { return }
            operation?.session.cancel()
            complete(id: id, outcome: .canceled)
        }

        private func complete(id: UUID, outcome: OidcAuthOutcome) {
            guard let current = operation, current.id == id else { return }
            operation = nil
            let continuation = current.continuation
            current.continuation = nil
            continuation?.resume(returning: outcome)
        }
    }

    #if DEBUG
        /// **13-04 — the web-handoff outcome seam for UI tests.**
        ///
        /// Returns a canned ``OidcAuthOutcome`` without opening any sheet. It
        /// exists because `ASWebAuthenticationSession` is presented out of
        /// process: a UI test cannot drive it, and one that tried would be
        /// measuring Safari rather than the app.
        ///
        /// `#if DEBUG` by construction, installed only when
        /// `-uitest-weblogin-outcome` is on the command line, so no Release
        /// build links it and no Release path can reach it. What it stubs is
        /// the boundary `AuthStore` already takes as its input — everything
        /// downstream (the dead-end classification, the fenced error, the
        /// password fallback) is the production code under test.
        @MainActor
        public final class StubbedWebAuthenticationOutcome: OidcAuthenticating {
            private let outcome: OidcAuthOutcome

            public init(outcome: OidcAuthOutcome) {
                self.outcome = outcome
            }

            public func authenticate(
                loginURL _: URL,
                callbackScheme _: String,
                anchor _: ASPresentationAnchorProvider
            ) async -> OidcAuthOutcome {
                outcome
            }
        }
    #endif

    /// Bridges `ASWebAuthenticationSession`'s presentation anchor to the app's
    /// shared `SceneAnchorProvider`, mirroring the passkey/Whoop drivers.
    @MainActor
    private final class OidcPresentationContextProvider: NSObject,
        ASWebAuthenticationPresentationContextProviding
    {
        private let anchorProvider: ASPresentationAnchorProvider
        init(anchorProvider: ASPresentationAnchorProvider) {
            self.anchorProvider = anchorProvider
        }

        func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
            anchorProvider.anchor()
        }
    }

#endif
