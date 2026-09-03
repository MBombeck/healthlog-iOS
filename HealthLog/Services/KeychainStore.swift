import Foundation
import Security

public protocol KeychainStoring: Sendable {
    func setString(_ value: String, forKey key: String) throws
    func getString(forKey key: String) -> String?
    func setData(_ data: Data, forKey key: String) throws
    func getData(forKey key: String) -> Data?
    func remove(forKey key: String) throws
    func removeAll() throws
}

public struct KeychainStore: KeychainStoring, Sendable {
    /// The one `kSecAttrService` every HealthLog process uses. `kSecAttrService`
    /// is part of the generic-password primary key, so it must NOT be derived
    /// from `Bundle.main.bundleIdentifier`: the widget extension runs as
    /// `dev.healthlog.app.widgets` and would otherwise read an empty keychain
    /// (no bearer, no server URL, no outbox cipher key) — every interactive
    /// widget intent then aborts silently.
    public static let appService = "dev.healthlog.app"

    public let service: String
    public let accessGroup: String?

    public init(service: String = KeychainStore.appService, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func setString(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encoding
        }
        try setData(data, forKey: key)
    }

    public func getString(forKey key: String) -> String? {
        guard let data = getData(forKey: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setData(_ data: Data, forKey key: String) throws {
        var query = baseQuery(key: key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        SecItemDelete(query as CFDictionary) // upsert semantics
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.osStatus(status)
        }
    }

    public func getData(forKey key: String) -> Data? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return data
    }

    public func remove(forKey key: String) throws {
        let query = baseQuery(key: key)
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            throw KeychainError.osStatus(status)
        }
    }

    public func removeAll() throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            throw KeychainError.osStatus(status)
        }
    }

    private func baseQuery(key: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        if let accessGroup {
            q[kSecAttrAccessGroup as String] = accessGroup
        }
        return q
    }
}

public enum KeychainError: Error, Sendable {
    case encoding
    case osStatus(OSStatus)
}

public enum KeychainKey {
    public static let authToken = "auth.bearer"
    public static let refreshToken = "auth.refresh"
    /// `Date` ISO-8601 String — wann der aktuelle Refresh-Token abläuft (60d
    /// rotating fenster, siehe `05-auth-flows.md §3`).
    public static let refreshTokenExpiresAt = "auth.refresh.expiresAt"
    /// `Date` ISO-8601 String — wann der aktuelle Access-Token abläuft (24h).
    public static let accessTokenExpiresAt = "auth.bearer.expiresAt"
    public static let serverURL = "auth.serverURL"
    /// SHA-256 host fingerprint written only after the user explicitly
    /// confirms a server address. It lets one-time legacy-host migration
    /// distinguish restored Keychain state from a fresh trust decision without
    /// retaining the host itself as readable product or configuration data.
    public static let serverURLExplicitHostFingerprint = "auth.serverURL.explicitHostFingerprint"
    public static let userID = "auth.userID"
    /// Build 273 (sync audit A2) — the user-id the last credential wipe signed
    /// out. Written by `AuthService.invalidateAndWipeSessionCredentials()`
    /// BEFORE `userID` is removed, read only by the outbox owner provider: a
    /// write that hits a terminal 401 is enqueued after the wipe and would
    /// otherwise be stamped ownerless and quarantined forever. Cleared on
    /// account deletion and server switch alongside the outbox itself.
    public static let lastSessionUserID = "auth.lastSessionUserID"
    /// Best-available identity label captured at login (`displayName` →
    /// `username` → email-local-part). Persisted alongside `userID` so the
    /// cold-launch `bootstrap()` can seed a named `User` — otherwise the
    /// Dashboard / Profile avatar paints a `"?"` monogram until
    /// `GET /api/user/profile` lands. Local-only, never leaves the device;
    /// wiped on logout / 401-bridge / account deletion alongside `userID`.
    public static let userDisplayName = "auth.userDisplayName"
    /// Stable per-install UUID, sent as `X-Device-Id` on every authenticated
    /// request. Server bindet den Refresh-Token an dieses Device-Row +
    /// nutzt es als Pivot für Revocation. Wird in
    /// `KeychainStore` mit `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
    /// persistiert — kein iCloud-Sync, sonst kollidieren zwei Geräte.
    public static let deviceID = "auth.deviceID"
    /// AES-GCM key for the outbox payload cipher (W-SEC-A, v0.6.2). Mirrored
    /// here so the logout + account-deletion paths can wipe it alongside the
    /// auth bundle. The key itself is also referenced as
    /// `OutboxPayloadCipher.defaultKeyAccount` — drift between the two would
    /// strand ciphertext rows undecryptable while leaving the key persisted,
    /// so the constants are intentionally identical strings.
    public static let outboxPayloadKey = "outbox.payload.key"

    public static func hkAnchor(typeIdentifier: String) -> String {
        "hk.anchor.\(typeIdentifier)"
    }
}

public extension KeychainStoring {
    /// Returns the persisted device-id, generating + persisting one on first
    /// access. Idempotent — concurrent first-call races are benign because
    /// either UUID is acceptable (server normalises on first use). Throws only
    /// if the Keychain refuses the write entirely.
    func deviceID() throws -> String {
        if let existing = getString(forKey: KeychainKey.deviceID) {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        try setString(fresh, forKey: KeychainKey.deviceID)
        return fresh
    }
}
