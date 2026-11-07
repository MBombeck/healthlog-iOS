import Foundation

/// SEC (1.5, #151) — which ways of confirming the step-up sheet offers.
///
/// Two inputs decided this until 1.4: whether the route wants a second factor
/// (then no password) and whether the account has an authenticator (then a
/// code field). The passkey button was always there, a 409 being the way to
/// learn there is none. Since server 1.46.2 `GET /api/auth/me/mfa` names the
/// proofs this account can give (`proofMethods`, the list a recent-proof
/// refusal carries in `meta.methods`); when it is there, the sheet offers
/// exactly those that work in the app. `oidc` never does (a browser round trip
/// that only a cookie session completes, ``MfaStatus/offeredProofMethods``),
/// and a security key (`webauthn`) is a browser-only ceremony here. An account
/// left with none of them (an SSO-only account) is told so, instead of being
/// handed a field that can only fail. An older server (`nil`) keeps the 1.4
/// choice.
struct StepUpArms: Equatable {
    let passkey: Bool
    let totp: Bool
    let password: Bool

    init(requiresFresh: Bool, hasTotp: Bool, proofMethods: [String]?) {
        func offers(_ method: String) -> Bool {
            proofMethods?.contains(method) ?? true
        }
        passkey = offers("passkey")
        totp = hasTotp && offers("totp")
        password = !requiresFresh && offers("password")
    }

    /// Nothing in the app can confirm it is you on this account.
    var nothingInApp: Bool {
        !passkey && !totp && !password
    }
}

extension AccountSecurityStore {
    /// The proofs the server names for this account, without `oidc`. `nil`
    /// until the status is loaded and on a server that does not send the list.
    var offeredProofMethods: [String]? {
        if case let .loaded(status) = twoFactor { return status.offeredProofMethods }
        return nil
    }
}
