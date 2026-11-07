import Foundation

/// KONTO (#157 point 3, server 1.46.2) — `GET /api/auth/me/mfa` carries
/// `proofMethods`: the ways this account can confirm it is you (`password`,
/// `oidc`, `totp`, `webauthn`, `passkey`), the list a recent-proof refusal
/// names in `meta.methods`. `nil` on an older server. SEC (wave 4d) builds the
/// step-up on it; until then it is only decoded.
public extension MfaStatus {
    internal enum CodingKeys: String, CodingKey {
        case totp, recoveryCodesRemaining, webauthn, passkeyNudgeDismissed, proofMethods
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totp = try c.decode(Totp.self, forKey: .totp)
        recoveryCodesRemaining = try c.decode(Int.self, forKey: .recoveryCodesRemaining)
        webauthn = try c.decode([SecurityKey].self, forKey: .webauthn)
        passkeyNudgeDismissed = try c.decode(Bool.self, forKey: .passkeyNudgeDismissed)
        // Tolerant: a malformed list is the same as none.
        proofMethods = try? c.decodeIfPresent([String].self, forKey: .proofMethods)
    }

    /// The proof methods a native client may offer. `oidc` is a browser round
    /// trip that only a cookie session can complete, so it is never offered,
    /// even if a server sent it.
    var offeredProofMethods: [String]? {
        proofMethods?.filter { $0 != "oidc" }
    }
}
