import Foundation

// Write-side DTOs for the documents contract: metadata PATCH, bulk action, the
// text-extract request, and the upload outcome / typed upload failure.

// MARK: - DocumentPatch (metadata edit)

/// `PATCH /api/documents/inbound/{id}` — rename / recategorise / re-file / set
/// the condition replace-set. Only the fields you supply are sent; `title` and
/// `documentDate` are tri-state (omit = untouched, explicit `null` = clear),
/// modelled as a ``Field`` list so an intentional clear survives encoding.
public struct DocumentPatch: Encodable, Sendable, Equatable {
    /// A single metadata edit. `title(nil)` / `documentDate(nil)` encode an
    /// explicit JSON `null` (clear); omitting the field leaves it untouched.
    public enum Field: Sendable, Equatable {
        case title(String?)
        case kind(DocumentKind)
        case documentDate(String?)
        /// Replace-set of condition-episode links (server contract: ≤ 20 ids).
        case episodeIds([String])
    }

    public var fields: [Field]

    public init(_ fields: [Field]) {
        self.fields = fields
    }

    /// Convenience for the common single-field edits.
    public static func title(_ value: String?) -> DocumentPatch {
        .init([.title(value)])
    }

    public static func kind(_ value: DocumentKind) -> DocumentPatch {
        .init([.kind(value)])
    }

    public static func documentDate(_ value: String?) -> DocumentPatch {
        .init([.documentDate(value)])
    }

    public static func episodeIds(_ value: [String]) -> DocumentPatch {
        .init([.episodeIds(value)])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        for field in fields {
            switch field {
            case let .title(value): try c.encode(value, forKey: .title) // encodes null when nil
            case let .kind(value): try c.encode(value.rawValue, forKey: .kind)
            case let .documentDate(value): try c.encode(value, forKey: .documentDate)
            case let .episodeIds(value): try c.encode(value, forKey: .episodeIds)
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case title, kind, documentDate, episodeIds
    }
}

// MARK: - DocumentBulkAction

/// `{ setKind | linkEpisode | unlinkEpisode | delete | restore }` — the bulk verb.
public enum DocumentBulkAction: String, Codable, Sendable, Equatable, Hashable {
    case setKind
    case linkEpisode
    case unlinkEpisode
    case delete
    case restore
}

// MARK: - DocumentBulkRequest

/// `POST /api/documents/inbound/bulk` — one action over ≤ 100 owner-scoped ids.
/// `kind` is required for `setKind`; `episodeId` for `linkEpisode`/`unlinkEpisode`.
public struct DocumentBulkRequest: Encodable, Sendable, Equatable {
    /// Server cap on ids per call.
    public static let maxIds = 100

    public let ids: [String]
    public let action: DocumentBulkAction
    public let kind: DocumentKind?
    public let episodeId: String?

    public init(ids: [String], action: DocumentBulkAction, kind: DocumentKind? = nil, episodeId: String? = nil) {
        self.ids = ids
        self.action = action
        self.kind = kind
        self.episodeId = episodeId
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ids, forKey: .ids)
        try c.encode(action.rawValue, forKey: .action)
        try c.encodeIfPresent(kind?.rawValue, forKey: .kind)
        try c.encodeIfPresent(episodeId, forKey: .episodeId)
    }

    private enum CodingKeys: String, CodingKey {
        case ids, action, kind, episodeId
    }
}

// MARK: - DocumentBulkResponse (per-id outcomes)

/// The per-id result array from a bulk action — a partial failure never aborts
/// the batch. `error` is `notFound` (unknown / foreign / tombstoned) or
/// `conflict` (restore blocked by a live duplicate).
public struct DocumentBulkResponse: Decodable, Sendable, Equatable {
    public struct Result: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let ok: Bool
        public let error: String?

        public init(id: String, ok: Bool, error: String?) {
            self.id = id
            self.ok = ok
            self.error = error
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false
            error = try c.decodeIfPresent(String.self, forKey: .error)
        }

        private enum CodingKeys: String, CodingKey {
            case id, ok, error
        }
    }

    public let results: [Result]

    /// Count of ids that succeeded / failed — drives the bulk toast copy.
    public var okCount: Int {
        results.filter(\.ok).count
    }

    public var failedCount: Int {
        results.filter { !$0.ok }.count
    }

    public init(results: [Result]) {
        self.results = results
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = try c.decodeIfPresent([Result].self, forKey: .results) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case results
    }
}

// MARK: - DocumentTextExtractRequest

/// `POST /api/documents/inbound/{id}/extract` TEXT mode body (`{ mode: "text",
/// text, kind? }`). VISION mode sends no body (see the repository).
public struct DocumentTextExtractRequest: Encodable, Sendable, Equatable {
    public let mode: String
    public let text: String
    public let kind: DocumentKind?

    public init(text: String, kind: DocumentKind? = nil) {
        mode = "text"
        self.text = text
        self.kind = kind
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(kind?.rawValue, forKey: .kind)
    }

    private enum CodingKeys: String, CodingKey {
        case mode, text, kind
    }
}

// MARK: - DocumentUploadDraft (a picked/scanned file ready to store)

/// The bytes + metadata for one store-only upload. The bytes are held on the
/// caller side (the picked file was copied into a temp path, or the scanned page
/// re-encoded to JPEG) so a failed upload can be retried without re-picking.
public struct DocumentUploadDraft: Sendable, Equatable {
    public let data: Data
    public let filename: String
    public let mimeType: String
    public var title: String?
    public var kind: DocumentKind?
    /// `YYYY-MM-DD` filing date (defaults to the upload day server-side when nil).
    public var documentDate: String?
    /// Condition episodes to pre-link.
    public var episodeIds: [String]

