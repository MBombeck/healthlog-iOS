import Foundation

// Clinician share-link DTOs (server v1.12.1 — `src/app/api/share-links/route.ts`,
// `src/lib/validations/clinician-share-link.ts`). A share-link is a scoped,
// time-limited, revocable link the user mints to hand a doctor: the doctor opens
// the rendered health-record view at `/c/<token>` on the web.
//
// **Security contract (server B1 confirmation):**
// - The raw token (`hls_<48 hex>`, *not* `hlk_`) is returned **only once** in the
//   create response (`ShareLinkDTO.token`). The server stores only its HMAC hash,
//   so it is **unrecoverable** afterwards — `GET` never returns it. The create UI
//   must present it for copy/share immediately and make clear it cannot be shown
//   again.
// - `createShareLinkSchema` is `.strict()` → any unknown key (incl. a smuggled
//   `userId`) is a 422. ``CreateShareLinkBody`` encodes **exactly** the allowed
//   fields and nothing else.
//
// **CU-12 / server v1.32.39.** The create schema turned `.strict()` in the
// literal sense: `allowFhirApi` and `resourceTypes` are no longer *accepted* in
// the request — sending either is a `422`. They stay on the **response** as
// constants (`false` / `[]`) purely so this decoder does not break, and the
// server removes them once we confirm. ``ShareLinkDTO`` therefore keeps
// decoding them optional-tolerantly while ``CreateShareLinkBody`` no longer
// emits them at all. In their place the request carries the shared
// ``ReportSelection`` (`{ v: 2, leaves: [...] }`) — the same object the
// health-record export speaks.
// - Revoke (`DELETE /{id}`) is *safe to repeat* but not 200-idempotent: a second
//   revoke returns **404** ("already revoked / gone"). The repository maps that
//   404 to success-equivalent.

// MARK: - ShareLinkDTO (server row projection)

/// One share-link row. The `token` field is present **only** on the create
/// response; `GET` list rows never carry it (decoded as `nil`).
public struct ShareLinkDTO: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let label: String
    public let rangeStart: String
    public let rangeEnd: String?
    public let resourceTypes: [String]
    public let allowFhirApi: Bool
    public let expiresAt: String
    public let createdAt: String
    public let revokedAt: String?
    public let lastAccessAt: String?
    public let accessCount: Int
    public let active: Bool
    /// Passphrase-2FA flag (server v1.18.7). Present on both list rows and the
    /// create response; legacy rows minted before the feature decode as `false`.
    public let protected: Bool
    /// Raw `hls_…` token — present **only** on the create response, `nil` on list
    /// rows. Never logged, never persisted (server-first; the link list is the
    /// authoritative state).
    public let token: String?
    /// Auto-minted passphrase (`XXXX-XXXX-XXXX-XXXX`). Returned **only once** on the
    /// create response (`nil` on list rows) — the owner hands it to the clinician
    /// out-of-band. Never logged, never persisted.
    public let passphrase: String?
    /// Absolute share URL (`<base>/c/<token>`). Create-response only; `nil` on list.
    public let shareUrl: String?
    /// Absolute QR payload — the share URL with the passphrase in the `#k=` fragment.
    /// Create-response only; `nil` on list. This is what the QR image encodes.
    public let qrUrl: String?
    /// **Server v1.32.39 / migration 0275.** `true` when the server retired this
    /// link during the selection-model migration: every link minted before the
    /// v2 selection existed was revoked wholesale, because there was no honest
    /// way to translate its old scope into the new leaf grammar.
    ///
    /// Until CU-12 this key was not decoded at all, so a dead link rendered
    /// exactly like a live one. There is **no reissue route** — the recovery is
    /// a fresh `POST /api/share-links`, which mints a new token *and* a new
    /// passphrase. The UI must say that plainly rather than call it a renewal.
    /// Absent (older server) → `false`.
    public let needsReselection: Bool
    /// **Server v1.32.39.** The link serves documents only — no health-data
    /// leaves. Delivered at runtime (`route.ts:129`) but missing from the
    /// `ShareLinkCreated` / `ShareLinkList` OpenAPI schemas, both of which are
    /// `additionalProperties: false`; a strictly generated decoder would reject
    /// the real response. Reported to the server team; decoded tolerantly here.
    /// Absent → `false`.
    public let documentOnly: Bool

    public init(
        id: String,
        label: String,
        rangeStart: String,
        rangeEnd: String?,
        resourceTypes: [String],
        allowFhirApi: Bool,
        expiresAt: String,
        createdAt: String,
        revokedAt: String?,
        lastAccessAt: String?,
        accessCount: Int,
        active: Bool,
        protected: Bool = false,
        token: String?,
        passphrase: String? = nil,
        shareUrl: String? = nil,
        qrUrl: String? = nil,
        needsReselection: Bool = false,
        documentOnly: Bool = false
    ) {
        self.id = id
        self.label = label
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.resourceTypes = resourceTypes
        self.allowFhirApi = allowFhirApi
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.revokedAt = revokedAt
        self.lastAccessAt = lastAccessAt
        self.accessCount = accessCount
        self.active = active
        self.protected = protected
        self.token = token
        self.passphrase = passphrase
        self.shareUrl = shareUrl
        self.qrUrl = qrUrl
        self.needsReselection = needsReselection
        self.documentOnly = documentOnly
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, rangeStart, rangeEnd, resourceTypes, allowFhirApi
        case expiresAt, createdAt, revokedAt, lastAccessAt, accessCount, active
        case protected, token, passphrase, shareUrl, qrUrl
        case needsReselection, documentOnly
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        rangeStart = try c.decode(String.self, forKey: .rangeStart)
        rangeEnd = try c.decodeIfPresent(String.self, forKey: .rangeEnd)
        resourceTypes = try c.decodeIfPresent([String].self, forKey: .resourceTypes) ?? []
        allowFhirApi = try c.decodeIfPresent(Bool.self, forKey: .allowFhirApi) ?? false
        expiresAt = try c.decode(String.self, forKey: .expiresAt)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        revokedAt = try c.decodeIfPresent(String.self, forKey: .revokedAt)
        lastAccessAt = try c.decodeIfPresent(String.self, forKey: .lastAccessAt)
        accessCount = try c.decodeIfPresent(Int.self, forKey: .accessCount) ?? 0
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? true
        protected = try c.decodeIfPresent(Bool.self, forKey: .protected) ?? false
        token = try c.decodeIfPresent(String.self, forKey: .token)
        passphrase = try c.decodeIfPresent(String.self, forKey: .passphrase)
        shareUrl = try c.decodeIfPresent(String.self, forKey: .shareUrl)
        qrUrl = try c.decodeIfPresent(String.self, forKey: .qrUrl)
        needsReselection = try c.decodeIfPresent(Bool.self, forKey: .needsReselection) ?? false
        documentOnly = try c.decodeIfPresent(Bool.self, forKey: .documentOnly) ?? false
    }
}

