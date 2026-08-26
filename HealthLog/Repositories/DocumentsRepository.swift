import CryptoKit
import Foundation

/// A short-lived authorization for one server-mediated document-AI operation.
/// The bearer is captured with the consenting owner so a logout, token rotation,
/// or A→B account switch can never rebuild the request under a different user.
struct DocumentAIConsentLease: Sendable, Equatable {
    enum Scope: Sendable, Equatable {
        case serverManaged
        case serverProvider(AIProvider)
    }

    let ownerUserID: String
    let bearerToken: String
    let scope: Scope

    var authorizationHeader: String {
        "Bearer \(bearerToken)"
    }
}

/// Resolves the lease that is valid *right now*. Repositories read it once to
/// capture the account/scope, then again immediately before transport. `nil` is
/// the fail-closed default, including while provider config is still loading.
struct DocumentAIConsentLeaseProvider: Sendable {
    private let resolve: @Sendable () async -> DocumentAIConsentLease?

    init(_ resolve: @escaping @Sendable () async -> DocumentAIConsentLease?) {
        self.resolve = resolve
    }

    func currentLease() async -> DocumentAIConsentLease? {
        await resolve()
    }

    static let denied = DocumentAIConsentLeaseProvider { nil }
}

enum DocumentAIConsentError: Error, Sendable, Equatable {
    case consentRequired
}

