import Foundation

/// Vault Phase 2 (server v1.27.22, iOS issue #43) — the additive AI-assist +
/// content-search endpoints on the document vault. All owner-scoped, all gated
/// server-side on the existing AI consent (there is NO new module toggle); the
/// client additionally ANDs `DocumentUsage.assistAvailable` with the app's own
/// AI-consent gate before ever offering these actions (see the detail screen).
///
/// **Write posture.** `/suggest` and `/summary` are POSTs that write NOTHING —
/// a suggestion is a draft the user reviews, a summary is session-only. `/index`
/// and `/reindex` DO persist (the blind content index: AES-GCM ciphertext + HMAC
/// token hashes, never plaintext) and are idempotent — the server overwrites the
/// index in place, so a stamped `Idempotency-Key` (added by `APIClient` on every
/// POST) makes an in-request retry safe. Like the other document writes these are
/// interactive (the user is looking at the detail sheet) and NOT outbox-routed.
public extension DocumentsRepository {
    // MARK: - Suggest (filing-metadata draft; writes nothing)

    /// `POST /api/documents/inbound/{id}/suggest` — one provider call returning a
    /// `{ title, kind, documentDate }` DRAFT for the edit form. VISION mode scans
    /// the stored original; TEXT mode structures browser-OCR'd text. Writes
    /// nothing — the user reviews + saves. `422 providerUnsupported` surfaces via
    /// ``isProviderUnsupported(_:)``.
    ///
    /// **Body contract (critical).** The server dispatches on `Content-Type`:
    /// any `application/json` request is routed to the TEXT (local-OCR) handler,
    /// which requires an enabled local-OCR flag + a `{ mode, text }` body. VISION
    /// mode must therefore send **no body at all** (no JSON, no Content-Type) so
    /// the request reaches the vision handler — sending an empty `{}` object would
    /// be mis-routed to TEXT and fail immediately. TEXT mode sends the JSON body.
    ///
    /// POLISH-B B7: on a server of v1.40 or newer the read prefers a
    /// background run (see ``assistPrefersRun(defaults:)``).
    func suggest(
        id: String,
        text: DocumentAiTextRequest? = nil,
        preferRun: Bool = assistPrefersRun()
    ) async throws -> DocumentSuggestion {
        if preferRun {
            let outcome = try await sendPreferringRun(
                path: "/api/documents/inbound/\(id)/suggest",
                body: text.map { try JSONEncoder.hlDefault.encode($0) },
                sync: DocumentSuggestResponse.self,
                run: DocumentSuggestResponse.self
            )
            switch outcome {
            case let .sync(response), let .run(response):
                return response.suggestions
            }
        }
        let req: APIRequest<DocumentSuggestResponse> = if let text {
            try .post("/api/documents/inbound/\(id)/suggest", body: text)
        } else {
            APIRequest(method: .post, path: "/api/documents/inbound/\(id)/suggest")
        }
        return try await sendWithExternalAIConsent(req).suggestions
    }

    // MARK: - Summary (session-only; nothing persisted)

    /// `POST /api/documents/inbound/{id}/summary?mode=summary|text` — a
    /// session-only plain-language summary (`.summary`) or the raw transcribed
    /// text (`.text`). Nothing is persisted; the result is descriptive only, not
    /// a diagnosis. VISION mode (empty body) or TEXT mode (on-device OCR).
    func summary(
        id: String,
        mode: DocumentSummaryMode = .summary,
        text: DocumentAiTextRequest? = nil,
        preferRun: Bool = assistPrefersRun()
    ) async throws -> DocumentSummary {
        let path = "/api/documents/inbound/\(id)/summary"
        // `mode` rides the query array (the path is appended as a path component,
        // so a literal "?mode=" would be percent-encoded into the path). VISION
        // mode sends NO body (see `suggest` — a JSON body mis-routes to the TEXT
        // handler server-side); TEXT mode sends the on-device-OCR JSON.
        let body: Data? = if let text {
            try JSONEncoder.hlDefault.encode(text)
        } else {
            nil
        }
        if preferRun {
            let outcome = try await sendPreferringRun(
                path: path,
                query: [("mode", mode.rawValue)],
                body: body,
                sync: DocumentSummary.self,
                run: DocumentSummary.self
            )
            switch outcome {
            case let .sync(summary), let .run(summary):
                return summary
            }
        }
        let req = APIRequest<DocumentSummary>(
            method: .post,
            path: path,
            query: [("mode", mode.rawValue)],
            body: body
        )
        return try await sendWithExternalAIConsent(req)
    }

    // MARK: - Background run for suggest and summary (POLISH-B B7)

    /// The first server release whose suggest and summary routes take
    /// `Prefer: respond-async` (SRV-REQ H).
    static let assistRunMinimumServerVersion = "1.40.0"

    /// Whether suggest and summary send `Prefer: respond-async`: only on a
    /// server known to be v1.40 or newer (rule 10, unknown means no). There
    /// the read runs in the background like `extract` and `index`, so a slow
    /// reader no longer hits the request timeout; the run's result is the body
    /// the route answers synchronously. Without it the request is the 1.4 one.
    static func assistPrefersRun(defaults: UserDefaults = .standard) -> Bool {
        KnownServerVersion.isAtLeast(assistRunMinimumServerVersion, defaults: defaults)
    }

    // MARK: - Content index (per-document + corpus backfill)

    /// `POST /api/documents/inbound/{id}/index` — build / refresh one document's
    /// blind content-search index so search matches inside its body. VISION mode
    /// (empty body) transcribes the stored original server-side; TEXT mode
    /// indexes on-device-OCR'd text with no provider egress. Idempotent — a
    /// re-index overwrites in place. Prefers a background run (#151, see
    /// `DocumentsRepository+Runs.swift`).
    @discardableResult
    func index(id: String, text: DocumentAiTextRequest? = nil) async throws -> DocumentIndexResult {
        // VISION mode sends NO body (a JSON body mis-routes to the TEXT handler
        // server-side); TEXT mode sends the on-device-OCR JSON.
        let body = try text.map { try JSONEncoder.hlDefault.encode($0) }
        return try await indexPreferringRun(id: id, body: body)
    }

    /// `POST /api/documents/inbound/reindex` — enqueue a bounded, resumable
    /// backfill that content-indexes every not-yet-indexed document off-request.
    /// Returns immediately (`{ enqueued }`).
    @discardableResult
    func reindexAll() async throws -> DocumentReindexResult {
        let req: APIRequest<DocumentReindexResult> = try .post(
            "/api/documents/inbound/reindex", body: EmptyPayload()
        )
        return try await sendWithExternalAIConsent(req)
    }
}
