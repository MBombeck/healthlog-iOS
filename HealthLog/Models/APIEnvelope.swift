import Foundation

/// Server-Envelope-Format gemäß `src/lib/api-response.ts`:
/// `{ data: T | null, error: string | null, errorCode?: string | null }`.
/// `error` ist im Server **fast** immer ein String (oder `null`) — frühere
/// iOS-Annahme, es sei ein Objekt, war falsch und hat Decoding sabotiert
/// (siehe Audit-Senior-Dev-2).
///
/// **CU-32 — die eine dokumentierte Ausnahme.** Der Idempotenz-Wrapper
/// (`src/lib/idempotency.ts`) bricht diesen Vertrag: sein 409 „a request with
/// this Idempotency-Key is already in progress" sendet
/// `error: { message: "…" }` als **Objekt**. Er liegt u. a. auf
/// `POST /api/anamnesis/facts`. Vor dieser Toleranz warf `init(from:)` dort,
/// alle `try?`-Dekodierversuche in `APIClient` fielen auf `nil`, und der Aufrufer
/// bekam statt einer Erklärung ein nacktes `HTTP 409` ohne `errorCode` — und
/// zwar genau dann, wenn zwei Requests mit demselben Idempotency-Key
/// kollidieren, also im **Outbox-Replay-Pfad**. ``decodeErrorText(from:)``
/// nimmt deshalb String **oder** `{ message }` und ist ansonsten
/// verhaltensgleich.
///
/// **`errorCode`:** the pre-v1.39 top-level machine code. Server v1.39 carries
/// every code in `meta.errorCode` (with `meta.capability`, `meta.reason`,
/// `meta.module`); `APIClient` reads `meta` first and falls back to this field
/// only for an older server. An AI refusal surfaces as
/// ``HLError/aiUnavailable(_:)`` (#114 / #115 · 0.2).
public struct APIEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    public let data: T?
    public let error: String?
    public let errorCode: String?
    /// #30 / v1.18.0 — the module-gate `403` envelope carries a `meta` object:
    /// `meta: { errorCode: "module.disabled", module: "<key>" }`. `APIClient`
    /// reads `meta.errorCode` + `meta.module` to surface the disabled module
    /// and mirror it into ``ModuleGate``. Optional + decode-tolerant: a server
    /// that omits `meta` (every response that isn't a module-gate rejection)
    /// yields `nil`.
    public let meta: APIEnvelopeMeta?

    public init(data: T?, error: String?, errorCode: String? = nil, meta: APIEnvelopeMeta? = nil) {
        self.data = data
        self.error = error
        self.errorCode = errorCode
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case data, error, errorCode, meta
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = try c.decodeIfPresent(T.self, forKey: .data)
        error = Self.decodeErrorText(from: c)
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode)
        meta = try c.decodeIfPresent(APIEnvelopeMeta.self, forKey: .meta)
    }

    /// Die Objekt-Form von `error`, wie sie ausschliesslich der
    /// Idempotenz-Wrapper sendet: `{ message: "…" }`.
    private struct ObjectError: Decodable {
        let message: String?
    }

    /// `error` als String lesen; ist es ausnahmsweise ein Objekt, dessen
    /// `message` nehmen. Nie werfen — ein unlesbares `error` darf den Envelope
    /// (und damit `data`, `errorCode` und `meta`) nicht mitreissen.
    private static func decodeErrorText(from c: KeyedDecodingContainer<CodingKeys>) -> String? {
        if let text = try? c.decodeIfPresent(String.self, forKey: .error) {
            return text
        }
        if let object = try? c.decodeIfPresent(ObjectError.self, forKey: .error) {
            return object.message
        }
        return nil
    }
}

