import Foundation

// MARK: - Which 401s are an answer, not a dead session

extension APIClient {
    /// Whether a 401 on `path` with `body` surfaces typed (`.server(401, …)`
    /// via `ensureSuccess`) instead of entering the refresh-then-logout bridge.
    ///
    /// Three reasons, one place: the paths that always keep their 401 body
    /// (``preserves401Body(path:)``), a proof-family code on any path
    /// (``SecurityStepUp/isProofRefusal(body:)``, R2 / #115 A3), and since B5
    /// (1.4) a route's own credential check answering
    /// (``isCredentialCheckRefusal(path:body:)``).
    nonisolated static func surfaces401(path: String, body: Data) -> Bool {
        preserves401Body(path: path)
            || SecurityStepUp.isProofRefusal(body: body)
            || isCredentialCheckRefusal(path: path, body: body)
    }

    /// **B5 (1.4)** — a 401 that refuses a credential the request carried in
    /// its body, not the session that sent it.
    ///
    /// `POST /api/auth/password` answers a wrong current password with 401
    /// (`apiError("Current password is incorrect", 401)`, server v1.43.10;
    /// `meta.errorCode` is the default `http.unauthenticated` since v1.43.7 and
    /// absent before). Read as a dead session, the bridge refreshed, sent the
    /// change a second time (a second guess against the account's re-proof
    /// budget), met the same 401 and signed the person out. On these paths a
    /// 401 is the route's answer unless it names the session itself: the
    /// server's session codes (`AUTH_ERROR_CODES`, v1.38.15) still refresh.
    nonisolated static func isCredentialCheckRefusal(path: String, body: Data) -> Bool {
        guard credentialCheckPaths.contains(path) else { return false }
        guard let code = errorCode(in: body) else { return true }
        return !sessionRefusalCodes.contains(code)
    }

    /// The routes that check a credential carried in the request body.
    nonisolated static let credentialCheckPaths: Set<String> = ["/api/auth/password"]

    /// 401 codes that speak about the bearer: no credential, an expired one,
    /// an unknown or revoked one. These keep the refresh-then-logout bridge.
    nonisolated static let sessionRefusalCodes: Set<String> = [
        "auth.missing",
        "auth.token.expired",
        "auth.token.invalid"
    ]

    /// `meta.errorCode`, or the pre-v1.39 top-level `errorCode`, of an error body.
    private nonisolated static func errorCode(in body: Data) -> String? {
        struct Envelope: Decodable {
            struct Meta: Decodable {
                let errorCode: String?
            }

            let meta: Meta?
            let errorCode: String?
        }
        guard !body.isEmpty, let envelope = try? JSONDecoder().decode(Envelope.self, from: body) else { return nil }
        return envelope.meta?.errorCode ?? envelope.errorCode
    }
}
