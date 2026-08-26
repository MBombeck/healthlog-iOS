import Foundation

/// Wraps the passkey-management verbs the Settings → Security surface needs:
///
/// - `GET    /api/auth/passkeys`        — the registered-credential list.
/// - `DELETE /api/auth/passkeys/{id}`   — revoke a single credential.
///
/// Owning the paths here (not in the View) is the whole point: the
/// `PasskeyManagementScreen` previously constructed `APIRequest`s inline,
/// which is exactly the seam that let a past path-drift surface as a runtime
/// 404 / decode error rather than a failing contract test (see the
/// `PasskeyEntry` doc-comment for the historic `lastUsedAt`/`label` decode
/// break). The repo is the contract-testable boundary.
///
/// **Idempotency:** the contract (`PROJECT_GUIDE.md`: "Idempotency-Keys auf jedem
/// POST/PUT") is header-based and applies to bodied mutations — `HTTPMethod
/// .requiresIdempotency` deliberately excludes DELETE, whose idempotency is the
/// resource path itself (re-deleting an already-deleted passkey is a no-op
/// server-side). `delete` therefore needs no wire-side key. A dedicated outbox
/// `Kind` for passkey-revoke is intentionally not wired (low write-rate,
/// security-sensitive — a stale offline revoke replay needs its own design);
/// today a failed revoke surfaces as an error, matching the prior in-View
/// behaviour exactly.
public actor PasskeyRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// Fetches the registered passkeys. Read-only, no cache — the list is
    /// small and only viewed when the user opens the management screen.
    public func list() async throws -> [PasskeyEntry] {
        let req: APIRequest<[PasskeyEntry]> = .get("/api/auth/passkeys")
        return try await api.send(req)
    }

    /// Revokes a single passkey. DELETE is idempotent on the path; no wire-side
    /// key is attached (see type doc).
    public func delete(id: String) async throws {
        let req: APIRequest<EmptyPayload> = .delete("/api/auth/passkeys/\(id)")
        try await api.sendVoid(req)
    }

    /// Renames a passkey via `PATCH /api/auth/passkeys/{id}`.
    ///
    /// Closes the gap that made every iOS-enrolled credential permanently read
    /// `"HealthLog"` — the display name was hardcoded at the enrolment call and
    /// there was no way to change it afterwards.
    ///
    /// Unlike the MFA security-key routes, this one is gated on `requireAuth()`
    /// (`src/app/api/auth/passkeys/[id]/route.ts:22`), which accepts cookie **or**
    /// Bearer — so it is genuinely reachable from the app.
    ///
    /// The name is normalised (trim + 64-char clamp) to the server's
    /// `webauthnKeyNameSchema` before it goes on the wire, so an over-long or
    /// whitespace-padded entry is corrected here rather than bounced as a 422.
    public func rename(id: String, name: String) async throws {
        let body = PasskeyRenameBody(name: WebAuthnKeyName.normalized(name))
        let req: APIRequest<EmptyPayload> = try .patch("/api/auth/passkeys/\(id)", body: body)
        try await api.sendVoid(req)
    }
}