/// `meta` block on a server envelope. Carries the module-gate
/// rejection shape (#30): `{ errorCode: "module.disabled", module: "<key>" }`
/// **and** the v1.23.0 two-factor login challenge shape (GH iOS #37):
/// `{ mfaRequired: true, mfaTicket: "<opaque>", methods: ["totp" | "recovery"
/// | "webauthn"] }`. Decode-tolerant — every field is optional so unrelated
/// `meta` shapes (and the `{ requestId }` shape on success envelopes) don't
/// fail the decode.
public struct APIEnvelopeMeta: Decodable, Sendable, Equatable {
    public let errorCode: String?
    public let module: String?
    /// #37 / v1.23.0 — `true` on a `POST /api/auth/login` 200 whose password
    /// was accepted but a second factor is still required. The paired
    /// ``mfaTicket`` + ``methods`` describe how to complete the challenge.
    public let mfaRequired: Bool?
    /// #37 — opaque, single-use, ~5-minute ticket to present to
    /// `/api/auth/mfa/verify` (or the webauthn-verify legs). **Sensitive** —
    /// must never be logged.
    public let mfaTicket: String?
    /// #37 — second factors the account can complete the challenge with
    /// (`"totp"`, `"recovery"`, `"webauthn"`). Decoded leniently; unknown
    /// strings are dropped by the caller.
    public let methods: [String]?
    /// v1.35.0 (GH #83) — the machine-readable *why* beside an `errorCode`,
    /// for refusals where "not acceptable" is not specific enough to put in
    /// front of a person (`health_score_config.too_narrow` names which breadth
    /// rule the selection missed). A raw string here on purpose: the transport
    /// carries the pair, the domain maps it to a sentence.
    public let reason: String?
    /// #114 / #115 · 0.2 — on an AI refusal (server v1.39): the capability that
    /// is unavailable, one of the `AiCapabilities` keys. Kept raw here; the
    /// transport maps it through ``AIRefusal``.
    public let capability: String?
    /// #110 — `PUT /api/auth/me/report-selection` names the leaf ids this
    /// server build does not know beside `report-selection.leaves.unknown`.
    public let unknownLeaves: [String]?
    /// #112 — a failed notification-channel test (`502`) says what the relay
    /// answered: its HTTP status, the SMTP reply code, and at most 200
    /// characters of the relay's own error text (never secret-shaped).
    public let upstreamStatus: Int?
    public let smtpCode: Int?
    public let upstreamBody: String?

    public init(
        errorCode: String? = nil,
        module: String? = nil,
        mfaRequired: Bool? = nil,
        mfaTicket: String? = nil,
        methods: [String]? = nil,
        reason: String? = nil,
        capability: String? = nil,
        unknownLeaves: [String]? = nil,
        upstreamStatus: Int? = nil,
        smtpCode: Int? = nil,
        upstreamBody: String? = nil
    ) {
        self.errorCode = errorCode
        self.module = module
        self.mfaRequired = mfaRequired
        self.mfaTicket = mfaTicket
        self.methods = methods
        self.reason = reason
        self.capability = capability
        self.unknownLeaves = unknownLeaves
        self.upstreamStatus = upstreamStatus
        self.smtpCode = smtpCode
        self.upstreamBody = upstreamBody
    }

    private enum CodingKeys: String, CodingKey {
        case errorCode, module, mfaRequired, mfaTicket, methods, reason, capability
        case unknownLeaves, upstreamStatus, smtpCode, upstreamBody
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode)
        module = try c.decodeIfPresent(String.self, forKey: .module)
        mfaRequired = try c.decodeIfPresent(Bool.self, forKey: .mfaRequired)
        mfaTicket = try c.decodeIfPresent(String.self, forKey: .mfaTicket)
        methods = try c.decodeIfPresent([String].self, forKey: .methods)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        capability = try? c.decodeIfPresent(String.self, forKey: .capability)
        // Detail fields decode tolerantly: a malformed one is simply absent,
        // it never costs the `errorCode` beside it.
        unknownLeaves = try? c.decodeIfPresent([String].self, forKey: .unknownLeaves)
        upstreamStatus = try? c.decodeIfPresent(Int.self, forKey: .upstreamStatus)
        smtpCode = try? c.decodeIfPresent(Int.self, forKey: .smtpCode)
        upstreamBody = try? c.decodeIfPresent(String.self, forKey: .upstreamBody)
    }
}

/// **Which refusals carry a machine-readable reason worth typing.**
///
/// `meta.reason` is not new — the document-inbox routes have carried one for
/// several releases, and their callers read the plain ``HLError/server(status:code:message:)``
/// they always got. Promoting *every* reasoned 4xx to
/// ``HLError/refusedWithReason(code:reason:)`` would change the shape of an
/// error under callers that never asked for it, so the promotion is opt-in per
/// code and this list is the opt-in.
public enum APIRefusal {
    /// Error codes whose `meta.reason` the client maps to its own sentence.
    public static let reasonedCodes: Set<String> = [
        HealthScoreConfigErrorCode.tooNarrow
    ]

    /// Throw ``HLError/refusedWithReason(code:reason:)`` when `meta` carries an
    /// opted-in code **and** a non-empty reason; return quietly otherwise so the
    /// caller's generic rejection path runs unchanged.
    static func throwIfReasoned(_ meta: APIEnvelopeMeta?) throws {
        guard let code = meta?.errorCode, reasonedCodes.contains(code),
              let reason = meta?.reason, !reason.isEmpty else { return }
        throw HLError.refusedWithReason(code: code, reason: reason)
    }
}

/// Empty body marker for envelopes without a payload.
public struct EmptyPayload: Codable, Sendable {
    public init() {}
}
