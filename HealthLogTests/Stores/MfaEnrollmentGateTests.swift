// Parity 2.3 — the forced second-factor enrolment gate.
//
// Two contracts are pinned here, both fail-safety properties rather than
// features:
//
//  1. `shouldGate` must stay DOWN until the requirement actually resolved. A
//     gate that raises on an unresolved read would lock a user out of a healthy
//     account on a network blip — strictly worse than the bug it fixes.
//  2. The cookie predicate must require an exact `required` value. The server
//     clears the hint by emitting an empty/expired cookie, so a lenient
//     "cookie present ⇒ gate" reading would leave the user permanently gated
//     after they enrolled — a trap with no exit but sign-out.

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @Suite("Forced-MFA enrolment gate (parity 2.3)")
    struct MfaEnrollmentGateTests {
        private func cookie(name: String, value: String) throws -> HTTPCookie {
            try #require(HTTPCookie(properties: [
                .name: name,
                .value: value,
                .domain: "test.healthlog.local",
                .path: "/"
            ]))
        }

        // MARK: - shouldGate

        @Test("Resolved and required raises the gate")
        func gatesWhenResolvedAndRequired() {
            #expect(MfaEnrollmentGateStore.shouldGate(hasLoaded: true, isRequired: true))
        }

        @Test("Resolved and not required leaves the shell mounted")
        func noGateWhenNotRequired() {
            #expect(!MfaEnrollmentGateStore.shouldGate(hasLoaded: true, isRequired: false))
        }

        @Test("An unresolved read never gates, so a network blip cannot lock the user out")
        func neverGatesBeforeResolve() {
            // Load-bearing: `isRequired` is meaningless until `hasLoaded`, and a
            // transient error deliberately leaves `hasLoaded` false.
            #expect(!MfaEnrollmentGateStore.shouldGate(hasLoaded: false, isRequired: true))
            #expect(!MfaEnrollmentGateStore.shouldGate(hasLoaded: false, isRequired: false))
        }

        // MARK: - Cookie predicate

        @Test("The server's pending hint cookie is recognised")
        func detectsPendingCookie() throws {
            let jar = try [cookie(name: "hl_mfa_enroll", value: "required")]
            #expect(MfaEnrollmentRepository.isEnrollmentPending(cookies: jar))
        }

        @Test("An empty cookie jar reads as not-required")
        func emptyJarIsNotPending() {
            #expect(!MfaEnrollmentRepository.isEnrollmentPending(cookies: []))
        }

        @Test("A cleared hint cookie must not keep gating the user after they enrolled")
        func clearedCookieIsNotPending() throws {
            // The server clears the hint by emitting the cookie with an empty
            // value. Reading "name present" as pending would trap the user.
            let jar = try [cookie(name: "hl_mfa_enroll", value: "")]
            #expect(!MfaEnrollmentRepository.isEnrollmentPending(cookies: jar))
        }

        @Test("An unrelated cookie never raises the gate")
        func unrelatedCookieIsNotPending() throws {
            let jar = try [cookie(name: "hl_session", value: "required")]
            #expect(!MfaEnrollmentRepository.isEnrollmentPending(cookies: jar))
        }

        // MARK: - /me projection

        @Test("A server that omits the field decodes to nil so the cookie fallback governs")
        func absentFieldDecodesNil() throws {
            let decoded = try JSONDecoder.hlDefault.decode(
                AuthMeMfaEnrollment.self, from: Data("{}".utf8)
            )
            #expect(decoded.mfaEnrollmentRequired == nil)
        }

        @Test("A server that publishes the field decodes it as authoritative")
        func presentFieldDecodes() throws {
            let decoded = try JSONDecoder.hlDefault.decode(
                AuthMeMfaEnrollment.self,
                from: Data(#"{"mfaEnrollmentRequired": true}"#.utf8)
            )
            #expect(decoded.mfaEnrollmentRequired == true)
        }
    }

#endif
