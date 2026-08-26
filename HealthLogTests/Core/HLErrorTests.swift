import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

@Suite("HLError")
struct HLErrorTests {
    @Test("Network errors are retriable")
    func retriable() {
        #expect(HLError.network(.timeout).isRetriable)
        #expect(HLError.offline.isRetriable)
        #expect(HLError.rateLimited(retryAfter: nil).isRetriable)
    }

    @Test("5xx server errors are retriable")
    func server5xx() {
        #expect(HLError.server(status: 500, code: nil, message: "x").isRetriable)
        #expect(HLError.server(status: 503, code: nil, message: "x").isRetriable)
    }

    @Test("4xx server errors are not retriable")
    func server4xx() {
        #expect(!HLError.server(status: 400, code: nil, message: "x").isRetriable)
        #expect(!HLError.server(status: 404, code: nil, message: "x").isRetriable)
    }

    @Test("Unauthorized is not retriable")
    func unauth() {
        #expect(!HLError.unauthorized.isRetriable)
    }

    @Test("#37/#38 — only a 401 with auth.stepup.required is isMfaStepUpRequired")
    func mfaStepUp() {
        #expect(HLError.server(status: 401, code: "auth.stepup.required", message: "x").isMfaStepUpRequired)
        // A step-up 401 is NOT retriable (a refresh cannot satisfy a cookie-only step-up).
        #expect(!HLError.server(status: 401, code: "auth.stepup.required", message: "x").isRetriable)
        // Wrong code / status / bare unauthorized must all be false.
        #expect(!HLError.server(status: 403, code: "auth.stepup.required", message: "x").isMfaStepUpRequired)
        #expect(!HLError.server(status: 401, code: "auth.session.expired", message: "x").isMfaStepUpRequired)
        #expect(!HLError.server(status: 401, code: nil, message: "x").isMfaStepUpRequired)
        #expect(!HLError.unauthorized.isMfaStepUpRequired)
    }
}
