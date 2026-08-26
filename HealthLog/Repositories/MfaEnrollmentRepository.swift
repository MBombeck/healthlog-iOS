import Foundation

/// Thin projection of `GET /api/auth/me` — only the forced-MFA-enrolment
/// signal. Decoupled from `UserProfile` so an unrelated `/me` schema change
/// cannot break the gate, mirroring `AuthMeDisclaimer` / `AuthMeModules`.
///
/// **This field does not exist on the server yet.** `/api/auth/me` recomputes
/// the requirement on every call (`syncMfaEnrollCookie`,
/// `src/app/api/auth/me/route.ts:33-38`) but publishes the result **only as a
/// cookie**, never in the JSON body. The key is declared here as
/// `decodeIfPresent` so that the day the server adds it, iOS starts honouring
/// the authoritative value with no client change. Until then it decodes `nil`
/// and `MfaEnrollmentRepository` falls back to the cookie — see there.
public struct AuthMeMfaEnrollment: Decodable, Sendable, Equatable {
    /// Server-authoritative "this account must enrol a second factor before
    /// using the app". `nil` when the server does not publish the field (every
    /// version to date).
    public let mfaEnrollmentRequired: Bool?

    public init(mfaEnrollmentRequired: Bool?) {
        self.mfaEnrollmentRequired = mfaEnrollmentRequired
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mfaEnrollmentRequired = try c.decodeIfPresent(Bool.self, forKey: .mfaEnrollmentRequired)
    }

    private enum CodingKeys: String, CodingKey {
        case mfaEnrollmentRequired
    }
}

/// Resolves whether the signed-in account must enrol a second factor before the
/// app is usable (parity item 2.3, web ref `src/app/enroll-mfa/page.tsx:22-64`).
///
/// **Why this reads a cookie.** The operator-enforced-MFA gate is published by
/// the server as a non-httpOnly UX-hint cookie (`hl_mfa_enroll=required`,
/// `src/lib/auth/mfa-enrollment.ts`), which the web proxy reads to redirect into
/// `/enroll-mfa`. There is no JSON equivalent: `/api/auth/me` recomputes the
/// requirement and syncs the cookie, but never returns it in the body. A native
/// client therefore has exactly one signal available today.
///
/// That signal does reach iOS: `APIClient` builds its sessions from
/// `URLSessionConfiguration.default`, which uses the shared `HTTPCookieStorage`
/// with `httpShouldSetCookies` on, so the `Set-Cookie` the route emits on a
/// Bearer request is stored like any other and readable here.
///
/// **Known limits, deliberately accepted:**
/// - The cookie carries `Secure`, so it is dropped on a plain-HTTP self-hosted
///   instance. Such an instance simply never gates — fail-open.
/// - It is a UX hint, not a wall. That is true on web too; the server enforces
///   the real policy on the enrolment surfaces themselves.
/// - It is cleared server-side the moment a factor is confirmed
///   (`setMfaEnrollCookie(false)` in `mfa/verify`), so the gate lifts on the
///   next `/me`.
///
/// **Fail-open by construction.** Every unresolved case — no cookie, network
/// error, missing field — yields "not required". A gate that guesses "required"
/// would lock a user out of a perfectly healthy account; the failure mode of
/// guessing "not required" is merely that an enforcing instance nags one boot
/// later. The right long-term fix is a server field; see the parity report.
public actor MfaEnrollmentRepository {
    /// Name of the server's UX-hint cookie.
    public static let enrollCookieName = "hl_mfa_enroll"
    /// The only value that means "enrolment pending".
    public static let enrollCookiePendingValue = "required"

    private let api: APIClientProtocol
    /// `nil`, solange kein Server eingerichtet ist — dann gibt es auch
    /// keinen Cookie-Jar-Scope, in dem der UX-Hinweis stehen koennte.
    private let baseURL: URL?
    private let cookieStorage: HTTPCookieStorage

    public init(
        api: APIClientProtocol,
        baseURL: URL?,
        cookieStorage: HTTPCookieStorage = .shared
    ) {
        self.api = api
        self.baseURL = baseURL
        self.cookieStorage = cookieStorage
    }

    /// Resolve the requirement. Performs the `/me` round-trip first (which is
    /// also what makes the server refresh the cookie), then reads whichever
    /// signal is available.
    ///
    /// Precedence is explicit: an authoritative JSON field always wins over the
    /// cookie heuristic, so the cookie path becomes dead weight — not a
    /// competing source of truth — the moment the server publishes the field.
    public func fetchEnrollmentRequired() async throws -> Bool {
        let req: APIRequest<AuthMeMfaEnrollment> = .get("/api/auth/me")
        let response = try await api.send(req)
        if let authoritative = response.mfaEnrollmentRequired {
            return authoritative
        }
        return readEnrollCookie()
    }

    /// Reads the UX-hint cookie for the configured host. `nonisolated` on the
    /// pure predicate below keeps the decision testable without a live actor.
    private func readEnrollCookie() -> Bool {
        guard let baseURL else { return false }
        let cookies = cookieStorage.cookies(for: baseURL) ?? []
        return Self.isEnrollmentPending(cookies: cookies)
    }

    /// Pure decision over a cookie jar — extracted so the gate's contract is
    /// unit-testable without `HTTPCookieStorage.shared` global state.
    ///
    /// Requires an exact match on both name and value: any other value (a
    /// cleared cookie is emitted as an empty/expired one) means "not pending".
    public nonisolated static func isEnrollmentPending(cookies: [HTTPCookie]) -> Bool {
        cookies.contains { $0.name == enrollCookieName && $0.value == enrollCookiePendingValue }
    }
}
