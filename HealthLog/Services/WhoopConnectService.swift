import Foundation

#if canImport(AuthenticationServices) && canImport(UIKit)
    import AuthenticationServices
    import UIKit
#endif

/// Drives the WHOOP OAuth connect leg through `ASWebAuthenticationSession`.
///
/// **Why a session and not `UIApplication.open` (the legacy Withings path).**
/// B5's cookie caveat: the connect→callback handshake depends on the server's
/// httpOnly `WhoopOAuthState` *nonce* cookie surviving the round-trip. We open
/// `…/api/whoop/connect` **itself** as the session start URL (NOT: fetch it via
/// the Bearer client and hand only the WHOOP URL to the session — that drops the
/// cookie). The session is **non-ephemeral** (`prefersEphemeralWebBrowserSession
/// = false`) so it shares the device's persistent Safari cookie jar; the server
/// sets the nonce cookie inside that same web context on the `connect` 302 and
/// reads it back on the `callback`, so the nonce round-trips (`SameSite=Lax`
/// permits it on the top-level navigation back from WHOOP).
///
/// **Redirect-detection mechanism (the B5 nuance).** The server's *final*
/// redirect after the WHOOP callback is a plain **web** URL on the app's own
/// host (`…/settings/integrations?whoop=connected|error`), not a custom scheme.
/// `ASWebAuthenticationSession` only auto-completes on a `callbackURLScheme`
/// match (or an HTTPS callback, which needs an `applinks:` associated domain +
/// AASA — we ship only `webcredentials:`, so that path is unavailable). We
/// therefore pass our bundle scheme as `callbackURLScheme` so that **if** the
/// server later adds a custom-scheme final redirect (the coord ask in
/// `v0.14.2-ios-to-server-whoop-connect-redirect.md`) it auto-completes and we
/// parse the outcome directly; **today** the session ends when the user dismisses
/// the web settings page (`.canceledLogin`), and the store re-reads
/// `GET /api/whoop/status` (`configured && connected`) as the authoritative
/// signal. Either way the connected gate is driven by status, never by the URL
/// alone — the URL outcome is only an optimistic fast-path.
///
/// UIKit/`AuthenticationServices` are allowed here per PROJECT_GUIDE.md (auth flows).
@MainActor
public protocol WhoopConnecting: Sendable {
    /// Opens `connectURL` in an auth session and resolves to the parsed terminal
    /// outcome. `.canceled` covers both a real user dismissal and the
    /// no-custom-scheme web-redirect dismissal — the caller re-reads status to
    /// disambiguate.
    func connect(connectURL: URL) async -> WhoopConnectOutcome
}

#if canImport(AuthenticationServices) && canImport(UIKit)
    @MainActor
    final class WhoopConnectService: WhoopConnecting {
        private final class Operation {
            let id: UUID
            let session: any WebAuthenticationSession
            let context: WhoopPresentationContextProvider
            var continuation: CheckedContinuation<WhoopConnectOutcome, Never>?

            init(
                id: UUID,
                session: any WebAuthenticationSession,
                context: WhoopPresentationContextProvider,
                continuation: CheckedContinuation<WhoopConnectOutcome, Never>
            ) {
                self.id = id
                self.session = session
                self.context = context
                self.continuation = continuation
            }
        }

        /// Custom scheme advertised as the session's `callbackURLScheme`. Matches
        /// the app's reverse-DNS bundle id so a future server custom-scheme final
        /// redirect (`dev.healthlog.app://…?whoop=connected`) auto-completes the
        /// session. Until the server adds it, no callback fires on this scheme and
        /// the session ends via user-dismiss → store re-reads status.
        static let callbackScheme = "dev.healthlog.app"

        private let anchorProvider: ASPresentationAnchorProvider
        private let sessionFactory: any WebAuthenticationSessionCreating
        private var operation: Operation?

        init(
            anchorProvider: ASPresentationAnchorProvider = SceneAnchorProvider.shared,
            sessionFactory: any WebAuthenticationSessionCreating = SystemWebAuthenticationSessionFactory()
        ) {
            self.anchorProvider = anchorProvider
            self.sessionFactory = sessionFactory
        }

        func connect(connectURL: URL) async -> WhoopConnectOutcome {
            let anchor = anchorProvider
            let id = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else {
                        continuation.resume(returning: .canceled)
                        return
                    }
                    cancelCurrentOperation()
                    let contextProvider = WhoopPresentationContextProvider(anchorProvider: anchor)
                    let session = sessionFactory.makeSession(
                        url: connectURL,
                        callbackURLScheme: Self.callbackScheme
                    ) { [weak self] callbackURL, _ in
                        let outcome = callbackURL.flatMap(WhoopConnectOutcome.from(callbackURL:)) ?? .canceled
                        self?.complete(id: id, outcome: outcome)
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
                        complete(id: id, outcome: .canceled)
                        return
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancel(id: id)
                }
            }
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

        private func complete(id: UUID, outcome: WhoopConnectOutcome) {
            guard let current = operation, current.id == id else { return }
            operation = nil
            let continuation = current.continuation
            current.continuation = nil
            continuation?.resume(returning: outcome)
        }
    }

    /// Bridges `ASWebAuthenticationSession`'s presentation anchor to the app's
    /// shared `SceneAnchorProvider`. Mirrors the passkey driver's anchor
    /// resolution so the sheet always finds a presentable window.
    @MainActor
    private final class WhoopPresentationContextProvider: NSObject,
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