// MARK: - List response

/// `GET /api/share-links` → `data.shareLinks[]` (each row token-less).
public struct ShareLinkListResponse: Decodable, Sendable {
    public let shareLinks: [ShareLinkDTO]

    public init(shareLinks: [ShareLinkDTO]) {
        self.shareLinks = shareLinks
    }
}

// MARK: - Share-link selection policy

/// The one place where the share-link route's selection rules differ from the
/// export route's.
///
/// The leaf **vocabulary** is never authored here — it is read live from
/// `GET /api/meta/capabilities` → `share.leaves` (``ServerCapabilities/Share``).
/// What *is* authored here is the single documented subtraction: the share-link
/// route refuses `INSURANCE` even though the catalogue lists it, answering `422
/// share-link.selection.forbidden_leaf`. Insurance identifiers are the one leaf
/// a link handed to a third party must never carry, so the server refuses it
/// rather than trusting the caller.
///
/// We honour that by never *offering* the leaf, and still handle the `422` (see
/// ``ShareLinkError/forbiddenLeaf``) in case a selection reaches the request by
/// another route — a restored draft, a future server that forbids more.
public enum ShareLinkSelectionPolicy {
    /// Leaf ids `POST /api/share-links` rejects. Server-documented, not guessed.
    public static let forbiddenLeaves: Set<String> = ["INSURANCE"]

    /// The live vocabulary minus what this route forbids, order preserved —
    /// what a share-link selection UI may show.
    public static func offeredLeaves(from vocabulary: [String]) -> [String] {
        vocabulary.filter { !forbiddenLeaves.contains($0) }
    }

    /// Forbidden ids present in a selection, in selection order. Empty is the
    /// happy path; non-empty means the request would 422.
    public static func forbiddenLeaves(in selection: ReportSelection) -> [String] {
        selection.leaves.filter { forbiddenLeaves.contains($0) }
    }
}

// MARK: - Create request body (`.strict()` — exact fields only)

/// Encodes **exactly** the keys `createShareLinkSchema` accepts. No `userId`
/// (server narrows it from auth; `.strict()` would 422 it), and since v1.32.39
/// no `resourceTypes` / `allowFhirApi` either — both are refused on the request
/// and only survive on the response as constants.
public struct CreateShareLinkBody: Encodable, Sendable {
    /// 1–120 chars (trimmed).
    public let label: String
    /// ISO-8601 with offset.
    public let rangeStart: String
    /// ISO with offset; `nil` = rolling window. Must be `>= rangeStart` when set.
    public let rangeEnd: String?
    /// REQUIRED, ISO with offset, in the future AND ≤ 90 days ahead.
    public let expiresAt: String
    /// What the link exposes — the shared v2 selection (``ReportSelection``),
    /// identical in shape to the one `POST /api/export/health-record` takes.
    /// Membership is inclusion: an empty `leaves` is legal and means the link
    /// carries no health data at all.
    public let selection: ReportSelection

    public init(
        label: String,
        rangeStart: String,
        rangeEnd: String?,
        expiresAt: String,
        selection: ReportSelection
    ) {
        self.label = label
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.expiresAt = expiresAt
        self.selection = selection
    }

    private enum CodingKeys: String, CodingKey {
        case label, rangeStart, rangeEnd, expiresAt, selection
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // `label`, `rangeStart`, `expiresAt`, `selection` are required by the
        // schema → always present. `rangeEnd` is encoded as explicit `null` when
        // the user picked a rolling window (null = rolling, distinct from
        // absent). Nothing else is ever emitted: `.strict()` turns a stray key
        // into a 422, and `resourceTypes` / `allowFhirApi` are exactly that now.
        try c.encode(label, forKey: .label)
        try c.encode(rangeStart, forKey: .rangeStart)
        try c.encode(rangeEnd, forKey: .rangeEnd) // encodes `null` when nil → rolling
        try c.encode(expiresAt, forKey: .expiresAt)
        try c.encode(selection, forKey: .selection)
    }
}