/// Actor repository for the "Dokumente" document-vault surface — the server's
/// `/api/documents/inbound*` contract (opt-in `inboundDocuments` module).
///
/// Clones the ``LabsRepository`` / ``IllnessRepository`` posture: reads go
/// network-direct through `APIClient` (the ``DocumentsStore`` holds the in-memory
/// snapshot); a clean `module.disabled` (403) discriminator lets the store render
/// the enable-CTA state instead of a hard error; every route is owner-scoped +
/// gated server-side.
///
/// **Write durability (deliberate, documented).** The metadata writes here
/// (`PATCH` rename/recategorise/relink, soft-`DELETE`, `POST /restore`, and the
/// `POST /bulk` action) are INTERACTIVE — the user is looking at the detail sheet
/// or the bulk bar and expects immediate, honest success/failure feedback (web
/// parity: the web surfaces `saveError` / `bulk.failed` inline). They are NOT
/// routed through the encrypted-payload `OutboxQueue`; this mirrors the
/// established `MeasurementReminderRepository` precedent ("interactive CRUD, no
/// outbox by design"). Every mutating call still carries an `Idempotency-Key`
/// (stamped by `APIClient` on POST/PATCH/DELETE) so an in-request retry after a
/// flaky response can't double-apply.
///
/// **Upload durability.** The binary multipart **upload** cannot ride the
/// encrypted-payload outbox — that store is built for small JSON payloads, and
/// persisting up-to-`maxFileBytes` of encrypted PHI file bytes into the SwiftData
/// SQLite would bloat the store and is out of its design envelope. Instead the
/// upload is made durable/retry-safe by three cooperating mechanisms: (1)
/// `APIClient`'s built-in transport retry loop covers transient 5xx / network
/// blips within the request; (2) a per-upload `Idempotency-Key` PLUS the server's
/// same-bytes **sha256 content dedupe** make any manual retry duplicate-safe (a
/// re-upload of already-stored bytes returns `200` + `meta.duplicate: true` with
/// the existing row — a success, not a double-write); and (3) the source bytes
/// live on the ``DocumentUploadDraft`` the store holds (the picked file was copied
/// into a temp path / the scanned page re-encoded to JPEG) so a failed upload can
/// be re-triggered without re-picking. Full offline-queue durability for uploads
/// is intentionally deferred (see the module report).
public actor DocumentsRepository {
    /// `internal` (not `private`) so the `+Assist` extension file (the vault
    /// Phase 2 AI routes) can reach the client — an actor's `private` member is
    /// file-scoped and would be invisible across the split.
    let api: APIClientProtocol

    /// Local gate for requests that authorize the server to expose a stored
    /// original/OCR body to document AI. The default denies, so a repository
    /// constructed outside the app composition root cannot accidentally egress.
    let externalAIConsent: DocumentAIConsentLeaseProvider

    public init(api: APIClientProtocol) {
        self.api = api
        externalAIConsent = .denied
    }

    init(api: APIClientProtocol, externalAIConsent: DocumentAIConsentLeaseProvider) {
        self.api = api
        self.externalAIConsent = externalAIConsent
    }

    /// Sends one document-AI trigger under a freshly revalidated account-bound
    /// consent lease. Automatic retries are disabled: every wire attempt must
    /// return through this gate and capture current consent again.
    func requestWithExternalAIConsent<Response: Sendable>(
        _ request: APIRequest<Response>
    ) async throws -> (request: APIRequest<Response>, lease: DocumentAIConsentLease) {
        guard let capturedLease = await externalAIConsent.currentLease() else {
            throw DocumentAIConsentError.consentRequired
        }
        guard await externalAIConsent.currentLease() == capturedLease else {
            throw DocumentAIConsentError.consentRequired
        }

        var headers = request.extraHeaders
        headers["Authorization"] = capturedLease.authorizationHeader
        let leasedRequest = APIRequest<Response>(
            method: request.method,
            path: request.path,
            query: request.query,
            body: request.body,
            extraHeaders: headers,
            idempotencyKey: request.idempotencyKey,
            maxRetries: 0,
            failFast: request.failFast,
            streaming: request.streaming,
            allowsAuthenticationRecovery: false
        )
        return (leasedRequest, capturedLease)
    }

    func validateExternalAIConsent(_ capturedLease: DocumentAIConsentLease) async throws {
        guard await externalAIConsent.currentLease() == capturedLease else {
            throw DocumentAIConsentError.consentRequired
        }
    }

    func sendWithExternalAIConsent<Response: Decodable & Sendable>(
        _ request: APIRequest<Response>
    ) async throws -> Response {
        let leased = try await requestWithExternalAIConsent(request)

        do {
            let response = try await api.send(leased.request)
            try await validateExternalAIConsent(leased.lease)
            return response
        } catch {
            do {
                try await validateExternalAIConsent(leased.lease)
            } catch {
                throw DocumentAIConsentError.consentRequired
            }
            throw error
        }
    }

    // MARK: - Error discriminators

    /// True when an `HLError` is the server's `403 module.disabled` for the
    /// documents module (the user or operator switched `inboundDocuments` off).
    /// The store maps this to the enable-CTA surface (no retry).
    public nonisolated static func isModuleDisabled(_ error: Error) -> Bool {
        if case let HLError.moduleDisabled(module) = error {
            return module == ModuleKey.inboundDocuments.wireKey
        }
        if case let HLError.server(status, code, _) = error {
            return status == 403 && (code == nil || code == "module.disabled")
        }
        return false
    }

    /// True when a restore was refused because an identical live document already
    /// exists (`409`, `meta.reason = "duplicateExists"`) or the tombstone is
    /// purged past the 30-day grace. The store maps this to an inline message.
    public nonisolated static func isRestoreConflict(_ error: Error) -> Bool {
        if case let HLError.server(status, _, _) = error {
            return status == 409
        }
        return false
    }

    /// True when re-extraction was refused because at least one fact is already
    /// APPROVED (`409`, `documents.inbound.alreadyPartlyConfirmed`).
    public nonisolated static func isAlreadyPartlyConfirmed(_ error: Error) -> Bool {
        if case let HLError.server(status, code, message) = error {
            return status == 409 &&
                (code == "documents.inbound.alreadyPartlyConfirmed" ||
                    message.contains("alreadyPartlyConfirmed"))
        }
        return false
    }

    /// True when extraction is unavailable because no document-scan provider is
    /// configured (`422`, `documents.inbound.providerUnsupported`). The stored
    /// document is untouched — only the enhancement failed.
    public nonisolated static func isProviderUnsupported(_ error: Error) -> Bool {
        if case let HLError.server(status, code, message) = error {
            return status == 422 &&
                (code == "documents.inbound.providerUnsupported" ||
                    message.contains("providerUnsupported"))
        }
        return false
    }

    // MARK: - Reads

    /// `GET /api/documents/inbound` — a page of documents for the given filter.
    /// Sort is server-pinned (`documentDate desc`) unless overridden. `cursor` is
    /// the prior page's `nextCursor`.
    public func list(
        filter: DocumentListFilter = .init(),
        cursor: String? = nil,
        limit: Int = 50
    ) async throws -> InboundDocumentList {
        var query = filter.queryItems()
        query.append(("sort", "documentDate"))
        query.append(("order", "desc"))
        query.append(("limit", String(limit)))
        if let cursor, !cursor.isEmpty { query.append(("cursor", cursor)) }
        let frozen = query
        let req: APIRequest<InboundDocumentList> = .get("/api/documents/inbound", query: frozen)
        return try await api.send(req)
    }

    /// `GET /api/documents/inbound/usage` — storage usage + effective limits.
    /// Read this before offering an upload (per-file cap + quota pre-flight).
    public func usage() async throws -> DocumentUsage {
        let req: APIRequest<DocumentUsage> = .get("/api/documents/inbound/usage")
        return try await api.send(req)
    }

    /// `GET /api/documents/inbound/{id}` — the document plus its staged facts.
    public func detail(id: String) async throws -> InboundDocumentDetail {
        let req: APIRequest<InboundDocumentDetail> = .get("/api/documents/inbound/\(id)")
        return try await api.send(req)
    }

    /// `GET /api/documents/inbound/{id}/original` — the decrypted original bytes.
    /// Goes through `APIClient.download` so the pinned session + Bearer token
    /// apply (a bare `URL` in an image/PDF view would carry neither). Returns the
    /// bytes + the response so the caller can read the served `Content-Type` /
    /// filename when it needs them.
    public func original(id: String) async throws -> (Data, HTTPURLResponse) {
        let req: APIRequest<Data> = APIRequest(
            method: .get,
            path: "/api/documents/inbound/\(id)/original",
            extraHeaders: ["Accept": "application/pdf, image/*, application/octet-stream"]
        )
        return try await api.download(req)
    }

    // MARK: - Metadata writes (interactive; idempotency-keyed; no outbox)

    /// `PATCH /api/documents/inbound/{id}` — rename / recategorise / re-file / set
    /// the condition replace-set. Returns the updated document + its staged facts.
    @discardableResult
    public func update(id: String, _ patch: DocumentPatch) async throws -> InboundDocumentDetail {
        let req: APIRequest<InboundDocumentDetail> = try .patch("/api/documents/inbound/\(id)", body: patch)
        return try await api.send(req)
    }

    /// `DELETE /api/documents/inbound/{id}` — soft-delete (30-day undo grace).
    /// Returns `true` when discarded.
    @discardableResult
    public func delete(id: String) async throws -> Bool {
        let req: APIRequest<DiscardResult> = .delete("/api/documents/inbound/\(id)")
        return try await api.send(req).discarded
    }

    /// `POST /api/documents/inbound/{id}/restore` — clear the soft-delete
    /// tombstone within the 30-day grace. Returns the restored document + facts.
    /// A `409` (purged / live duplicate) surfaces via ``isRestoreConflict(_:)``.
    @discardableResult
    public func restore(id: String) async throws -> InboundDocumentDetail {
        let req: APIRequest<InboundDocumentDetail> = try .post(
            "/api/documents/inbound/\(id)/restore", body: EmptyPayload()
        )
        return try await api.send(req)
    }

    /// `POST /api/documents/inbound/bulk` — one action over ≤ 100 owner-scoped
    /// ids; returns the per-id result array (a partial failure never aborts).
    /// Chunks ids at ``DocumentBulkRequest/maxIds`` and merges the results.
    @discardableResult
    public func bulk(
        ids: [String],
        action: DocumentBulkAction,
        kind: DocumentKind? = nil,
        episodeId: String? = nil
    ) async throws -> DocumentBulkResponse {
        guard !ids.isEmpty else { return DocumentBulkResponse(results: []) }
        var merged: [DocumentBulkResponse.Result] = []
        for chunk in ids.chunked(into: DocumentBulkRequest.maxIds) {
            let body = DocumentBulkRequest(ids: chunk, action: action, kind: kind, episodeId: episodeId)
            let req: APIRequest<DocumentBulkResponse> = try .post("/api/documents/inbound/bulk", body: body)
            let page = try await api.send(req)
            merged.append(contentsOf: page.results)
        }
        return DocumentBulkResponse(results: merged)
    }

    // MARK: - Extraction (optional AI enhancement)

    /// `POST /api/documents/inbound/{id}/extract` — stage structured facts from
    /// the stored original. VISION mode (empty body) scans the stored file; TEXT
    /// mode structures browser-OCR'd text. Returns the document + newly staged
    /// facts. `422 providerUnsupported` / `409 alreadyPartlyConfirmed` surface via
    /// the discriminators above.
    @discardableResult
    public func extract(id: String, text: DocumentTextExtractRequest? = nil) async throws -> InboundDocumentDetail {
        // The server dispatches on `Content-Type`: an `application/json` request
        // routes to the TEXT (local-OCR) handler. VISION mode must send NO body so
        // it reaches the vision handler; TEXT mode sends the on-device-OCR JSON.
        if let text {
            let req: APIRequest<InboundDocumentDetail> = try .post(
                "/api/documents/inbound/\(id)/extract", body: text
            )
            return try await sendWithExternalAIConsent(req)
        }
        let req = APIRequest<InboundDocumentDetail>(method: .post, path: "/api/documents/inbound/\(id)/extract")
        return try await sendWithExternalAIConsent(req)
    }

    // MARK: - Upload (multipart, store-only)

    /// `POST /api/documents/inbound` — STORE-only multipart upload. Pre-flights
    /// the per-file cap + remaining quota from `usage` (when supplied), builds the
    /// `multipart/form-data` body (file + optional title/kind/documentDate +
    /// repeated episodeIds), and maps the 200-duplicate / 201-created / 413 / 415
    /// / 429 outcomes. Throws ``DocumentUploadError`` for a classifiable failure;
    /// re-throws an `HLError.moduleDisabled` / `.unauthorized` so the store can
    /// route it (module gate / re-auth).
    public func upload(_ draft: DocumentUploadDraft, usage: DocumentUsage?) async throws -> DocumentUploadOutcome {
        // Pre-flight against the effective limits (deterministic; distinguishes
        // fileTooLarge from quotaExceeded client-side, matching the web pre-flight).
        if let usage, usage.maxFileBytes > 0 {
            if draft.data.count > usage.maxFileBytes {
                throw DocumentUploadError.fileTooLarge(maxFileBytes: usage.maxFileBytes)
            }
            if usage.quotaBytes > 0, draft.data.count > usage.remainingBytes {
                throw DocumentUploadError.quotaExceeded(quotaBytes: usage.quotaBytes, usedBytes: usage.usedBytes)
            }
        }

        let boundary = "HLDocBoundary-\(UUID().uuidString)"
        let body = Self.multipartBody(draft: draft, boundary: boundary)
        let req: APIRequest<Data> = APIRequest(
            method: .post,
            path: "/api/documents/inbound",
            body: body,
            extraHeaders: [
                "Content-Type": "multipart/form-data; boundary=\(boundary)",
                "Accept": "application/json"
            ],
            // A store-only upload must not be silently re-issued by the transport
            // retry loop mid-way (a partial POST could double-count); the server's
            // sha256 dedupe + the stamped Idempotency-Key make a *manual* retry
            // safe, which is the durability we want. So no in-request retries.
            maxRetries: 0
        )

        do {
            let (data, response) = try await api.download(req)
            let envelope = try JSONDecoder.hlDefault.decode(UploadEnvelope.self, from: data)
            guard let document = envelope.data else {
                throw DocumentUploadError.generic("upload: empty document in response")
            }
            let isDuplicate = envelope.meta?.duplicate == true || response.statusCode == 200
            return DocumentUploadOutcome(document: document, isDuplicate: isDuplicate)
        } catch let error as DocumentUploadError {
            throw error
        } catch HLError.rateLimited(_) {
            throw DocumentUploadError.rateLimited
        } catch let HLError.server(status, _, _) {
            throw Self.mapServerUploadError(status: status, draft: draft, usage: usage)
        } catch let error as HLError where Self.isModuleDisabled(error) || error == .unauthorized {
            // Route these to the store's own handling (enable-CTA / re-auth).
            throw error
        } catch {
            throw DocumentUploadError.generic(LogSanitizer.redact(String(describing: error)))
        }
    }

    /// Maps a server upload rejection status onto a typed ``DocumentUploadError``.
    /// Mirrors the web `classifyUploadFailure` HTTP fallback (413 → too-large /
    /// quota, 415 → unsupported, 429 → rate-limited); the ambiguous 413 is split
    /// by the pre-flight math when `usage` is known.
    nonisolated static func mapServerUploadError(
        status: Int,
        draft: DocumentUploadDraft,
        usage: DocumentUsage?
    ) -> DocumentUploadError {
        switch status {
        case 413:
            if let usage, usage.quotaBytes > 0, draft.data.count > usage.remainingBytes {
                return .quotaExceeded(quotaBytes: usage.quotaBytes, usedBytes: usage.usedBytes)
            }
            return .fileTooLarge(maxFileBytes: usage?.maxFileBytes ?? draft.data.count)
        case 415:
            return .unsupportedType
        case 429:
            return .rateLimited
        default:
            return .generic("HTTP \(status)")
        }
    }

    /// SHA-256 hex of the draft bytes — surfaced for local same-bytes detection /
    /// stable idempotency if a caller wants it (the server is the authoritative
    /// deduper). Pure + nonisolated so callers can hash without an actor hop.
    public nonisolated static func contentSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Builds a `multipart/form-data` body with the file part + the optional text
    /// fields (title / kind / documentDate) + one `episodeIds` part per id. CRLF
    /// line endings per RFC 7578.
    nonisolated static func multipartBody(draft: DocumentUploadDraft, boundary: String) -> Data {
        var body = Data()
        let crlf = "\r\n"
        func boundaryLine() {
            body.append(Data("--\(boundary)\(crlf)".utf8))
        }
        func field(_ name: String, _ value: String) {
            boundaryLine()
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\(crlf)\(crlf)".utf8))
            body.append(Data("\(value)\(crlf)".utf8))
        }
        // File part first.
        boundaryLine()
        body.append(Data(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(draft.filename)\"\(crlf)".utf8
        ))
        body.append(Data("Content-Type: \(draft.mimeType)\(crlf)\(crlf)".utf8))
        body.append(draft.data)
        body.append(Data(crlf.utf8))
        // Optional metadata.
        if let title = draft.title, !title.isEmpty { field("title", title) }
        if let kind = draft.kind { field("kind", kind.rawValue) }
        if let date = draft.documentDate, !date.isEmpty { field("documentDate", date) }
        for episodeId in draft.episodeIds {
            field("episodeIds", episodeId)
        }
        // Closing boundary.
        body.append(Data("--\(boundary)--\(crlf)".utf8))
        return body
    }

    // MARK: - Wire helpers

    /// `DELETE` response: `{ id, discarded }`. Tolerant — a bare `{}` decodes.
    private struct DiscardResult: Decodable {
        let discarded: Bool

        init(from decoder: Decoder) throws {
            let c = try? decoder.container(keyedBy: CodingKeys.self)
            discarded = (try? c?.decodeIfPresent(Bool.self, forKey: .discarded)) ?? true
        }

        private enum CodingKeys: String, CodingKey { case discarded }
    }

    /// The upload envelope, decoded directly off `download` so the success-side
    /// `meta.duplicate` (a 200 same-bytes re-upload) is visible — the generic
    /// `APIClient.send` strips `meta`.
    private struct UploadEnvelope: Decodable {
        let data: InboundDocument?
        let meta: Meta?

        struct Meta: Decodable {
            let duplicate: Bool?

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                duplicate = try c.decodeIfPresent(Bool.self, forKey: .duplicate)
            }

            private enum CodingKeys: String, CodingKey { case duplicate }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            data = try c.decodeIfPresent(InboundDocument.self, forKey: .data)
            meta = try? c.decodeIfPresent(Meta.self, forKey: .meta)
        }

        private enum CodingKeys: String, CodingKey { case data, meta }
    }
}

