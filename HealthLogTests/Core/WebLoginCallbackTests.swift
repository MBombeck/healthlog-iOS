// #65 / v1.32.11 — pins the web-handoff login callback model + flow constants.
//
// Coverage (per the frozen server contract in the #65 plan):
//   1. `parse` returns `.code` for a well-formed login-callback URL.
//   2. each closed-set `error=<reason>` token parses to its case; `error`
//      beats `code` (precedence); an out-of-set token → `.unknown(raw)`.
//   3. host containment: an OIDC callback URL that reaches this parser resolves
//      to `.unrecognized` (cross-flow guard), never an accidental code exchange.
//   4. every reason's `localizedMessage` is non-empty and pairwise distinct.
//   5. `loginURL` carries `/api/auth/native/login` + `code_challenge=` and NO
//      `client=` item (the web-login contract knows only `code_challenge`).
//
// Pure model tests — no network, no web sheet.

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @Suite("Web-handoff login callback (#65)")
    struct WebLoginCallbackTests {
        // MARK: - 1) success parse

        @Test("parse returns .code for a well-formed login-callback URL")
        func parseCodeCallback() throws {
            let url = try #require(URL(string: "healthlog://login-callback?code=hlh_x0000000000000000000000000000000000000000"))
            #expect(WebLoginCallback.parse(url) == .code("hlh_x0000000000000000000000000000000000000000"))
        }

        // MARK: - 2) each error token + precedence + unknown

        @Test("every closed-set error token parses to its reason")
        func errorTokensParse() throws {
            let cases: [(String, WebLoginErrorReason)] = [
                ("invalid_state", .invalidState),
                ("no_session", .noSession),
                ("stale_session", .staleSession),
                ("rate_limited", .rateLimited)
            ]
            for (raw, expected) in cases {
                #expect(WebLoginErrorReason(raw: raw) == expected)
                let url = try #require(URL(string: "healthlog://login-callback?error=\(raw)"))
                #expect(WebLoginCallback.parse(url) == .error(expected))
            }
        }

        @Test("error takes precedence over a code in the same callback")
        func errorBeatsCode() throws {
            let url = try #require(URL(
                string: "healthlog://login-callback?error=stale_session&code=hlh_ignored000000000000000000000000000000000"
            ))
            #expect(WebLoginCallback.parse(url) == .error(.staleSession))
        }

        @Test("an out-of-set error token falls back to .unknown(raw) with a non-empty generic message")
        func unknownErrorToken() throws {
            let url = try #require(URL(string: "healthlog://login-callback?error=some_future_reason"))
            let parsed = WebLoginCallback.parse(url)
            #expect(parsed == .error(.unknown("some_future_reason")))
            #expect(WebLoginErrorReason(raw: "some_future_reason") == .unknown("some_future_reason"))
            #expect(!WebLoginErrorReason.unknown("some_future_reason").localizedMessage.isEmpty)
        }

        // MARK: - 3) cross-flow host containment

        @Test("an OIDC callback URL resolves to .unrecognized (cross-flow guard)")
        func oidcHostRejected() throws {
            let url = try #require(URL(
                string: "healthlog://oidc-callback?code=hlh_oidc00000000000000000000000000000000000000"
            ))
            #expect(WebLoginCallback.parse(url) == .unrecognized)
        }

        @Test("a login-callback with no recognised query is .unrecognized")
        func emptyQueryUnrecognized() throws {
            let url = try #require(URL(string: "healthlog://login-callback"))
            #expect(WebLoginCallback.parse(url) == .unrecognized)
        }

        // MARK: - 4) messages non-empty + distinct

        @Test("every reason maps to a non-empty, pairwise-distinct message")
        func messagesNonEmptyDistinct() {
            let reasons: [WebLoginErrorReason] = [.invalidState, .noSession, .staleSession, .rateLimited]
            var seen = Set<String>()
            for reason in reasons {
                let message = reason.localizedMessage
                #expect(!message.isEmpty)
                seen.insert(message)
            }
            #expect(seen.count == reasons.count)
        }

        // MARK: - 5) login-URL builder shape

        @Test("loginURL carries the native login path + code_challenge and no client item")
        func loginURLShape() throws {
            let base = try #require(URL(string: "https://meinserver.example.com"))
            let url = try #require(WebLoginNativeFlow.loginURL(baseURL: base, codeChallenge: "chal_ABC123"))
            let string = url.absoluteString
            #expect(string.contains("/api/auth/native/login"))
            #expect(string.contains("code_challenge=chal_ABC123"))
            #expect(!string.contains("client="))
        }

        @Test("flow constants: scheme healthlog, host login-callback")
        func flowConstants() {
            #expect(WebLoginNativeFlow.callbackScheme == "healthlog")
            #expect(WebLoginNativeFlow.callbackHost == "login-callback")
        }
    }

#endif