    public init(
        data: Data,
        filename: String,
        mimeType: String,
        title: String? = nil,
        kind: DocumentKind? = nil,
        documentDate: String? = nil,
        episodeIds: [String] = []
    ) {
        self.data = data
        self.filename = filename
        self.mimeType = mimeType
        self.title = title
        self.kind = kind
        self.documentDate = documentDate
        self.episodeIds = episodeIds
    }
}

// MARK: - DocumentUploadOutcome

/// The result of a store-only upload. `isDuplicate` is `true` when the same bytes
/// were already stored — the server returns 200 + `meta.duplicate: true` with the
/// existing row (a success, not an error).
public struct DocumentUploadOutcome: Sendable, Equatable {
    public let document: InboundDocument
    public let isDuplicate: Bool

    public init(document: InboundDocument, isDuplicate: Bool) {
        self.document = document
        self.isDuplicate = isDuplicate
    }
}

// MARK: - DocumentOperationError (what a document operation can refuse on)

/// The user-facing classification of any document operation failure.
///
/// It exists so a view never has to inspect the store's sticky error slot, and
/// never has to string-match a protocol error, to learn what happened to the
/// operation it started. `DocumentUploadError` stays what it has always been —
/// the typed pre-flight/server upload reason — and is carried here rather than
/// duplicated.
public enum DocumentOperationError: Error, Sendable, Equatable {
    /// The upload was refused for a reason the user can act on (size, quota,
    /// type, rate limit) or for an opaque transport failure.
    case upload(DocumentUploadError)
    /// The `inboundDocuments` module is off — the surface, not the operation,
    /// is what has to change.
    case moduleDisabled
    /// There is no authenticated session to write under.
    case notAuthenticated
    /// The operation completed, but the question it belonged to had already
    /// been replaced (a new filter, a logout). Nothing was published and
    /// nothing should be said — this is not a failure the user caused.
    case superseded
}

// MARK: - DocumentWriteOutcome (what a document write returns)

/// What a document write actually did, returned to the surface that started it.
///
/// The point is the middle case. A bulk action over N ids can succeed for some
/// and be refused for others, and a caller that only learns "it threw / it
/// didn't" has to guess — which is how a half-refused batch used to clear the
/// whole selection and say nothing.
public enum DocumentWriteOutcome: Sendable, Equatable {
    /// Everything the caller asked for was applied.
    case completed(succeeded: Int)
    /// Some ids were applied and some were refused; both lists are the
    /// server's, per id.
    case partial(succeeded: [String], failed: [String])
    /// Nothing was applied.
    case failed(DocumentOperationError)

    /// The reason this write refused, or `nil` when at least part of it landed.
    public var failure: DocumentOperationError? {
        guard case let .failed(error) = self else { return nil }
        return error
    }

    public var succeededCount: Int {
        switch self {
        case let .completed(succeeded): succeeded
        case let .partial(succeeded, _): succeeded.count
        case .failed: 0
        }
    }

    public var failedCount: Int {
        switch self {
        case .completed: 0
        case let .partial(_, failed): failed.count
        case .failed: 1
        }
    }

    /// True only when nothing was refused and something was applied.
    public var isComplete: Bool {
        if case let .completed(succeeded) = self { return succeeded > 0 }
        return false
    }
}

// MARK: - DocumentImportOutcome (what a multi-source import did)

/// The aggregate of one import gesture — a multi-file pick, a photo selection,
/// a scan — over however many inputs it produced.
///
/// `unreadable` is separate from `failures` on purpose: a file that could not
/// be read never reached the network, so it is not a server refusal, and a pick
/// of N files that yields zero readable inputs is a visible failure rather than
/// a silent no-op.
public struct DocumentImportOutcome: Sendable, Equatable {
    /// Everything the user chose, readable or not.
    public let selected: Int
    /// Inputs the server accepted (a same-bytes duplicate counts as accepted).
    public let uploaded: Int
    /// Inputs that could not be read or re-encoded on the device.
    public let unreadable: Int
    /// Per-input refusals from the upload path, in the order they happened.
    public let failures: [DocumentOperationError]

    public init(selected: Int, uploaded: Int, unreadable: Int, failures: [DocumentOperationError]) {
        self.selected = selected
        self.uploaded = uploaded
        self.unreadable = unreadable
        self.failures = failures
    }

    public var failedCount: Int {
        unreadable + failures.count
    }

    /// True only when every selected input was stored. An import that stored
    /// nothing because nothing was selected is NOT complete — there is no
    /// success to dismiss on.
    public var isComplete: Bool {
        failedCount == 0 && selected > 0 && uploaded == selected
    }
}

// MARK: - DocumentUploadError (typed pre-flight + server failure)

/// A typed upload failure — the client pre-flights `fileTooLarge` / `quotaExceeded`
/// from `usage` before the network hop, and maps a server 413/415/429 onto the
/// same reasons (matching the web `classifyUploadFailure` fallback). Carries the
/// limit fields the UI needs for its copy.
public enum DocumentUploadError: Error, Sendable, Equatable {
    /// The file exceeds the per-file cap. `maxFileBytes` is the effective cap.
    case fileTooLarge(maxFileBytes: Int)
    /// The upload would exceed the quota. Carries the effective quota + current use.
    case quotaExceeded(quotaBytes: Int, usedBytes: Int)
    /// The type is unsupported / unidentifiable (server 415).
    case unsupportedType
    /// Too many uploads (server 429).
    case rateLimited
    /// Any other transport / server failure (wraps the underlying description).
    case generic(String)
}
