import Foundation

/// Wraps the active-session management verbs behind Settings → Account →
/// "Active sessions" (parity item 2.2, web ref
/// `components/settings/security-sessions-card.tsx:139-189`):
///
/// - `GET    /api/auth/me/sessions`       — list the user's active sessions.
/// - `DELETE /api/auth/me/sessions/{id}`  — revoke one.
/// - `DELETE /api/auth/me/sessions`       — revoke every *other* session.
///
/// **Why `/sessions` and not `/api/auth/me/devices`.** The devices route's own
/// docstring claims it exists to drive "the settings → security → devices
/// surface in the v1.5 iOS app", which made it the obvious candidate. It is the
/// wrong one, for two reasons that outrank the docstring:
///
/// 1. **It has no revoke verb.** `devices/route.ts` exports `GET` only. The
///    entire point of this surface is cutting off a device you no longer hold;
///    a read-only inventory cannot do that.
/// 2. **It lists a different population.** `devices` enumerates `prisma.device`
///    rows — APNs / Web-Push *notification registrations*. The newer sessions
///    route (v1.23) says so explicitly in its own header comment ("Distinct
///    from `/api/auth/me/devices`, which lists APNs / Web-Push notification
///    devices"). A device with notifications declined never appears there, so
///    it is not a credential inventory at all.
///
/// The devices docstring predates the sessions route and was simply never
/// updated; `sessions` is the surface the web card uses and the only one with
/// revocation. See `SessionEntry`'s type doc for what the list does and does
/// not contain on a native client.
///
/// **Idempotency:** DELETE carries no wire-side key — `HTTPMethod
/// .requiresIdempotency` excludes it, the resource path is the idempotency
/// anchor (re-revoking a gone session is a server-side no-op). Same contract as
/// `PasskeyRepository.delete`. No outbox `Kind` is wired: replaying a stale
/// offline session-revoke is a security decision that needs its own design, and
/// a failed revoke must surface as an error rather than silently queue.
public actor SessionsRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// Lists the active sessions. Read-only, uncached — the list is small, is
    /// only viewed when the user opens the screen, and staleness here is a
    /// security problem rather than a perf win.
    public func list() async throws -> [SessionEntry] {
        let req: APIRequest<SessionListResponse> = .get("/api/auth/me/sessions")
        return try await api.send(req).sessions
    }

    /// Revokes a single session. The server scopes the delete on both id AND
    /// userId and answers 404 for a foreign/unknown id, so this can never reach
    /// another user's row.
    public func revoke(id: String) async throws {
        let req: APIRequest<EmptyPayload> = .delete("/api/auth/me/sessions/\(id)")
        try await api.sendVoid(req)
    }

    /// v1.38.11 — "Sign out everywhere else", and from that server build it
    /// finally is `-else` for an iOS caller too.
    ///
    /// **Below v1.38.11 this is not `-else` when the caller is iOS.** The old
    /// server implementation (`destroyOtherSessions`,
    /// `src/lib/auth/session.ts:291-309`) deletes every `Session` row except
    /// `currentSessionId` — but then revokes **every** unrevoked `RefreshToken`
    /// for the user unconditionally, with no caller-exclusion. For a browser
    /// caller that is the intended semantic (keep this tab, drop all native
    /// apps). For an iOS caller it also revokes *this phone's* refresh token:
    /// the current access token keeps working until it expires, and the next
    /// refresh then fails and signs the user out locally.
    ///
    /// **From v1.38.11 the route spares the calling device.** For a Bearer
    /// caller it now excludes the caller's own credential and revokes the OTHER
    /// devices' refresh tokens *and* their paired access tokens in one
    /// transaction — so the lost phone loses its access token immediately
    /// instead of at expiry, and this phone stays signed in. Self-hosted
    /// instances below 1.38.11 keep the old behaviour, so the difference is not
    /// something the client may assume away.
    ///
    /// The wire call is identical on both sides of that line; only what the UI
    /// may promise changes. ``SignOutEverywhereElse`` is the version gate,
    /// `SessionsStore.sparesThisDevice` carries the verdict, and `SessionsScreen`
    /// picks between the `sessions.signOutAll.*` (old) and
    /// `sessions.signOutAll.else.*` (spared) copy with it. An unreadable server
    /// version keeps the older, harsher wording.
    ///
    /// We surface the action on every server — it is the only lever that cuts
    /// off a lost phone, since a native session is a `RefreshToken` and never
    /// appears in the `Session` list.
    ///
    /// - Returns: the number of **`Session` rows** deleted. Revoked refresh
    ///   tokens are not counted, so this is not a device count.
    @discardableResult
    public func revokeOthers() async throws -> Int {
        let req: APIRequest<SessionRevokeOthersResponse> = .delete("/api/auth/me/sessions")
        return try await api.send(req).sessionsRevoked
    }
}
