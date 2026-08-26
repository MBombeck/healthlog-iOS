import CryptoKit
import Foundation

/// App-generated PKCE (RFC 7636) for the native OIDC SSO leg (#49 / v1.30.11).
///
/// **S256 only.** The app mints its own `codeVerifier` + `codeChallenge`, opens
/// `…/api/auth/oidc/login?client=native&code_challenge=<challenge>` inside an
/// `ASWebAuthenticationSession`, and keeps the `codeVerifier` **in memory** until
/// the one-shot token exchange (`POST /api/auth/oidc/native/token`). That
/// in-memory verifier is exactly what makes an intercepted handoff code useless
/// to a scheme-squatting app. The verifier is **never persisted and never
/// logged**. This app-side PKCE is separate from the server↔IdP PKCE, which
/// stays server-owned.
public struct OidcPKCE: Sendable, Equatable {
    /// The PKCE `code_verifier`: 43–128 chars, `^[A-Za-z0-9\-._~]{43,128}$`. We
    /// emit 32 cryptographically-random bytes → a 43-char base64url string (the
    /// RFC-recommended entropy floor).
    public let codeVerifier: String
    /// The PKCE `code_challenge`: `base64url(SHA256(codeVerifier))` (S256).
    public let codeChallenge: String

    /// Derives the S256 challenge for a caller-supplied verifier. Used by
    /// ``generate()`` and by the derivation unit test (known verifier → known
    /// challenge, RFC 7636 Appendix B).
    public init(codeVerifier: String) {
        self.codeVerifier = codeVerifier
        codeChallenge = Self.s256Challenge(for: codeVerifier)
    }

    /// Fresh PKCE pair: 32 cryptographically-random bytes → base64url verifier
    /// plus its S256 challenge. `SystemRandomNumberGenerator` is documented as
    /// cryptographically secure on Apple platforms.
    public static func generate() -> OidcPKCE {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        for _ in 0 ..< 32 {
            bytes.append(UInt8.random(in: UInt8.min ... UInt8.max, using: &generator))
        }
        return OidcPKCE(codeVerifier: base64URLEncode(Data(bytes)))
    }

    /// `base64url(SHA256(verifier))` — no padding, URL-safe alphabet. Pure.
    public static func s256Challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    /// Local base64url (unpadded) so this type carries no dependency on the
    /// UIKit-gated `Data.base64URLEncodedString()` in `PasskeyService` — keeping
    /// PKCE testable on every build (incl. the SPM test host) without a
    /// duplicate-symbol clash.
    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