// MARK: - DocumentListFilter

/// The list facets — search `q`, a `kind` OR-set, a single `episodeId`, and a
/// `year` (which the server prefers over a from/to range). Sort/order/cursor/
/// limit are supplied by ``DocumentsRepository/list(filter:cursor:limit:)``.
public struct DocumentListFilter: Sendable, Equatable {
    public var q: String?
    public var kinds: [DocumentKind]
    public var episodeId: String?
    public var year: Int?

    public init(q: String? = nil, kinds: [DocumentKind] = [], episodeId: String? = nil, year: Int? = nil) {
        self.q = q
        self.kinds = kinds
        self.episodeId = episodeId
        self.year = year
    }

    /// `true` when any facet is active — drives the "clear filters" affordance +
    /// the filtered-vs-unfiltered empty state.
    public var isActive: Bool {
        !(q ?? "").isEmpty || !kinds.isEmpty || !(episodeId ?? "").isEmpty || year != nil
    }

    /// The number of active facets (search + each kind + episode + year), for the
    /// clear-filters pill count (web `countActiveFilters`).
    public var activeCount: Int {
        var count = 0
        if !(q ?? "").isEmpty { count += 1 }
        count += kinds.count
        if !(episodeId ?? "").isEmpty { count += 1 }
        if year != nil { count += 1 }
        return count
    }

    /// The query items for the list request. `kind` is repeated once per selected
    /// kind (the server accepts repeats or a comma-joined value; repeats are the
    /// explode-true form in the contract).
    func queryItems() -> [(String, String)] {
        var items: [(String, String)] = []
        if let q, !q.isEmpty { items.append(("q", q)) }
        for kind in kinds {
            items.append(("kind", kind.rawValue))
        }
        if let episodeId, !episodeId.isEmpty { items.append(("episodeId", episodeId)) }
        if let year { items.append(("year", String(year))) }
        return items
    }
}

// MARK: - Chunking helper

private extension Array {
    /// Splits into consecutive slices of at most `size` (used to cap bulk ids).
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}
