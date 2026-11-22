#if DEBUG
    import Foundation

    /// **1.5 SEC — the step-up before a connector token, for the sweep.**
    /// Under `-uitest-sec` the account names its proofs (`proofMethods`:
    /// password and passkey, no second factor), so the proof sheet offers
    /// exactly those; the passkey means the mint asks before it is sent.
    /// `-uitest-sec-sso-only` is an account that signs in only through the
    /// organisation's login, with no factor and no passkey: it mints on the
    /// token. `nil` everywhere else.
    enum SecFixtures {
        static let argument = "-uitest-sec"
        static let ssoOnlyArgument = "-uitest-sec-sso-only"

        static func response(forPath path: String) -> (status: Int, body: Data)? {
            let arguments = ProcessInfo.processInfo.arguments
            guard path == "/api/auth/me/mfa", arguments.contains(argument) else { return nil }
            let methods = arguments.contains(ssoOnlyArgument) ? "[]" : #"["password","passkey"]"#
            let body = #"{"data":{"totp":{"enabled":false},"recoveryCodesRemaining":0,"webauthn":[],"#
                + #""passkeyNudgeDismissed":false,"proofMethods":\#(methods)},"error":null}"#
            return (200, Data(body.utf8))
        }

        /// `POST /api/mcp/tokens` — the minted token, shown once, as the server
        /// returns it. Without it the SSO-only account, which mints with no
        /// proof, saw the bare read error under its form. An invented value.
        static func mintResponse(forPath path: String, method: String) -> (status: Int, body: Data)? {
            guard method == "POST", path == "/api/mcp/tokens",
                  ProcessInfo.processInfo.arguments.contains(argument) else { return nil }
            let body = #"{"data":{"token":"hlk_sweep_example_token","name":"Claude","expiresAt":null},"error":null}"#
            return (200, Data(body.utf8))
        }
    }
#endif
