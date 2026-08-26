import Foundation

/// v0.14.10 — server-side AI **consent receipts** (server SB-10 routes,
/// `POST /api/consent/ai` + `GET/DELETE /api/consent/ai/latest`).
///
/// **Why this exists (RCA W-INSIGHTSDATA Bug 2).** Server v1.12.1 enforcement
/// (server commit `37e9f32f`, live since ~2026-06-05) requires an ACTIVE
/// `ConsentReceipt` (`ai_insights_only` or the master `ai_full`) before any
/// LLM egress on a server-managed provider chain — and the default chain ends
/// in the operator's global key (`admin-openai`), so practically every account
/// trips the gate. The receipt infrastructure was built for the iOS client to
/// mint ("the three consent surfaces the iOS client collects"), but no client
/// ever called `POST /api/consent/ai`. Result: `runStatusCompletion` fails
/// closed to the no-key fallback for the whole per-metric status family — the
/// Insights metric sub-pages lost their "Einschätzung" prose (the overview
/// Tagesbriefing survived only because it falls back to the deterministic
/// period narrative).
///
/// This repo is the thin wire wrapper; `AppContainer.syncServerAIConsentReceipt`
/// drives WHEN a receipt is minted (on grant + once per launch while granted,
/// healing existing granted installs) and revoked (explicit master-off).
public actor ConsentReceiptRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// The receipt kind iOS mints. The in-app `AIConsentSheet` is the single
    /// master opt-in covering BOTH server-AI surfaces (per-metric/overview
    /// assessments AND the ✦ Coach), so the superset `ai_full` grant — which
    /// satisfies either surface in the server's consent guard — is the honest
    /// mapping. The narrower `ai_insights_only` / `ai_coach` kinds stay
    /// unminted until iOS ever offers split consents.
    public static let fullConsentKind = "ai_full"

    /// True when an active (non-revoked) receipt satisfying BOTH AI surfaces
    /// is on file — i.e. the master `ai_full` receipt exists.
    public func hasActiveFullConsentReceipt() async throws -> Bool {
        let req: APIRequest<ConsentReceiptsByKindDTO> = .get("/api/consent/ai/latest")
        let receipts = try await api.send(req)
        guard let full = receipts.aiFull else { return false }
        return full.revokedAt == nil
    }

    /// Mints a fresh `ai_full` receipt documenting the in-app informed-consent
    /// acceptance. `artefact` is opaque to the server (audit-trail storage);
    /// we send a small JSON record of the consent act.
    public func mintFullConsentReceipt(artefact: String, signedAt: Date = .now) async throws {
        let body = ConsentReceiptPostBody(
            kind: Self.fullConsentKind,
            artefact: artefact,
            signedAt: Self.isoTimestamp(signedAt)
        )
        let req: APIRequest<ConsentReceiptMintedDTO> = try .post("/api/consent/ai", body: body)
        _ = try await api.send(req)
    }

    /// Idempotent ensure: GET the latest receipts; mint the master receipt only
    /// when none is active. Returns `true` when an active receipt exists after
    /// the call (pre-existing or freshly minted). Best-effort — any transport
    /// failure is logged and reported as `false`; callers never surface it
    /// (the next launch retries).
    @discardableResult
    public func ensureFullConsentReceipt(artefact: String) async -> Bool {
        do {
            if try await hasActiveFullConsentReceipt() { return true }
            try await mintFullConsentReceipt(artefact: artefact)
            HLLog.api.info("AI consent receipt minted server-side (ai_full)")
            return true
        } catch {
            let detail = LogSanitizer.redact(String(describing: error))
            HLLog.api.warning("AI consent receipt sync failed: \(detail)")
            return false
        }
    }

    /// Master revoke — `DELETE /api/consent/ai/latest` (no `kind` query)
    /// revokes the latest active receipt across EVERY consent kind. Wired to
    /// the explicit in-app master-off (Task #49 toggle / switching the AI
    /// source away from External AI), NOT to the logout cascade: the logout
    /// consent wipe is device hygiene, while the receipt is the account-level
    /// consent record that must only fall on an explicit user revocation.
    /// Best-effort — a transport failure is logged; the local gates are
    /// already closed, and the next explicit disable retries.
    public func revokeAll() async {
        do {
            let req: APIRequest<EmptyResponse> = .delete("/api/consent/ai/latest")
            _ = try await api.send(req)
            HLLog.api.info("AI consent receipts revoked server-side")
        } catch {
            let detail = LogSanitizer.redact(String(describing: error))
            HLLog.api.warning("AI consent receipt revoke failed: \(detail)")
        }
    }

    /// ISO-8601 with timezone designator — the server's zod schema
    /// (`z.iso.datetime({ offset: true })`) requires an offset or `Z`.
    /// Built per call (`ISO8601DateFormatter` is not `Sendable`, and minting
    /// is rare — never on a hot path).
    private static func isoTimestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

// MARK: - Wire shapes (server v1.4.40 SB-10)

/// POST body for `/api/consent/ai` — `consentPostBody` zod schema:
/// `{ kind, artefact (non-empty, ≤64 KB UTF-8), signedAt (ISO-8601 + offset) }`.
struct ConsentReceiptPostBody: Encodable {
    let kind: String
    let artefact: String
    let signedAt: String
}

/// One serialised receipt row (`serialiseReceipt` server-side). `artefact` is
/// deliberately stripped by the server (audit-only).
public struct ConsentReceiptDTO: Decodable, Sendable {
    public let id: String
    public let kind: String
    public let signedAt: Date
    public let revokedAt: Date?
}

/// `GET /api/consent/ai/latest` (no kind) — the latest non-revoked receipt per
/// kind, full keyspace, `null` when not granted.
public struct ConsentReceiptsByKindDTO: Decodable, Sendable {
    public let aiFull: ConsentReceiptDTO?
    public let aiInsightsOnly: ConsentReceiptDTO?
    public let aiCoach: ConsentReceiptDTO?

    private enum CodingKeys: String, CodingKey {
        case aiFull = "ai_full"
        case aiInsightsOnly = "ai_insights_only"
        case aiCoach = "ai_coach"
    }
}

/// `POST /api/consent/ai` success payload — `{ id, receipt }`.
struct ConsentReceiptMintedDTO: Decodable {
    let id: String
    let receipt: ConsentReceiptDTO
}
