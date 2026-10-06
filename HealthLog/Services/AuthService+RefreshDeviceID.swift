import Foundation

// MARK: - R2 / #115 A6 — the refresh never leaves without its device id

extension AuthService {
    /// How often ``deviceIDForRefresh()`` asks the Keychain before it gives up.
    static let refreshDeviceIDAttempts = 3
    /// Pause between two of those reads. Short on purpose: the refresh sits in
    /// front of a request the person is waiting for.
    static let refreshDeviceIDRetryDelay: Duration = .milliseconds(150)

    /// The install's device id for `POST /api/auth/refresh`, read with a short
    /// retry.
    ///
    /// **Why.** Since server v1.39.3 the refresh route refuses a refresh token
    /// that is bound to a device when the request carries no `X-Device-Id`:
    /// `401 auth.refresh.invalid`, which ``RefreshOutcome`` correctly reads as a
    /// dead token — the person is signed out. `APIClient.buildURLRequest` sends
    /// the header only when `keychain.deviceID()` succeeds (`try?`), so a single
    /// failed Keychain read at refresh time (protected data not yet available,
    /// a transient `SecItem` error) used to send the refresh without it.
    ///
    /// A miss is retried a few times; if the id still cannot be read, the
    /// caller answers ``RefreshOutcome/transient`` without sending anything.
    /// The access token stays, the request fails this once, and the next 401
    /// refreshes again — the same stance as a refresh that hits no network.
    func deviceIDForRefresh() async -> String? {
        for attempt in 1 ... Self.refreshDeviceIDAttempts {
            if let id = try? keychain.deviceID(), !id.isEmpty {
                return id
            }
            if attempt < Self.refreshDeviceIDAttempts {
                try? await Task.sleep(for: Self.refreshDeviceIDRetryDelay)
            }
        }
        HLLog.auth.warning("Refresh deferred: the device id could not be read from the Keychain.")
        return nil
    }

    /// `POST /api/auth/refresh` with the device id pinned as an explicit header.
    ///
    /// `extraHeaders` are applied after the client's own `X-Device-Id`, so the
    /// id read above is what goes out even if a second Keychain read inside
    /// `buildURLRequest` fails. `maxRetries: 0` — the token is one-time-use
    /// (a resend would be reuse → family revoked); `failFast` — the auth
    /// session (#96).
    static func refreshRequest(
        body: some Encodable,
        deviceID: String
    ) throws -> APIRequest<NativeLoginResponse> {
        try APIRequest(
            method: .post,
            path: "/api/auth/refresh",
            body: JSONEncoder.hlDefault.encode(body),
            extraHeaders: ["X-Device-Id": deviceID],
            maxRetries: 0,
            failFast: true
        )
    }
}
