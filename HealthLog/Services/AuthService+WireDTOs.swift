import Foundation

extension String {
    /// `nil` if the trimmed string is empty, otherwise the trimmed string.
    var trimmedNonEmptyHint: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Wire DTOs (server-Schema-konform)

struct NativeLoginResponse: Decodable {
    /// Server liefert auf `/api/auth/login` ein volles `user`-Objekt; auf
    /// `/api/auth/refresh` (W2a-A2 §3.1) gibt es kein `user` zurück — daher
    /// optional, mit Anonymous-Fallback im `asAuthSession()`-Pfad.
    let user: User?
    let token: String?
    let tokenExpiresAt: Date?
    /// Refresh-Token-Pair wird vom Server NUR bei `X-Client-Type: native`
    /// (oder `User-Agent: HealthLog-iOS/...`) ausgestellt — siehe
    /// `05-auth-flows.md §2`. Früher hat iOS dieses Feld komplett ignoriert
    /// → silent 24h-Logout (W2a-A2 Audit §2.7 + §3 P0).
    let refreshToken: String?
    let refreshTokenExpiresAt: Date?

    func asAuthSession() throws -> AuthSession {
        guard let token else {
            throw HLError.unknown("Server hat keinen Bearer-Token zurückgegeben (X-Client-Type: native fehlt?)")
        }
        // Refresh-Pfad antwortet ohne `user`-Block — wir reichern ihn nicht
        // an, weil der vorhandene `phase = .authenticated(user)` den Wert
        // ohnehin nur aus dem ersten Login trägt. Ein leerer Stub-User reicht.
        let resolvedUser = user ?? User(id: "", email: nil, username: nil, displayName: nil, createdAt: nil)
        return AuthSession(
            token: token,
            refreshToken: refreshToken,
            refreshTokenExpiresAt: refreshTokenExpiresAt,
            user: resolvedUser,
            expiresAt: tokenExpiresAt
        )
    }
}

struct PasskeyLoginOptionsResponse: Decodable {
    let challengeId: String
    let options: PublicKeyCredentialRequestOptions

    struct PublicKeyCredentialRequestOptions: Decodable {
        let challenge: String
        let rpId: String
        let allowCredentials: [Descriptor]?
        let userVerification: String?

        struct Descriptor: Decodable {
            let id: String
            let type: String
        }
    }
}

/// #37 — the `WebauthnOptionsResponse` for the mfa-webauthn options leg.
/// The server types `options` loosely (`additionalProperties: {}`), but the
/// live fields are the standard SimpleWebAuthn assertion-options shape — we
/// decode the same `{ challenge, rpId, allowCredentials }` subset the passkey
/// login path already uses.
struct MfaWebauthnOptionsResponse: Decodable {
    let challengeId: String
    let options: Options

    struct Options: Decodable {
        let challenge: String
        let rpId: String
        let allowCredentials: [Descriptor]?

        struct Descriptor: Decodable {
            let id: String
            let type: String
        }
    }
}

struct WebAuthnAssertionDTO: Encodable {
    let id: String
    let rawId: String
    let type: String
    let response: AssertionResponse

    struct AssertionResponse: Encodable {
        let clientDataJSON: String
        let authenticatorData: String
        let signature: String
        let userHandle: String?
    }
}
