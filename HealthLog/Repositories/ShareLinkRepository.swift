import Foundation

/// Wraps the clinician share-link endpoints (server v1.12.1, Bearer-auth, no
/// scope — `src/app/api/share-links/route.ts` + `[id]/route.ts`):
///
/// - `POST /api/share-links`  → mint a link, returns the raw `hls_` token **once**.
/// - `GET  /api/share-links`  → list active + past links (token-less).
/// - `DELETE /api/share-links/{id}` → revoke; a re-revoke returns **404**.
///
/// **Idempotency contract (B1).** Revoke uses `updateMany where { id, userId,
/// revokedAt: null }`, so an unknown / cross-user / already-revoked id all return
/// 404. ``revoke(id:)`` therefore treats a 404 as **success-equivalent** ("already
/// gone") rather than surfacing it as an error — a second tap or a stale list never
/// produces a spurious failure.
///
/// **Rate limit.** 20 ops/hour per user shared across create + revoke. `APIClient`
/// already maps 429 to ``HLError/rateLimited(retryAfter:)``; callers surface it via
/// `userFacingDescription`.
///
/// **Secrets.** The raw token is never logged and never persisted by this
/// repository — it lives only in the create response handed straight to the UI for
/// copy/share. The list is the authoritative state.
public actor ShareLinkRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// List the caller's share-links (token-less projection). Newest server order
    /// is preserved.
    public func list() async throws -> [ShareLinkDTO] {
        let req: APIRequest<ShareLinkListResponse> = .get("/api/share-links")
        let response = try await api.send(req)
        return response.shareLinks
    }

    /// Mint a new share-link. The returned ``ShareLinkDTO/token`` is the raw
    /// `hls_…` token and is present **only** on this response — present it to the
    /// user for copy/share immediately; it is unrecoverable afterwards.
    ///
    /// - Throws: ``ShareLinkError`` when the server refuses the *selection*
    ///   (`422 share-link.selection.*`); any other failure passes through as the
    ///   original ``HLError``.
    public func create(_ body: CreateShareLinkBody) async throws -> ShareLinkDTO {
        let req: APIRequest<ShareLinkDTO> = try .post("/api/share-links", body: body)
        let link: ShareLinkDTO
        do {
            link = try await api.send(req)
        } catch {
            throw ShareLinkError.mapped(error)
        }
        // Defence-in-depth: never log the token. We log only the non-secret id +
        // whether a token was returned, so a regression that drops the token is
        // observable without ever emitting the secret itself.
        HLLog.api.info(
            "share-link created id=\(link.id, privacy: .private) hasToken=\(link.token != nil)"
        )
        return link
    }

    /// Revoke a share-link. Returns normally on a real revoke (200) **and** on a
    /// 404 (already revoked / unknown id) — both mean "the link is gone", which is
    /// what the caller wants. Any other error propagates.
    public func revoke(id: String) async throws {
        let req: APIRequest<EmptyPayload> = .delete("/api/share-links/\(id)")
        do {
            try await api.sendVoid(req)
        } catch let HLError.server(status, _, _) where status == 404 {
            // Re-revoke / unknown id → already gone. Success-equivalent per B1.
            HLLog.api.info("share-link revoke 404 (already gone) id=\(id, privacy: .private)")
        }
    }
}

// MARK: - Selection refusals

/// The `422` classes `POST /api/share-links` raises about the **selection**.
///
/// Without this mapping the raw wire code reaches the user: `HLError.server`
/// surfaces a 4xx `message` verbatim (it is normally server-localised prose),
/// so a refusal would render as the literal string
/// `share-link.selection.forbidden_leaf`. That is the "generic error" the
/// acceptance criterion rules out.
///
/// **Wire detail, same as CU-01's ``ReportSelectionError``:** these codes ride
/// in the envelope's top-level `error` *string*, not in `meta.errorCode` — the
/// route throws `HttpError(422, "<code>")` and the handler serialises the
/// message verbatim. ``mapped(_:)`` matches ``HLError/server``'s `code` *and*
/// `message`, so a later server change that promotes the code into
/// `meta.errorCode` needs no iOS change.
public enum ShareLinkError: Error, Sendable, Equatable {
    /// `422 share-link.selection.forbidden_leaf` — the selection carried a leaf
    /// this route refuses regardless of the catalogue (`INSURANCE` today, see
    /// ``ShareLinkSelectionPolicy/forbiddenLeaves``). The UI never offers those,
    /// so reaching this means a selection arrived from elsewhere.
    case forbiddenLeaf
    /// Any other `422` whose code names the selection
    /// (`share-link.selection.<something>`). Deliberately open-ended: we do not
    /// invent codes the server has not documented, but a code we cannot name is
    /// still a selection refusal and must never be shown raw.
    case selectionRejected

    /// Prefix every selection refusal on this route shares.
    static let selectionCodePrefix = "share-link.selection."

    /// The one documented code, matched exactly.
    static let forbiddenLeafCode = "share-link.selection.forbidden_leaf"

    /// Recognise a selection refusal in a raw error, or return the error
    /// untouched. Never invents a class: anything that is not a `422` naming the
    /// selection passes through as-is, so transport failures, 401s, 429s and
    /// 5xx keep their existing handling.
    static func mapped(_ error: Error) -> Error {
        guard let hlError = error as? HLError,
              case let .server(status, code, message) = hlError,
              status == 422 else
        {
            return error
        }
        var tokens: [String] = [message]
        if let code { tokens.append(code) }
        guard tokens.contains(where: { $0.hasPrefix(selectionCodePrefix) }) else {
            return error
        }
        return tokens.contains(forbiddenLeafCode) ? Self.forbiddenLeaf : Self.selectionRejected
    }

    /// User-facing copy. Says what was refused and what to do — never the code.
    public var userFacingDescription: String {
        switch self {
        case .forbiddenLeaf:
            String(localized: "shareLink.error.forbiddenLeaf")
        case .selectionRejected:
            String(localized: "shareLink.error.selectionRejected")
        }
    }
}
