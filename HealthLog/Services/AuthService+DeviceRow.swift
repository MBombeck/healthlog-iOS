import Foundation

// MARK: - D3 #2: signing out takes the device's push registration with it

extension AuthService {
    /// Deletes this device's row (`DELETE /api/auth/me/devices/{id}`, the row
    /// `GET /api/auth/me/devices` marks `isCurrent`) while the session is
    /// still valid. Best effort: any failure is logged and the sign-out goes on.
    ///
    /// **Why.** Signing out only revoked the refresh token. The `Device` row
    /// kept its APNs token, and the server sends to every row that has one:
    /// the signed-out account's reminders, follow-ups and confirmations kept
    /// reaching the lock screen. Signing in with another account on the same
    /// iPhone then got `409` on `POST /api/devices` (the token belongs to the
    /// first account), so the new account received no server push at all.
    /// The row has to go before the revoke, because the delete needs a session
    /// and the revoke ends it.
    func deleteOwnDeviceRow() async {
        let list = APIRequest<OwnDeviceList>(
            method: .get,
            path: "/api/auth/me/devices",
            maxRetries: 0,
            failFast: true,
            allowsAuthenticationRecovery: false
        )
        do {
            let devices = try await api.send(list).devices
            guard let current = devices.first(where: { $0.isCurrent == true }),
                  let id = current.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else
            {
                HLLog.auth.info("Logout: no current device row to delete")
                return
            }
            let delete = APIRequest<EmptyPayload>(
                method: .delete,
                path: "/api/auth/me/devices/\(id)",
                maxRetries: 0,
                failFast: true,
                allowsAuthenticationRecovery: false
            )
            try await api.sendVoid(delete)
            HLLog.auth.info("Logout: device row deleted")
        } catch {
            HLLog.auth.warning(
                "Logout: device row not deleted err=\(LogSanitizer.redact(String(describing: error)), privacy: .public)"
            )
        }
    }
}

/// The two fields of `GET /api/auth/me/devices` the sign-out reads. Its own
/// type, since the widget extension compiles `AuthService` without the
/// devices repository.
struct OwnDeviceList: Decodable, Sendable {
    struct Device: Decodable, Sendable {
        let id: String
        let isCurrent: Bool?
    }

    let devices: [Device]
}
