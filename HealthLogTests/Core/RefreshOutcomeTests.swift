import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Locks the 401-cascade classification. `RefreshOutcome.classify`
/// is the seam that decides whether a failed `POST /api/auth/refresh` tears
/// down the session (`authFailure`) or leaves it intact (`transient`).
///
/// Contract:
///   - A `401` on the refresh route, or a `4xx` carrying one of the stable
///     errorCodes `auth.refresh.{revoked,reuse,invalid}` → `authFailure` →
///     logout.
///   - `HLError.unauthorized` → `authFailure`.
///   - Everything else (offline / network / timeout / 5xx / rate-limit /
///     decode, and any other `4xx`, which is a proxy or a malformed request
///     and no verdict on the token) → `transient` → NO logout.
@Suite("RefreshOutcome.classify (401-cascade gating)")
struct RefreshOutcomeTests {
    @Test("Unauthorized → authFailure")
    func unauthorized() {
        #expect(RefreshOutcome.classify(HLError.unauthorized) == .authFailure)
        #expect(RefreshOutcome.classify(HLError.unauthorized).shouldLogout)
    }

    @Test(
        "A refresh verdict named by the server → authFailure",
        arguments: [
            HLError.server(status: 401, code: "auth.refresh.revoked", message: "revoked"),
            HLError.server(status: 401, code: "auth.refresh.reuse", message: "reuse detected"),
            HLError.server(status: 401, code: "auth.refresh.invalid", message: "invalid"),
            HLError.server(status: 401, code: nil, message: "unauthorized"),
            HLError.server(status: 403, code: "auth.refresh.revoked", message: "revoked"),
        ]
    )
    func namedVerdict(_ error: HLError) {
        #expect(RefreshOutcome.classify(error) == .authFailure)
    }

    @Test(
        "Any other 4xx is no verdict on the token → transient (NO logout)",
        arguments: [
            HLError.server(status: 400, code: nil, message: "bad request"),
            HLError.server(status: 403, code: nil, message: "forbidden"),
            HLError.server(status: 403, code: "auth.forbidden", message: "forbidden"),
            HLError.server(status: 404, code: nil, message: "not found"),
            HLError.server(status: 413, code: nil, message: "too large"),
            HLError.server(status: 422, code: "validation.failed", message: "invalid body"),
        ]
    )
    func otherClientErrors(_ error: HLError) {
        #expect(RefreshOutcome.classify(error) == .transient)
        #expect(!RefreshOutcome.classify(error).shouldLogout)
    }

    @Test(
        "Transient failures → transient (NO logout)",
        arguments: [
            HLError.offline,
            HLError.network(.timeout),
            HLError.network(.connectionLost),
            HLError.network(.dnsFailure),
            HLError.network(.other("boom")),
            HLError.server(status: 500, code: nil, message: "server error"),
            HLError.server(status: 503, code: nil, message: "unavailable"),
            HLError.rateLimited(retryAfter: 30),
            HLError.decoding("garbage"),
            HLError.canceled,
        ]
    )
    func transient(_ error: HLError) {
        #expect(RefreshOutcome.classify(error) == .transient)
        #expect(!RefreshOutcome.classify(error).shouldLogout)
    }

    @Test("Non-HLError errors default to transient (never a spurious logout)")
    func nonHLErrorTransient() {
        struct Boom: Error {}
        #expect(RefreshOutcome.classify(Boom()) == .transient)
    }

    @Test("didRefresh / shouldLogout convenience flags")
    func convenienceFlags() {
        #expect(RefreshOutcome.refreshed.didRefresh)
        #expect(!RefreshOutcome.refreshed.shouldLogout)
        #expect(!RefreshOutcome.transient.didRefresh)
        #expect(!RefreshOutcome.transient.shouldLogout)
        #expect(!RefreshOutcome.authFailure.didRefresh)
        #expect(RefreshOutcome.authFailure.shouldLogout)
    }
}
