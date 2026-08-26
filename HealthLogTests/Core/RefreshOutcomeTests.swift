import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Locks the 401-cascade classification (v0.10.0). `RefreshOutcome.classify`
/// is the seam that decides whether a failed `POST /api/auth/refresh` tears
/// down the session (`authFailure`) or leaves it intact (`transient`).
///
/// Contract:
///   - Server 4xx on the refresh route (incl. the v1.7.0 stable errorCodes
///     `auth.refresh.{revoked,reuse,invalid}` which arrive as 401/403) →
///     `authFailure` → logout.
///   - `HLError.unauthorized` → `authFailure`.
///   - Everything else (offline / network / timeout / 5xx / rate-limit /
///     decode) → `transient` → NO logout.
@Suite("RefreshOutcome.classify (401-cascade gating)")
struct RefreshOutcomeTests {
    @Test("Unauthorized → authFailure")
    func unauthorized() {
        #expect(RefreshOutcome.classify(HLError.unauthorized) == .authFailure)
        #expect(RefreshOutcome.classify(HLError.unauthorized).shouldLogout)
    }

    @Test(
        "Server 4xx (incl. auth.refresh.* errorCodes) → authFailure",
        arguments: [
            HLError.server(status: 401, code: "auth.refresh.revoked", message: "revoked"),
            HLError.server(status: 401, code: "auth.refresh.reuse", message: "reuse detected"),
            HLError.server(status: 401, code: "auth.refresh.invalid", message: "invalid"),
            HLError.server(status: 403, code: nil, message: "forbidden"),
            HLError.server(status: 400, code: nil, message: "bad request"),
        ]
    )
    func server4xx(_ error: HLError) {
        #expect(RefreshOutcome.classify(error) == .authFailure)
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
