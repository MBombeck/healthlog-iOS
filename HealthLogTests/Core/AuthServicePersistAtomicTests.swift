// Sicherheits-Pin für `AuthService.persist(_:)` (Security-Audit v0629 H-3):
// die Token-Persistierung muss atomar sein. Schlägt ein einzelner
// Keychain-Write während des Persist-Vorgangs fehl, dürfen wir KEINEN
// Mischzustand aus altem-Refresh + neuem-Bearer hinterlassen — sonst
// trifft der nächste Refresh-Versuch einen verbrauchten Refresh-Token,
// Server triggered `revokeAllForUser`, und der User wird auf allen Geräten
// stillschweigend ausgeloggt.
//
// Diese Tests treiben den Persist-Pfad über `service.login(...)` und
// injecten via `FailingKeychain` einen Write-Failure auf den
// Refresh-Token-Slot. Erwartung: vorheriger Credential-Satz bleibt
// vollständig intakt, neuer Bearer ist NICHT geschrieben.

// swiftlint:disable force_unwrapping force_try

import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif
#if canImport(AuthenticationServices)
    import AuthenticationServices
#endif

@Suite("AuthService.persist atomicity", .serialized)
struct AuthServicePersistAtomicTests {
    /// Passkey-Stub: nie aufgerufen, erfüllt nur die Service-Signatur.
    private final class NoopPasskey: PasskeyServiceProtocol, @unchecked Sendable {
        @MainActor func register(
            challenge _: String, rpId _: String, rpName _: String,
            userID _: String, userName _: String, displayName _: String,
            anchor _: ASPresentationAnchorProvider
        ) async throws -> PasskeyRegistration {
            throw HLError.unknown("noop")
        }

        @MainActor func assert(
            challenge _: String, rpId _: String, allowCredentialIDs _: [String],
            anchor _: ASPresentationAnchorProvider
        ) async throws -> PasskeyAssertion {
            throw HLError.unknown("noop")
        }
    }

    /// In-Memory Keychain mit Fehler-Injection auf bestimmten Keys. Wird
    /// `failOnKey` getroffen, wirft `setString`/`setData` einen
    /// `KeychainError.osStatus` — als simulierter Partial-Failure.
    private final class FailingKeychain: KeychainStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var store: [String: Data] = [:]
        private var _failOnKey: String?

        init(failOnKey: String? = nil) {
            _failOnKey = failOnKey
        }

        func setFailOnKey(_ key: String?) {
            lock.lock()
            defer { lock.unlock() }
            _failOnKey = key
        }

        func setString(_ value: String, forKey key: String) throws {
            guard let data = value.data(using: .utf8) else {
                throw KeychainError.encoding
            }
            try setData(data, forKey: key)
        }

        func getString(forKey key: String) -> String? {
            getData(forKey: key).flatMap { String(data: $0, encoding: .utf8) }
        }

        func setData(_ data: Data, forKey key: String) throws {
            lock.lock()
            defer { lock.unlock() }
            if _failOnKey == key {
                throw KeychainError.osStatus(-25300) // errSecItemNotFound (irrelevant, must just throw)
            }
            store[key] = data
        }

        func getData(forKey key: String) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return store[key]
        }

        func remove(forKey key: String) throws {
            lock.lock()
            defer { lock.unlock() }
            store.removeValue(forKey: key)
        }

        func removeAll() throws {
            lock.lock()
            defer { lock.unlock() }
            store.removeAll()
        }
    }

    private func makeService(keychain: KeychainStoring) -> AuthService {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let api = APIClient(
            environment: env,
            keychain: keychain,
            sessionConfiguration: .mock()
        )
        return AuthService(api: api, keychain: keychain, passkey: NoopPasskey())
    }

    /// Server-Antwort, die ein vollständiges native-Login-Bundle liefert
    /// (Bearer + Refresh + beide Expiries + User). `static` weil
    /// `MockURLProtocol.handler` ein `@Sendable`-Closure ist und keinen
    /// `self`-Capture auf die nicht-Sendable Test-Struct halten darf.
    private static func freshLoginResponseBody() -> Data {
        Data(#"""
        {
            "data": {
                "user": {
                    "id": "user-fresh-99",
                    "email": "fresh@example.com",
                    "username": "fresh",
                    "displayName": "Fresh"
                },
                "token": "hlk_bearer_FRESH",
                "tokenExpiresAt": "2026-06-01T12:00:00Z",
                "refreshToken": "hlk_refresh_FRESH",
                "refreshTokenExpiresAt": "2026-07-31T12:00:00Z"
            }
        }
        """#.utf8)
    }

    @Test("partial-failure: refresh-token write throws → previous credential set survives intact")
    func partialFailureRollsBack() async throws {
        let kc = FailingKeychain()
        // Bestehender Login-Zustand (z.B. nach einem früheren erfolgreichen Login).
        try kc.setString("hlk_bearer_OLD", forKey: KeychainKey.authToken)
        try kc.setString("hlk_refresh_OLD", forKey: KeychainKey.refreshToken)
        try kc.setString("2026-05-01T12:00:00Z", forKey: KeychainKey.accessTokenExpiresAt)
        try kc.setString("2026-06-30T12:00:00Z", forKey: KeychainKey.refreshTokenExpiresAt)
        try kc.setString("user-old-1", forKey: KeychainKey.userID)

        let service = makeService(keychain: kc)

        // Server liefert ein frisches Bundle, ABER der Keychain failt beim
        // Write des neuen Refresh-Tokens.
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.freshLoginResponseBody()
            )
        }
        kc.setFailOnKey(KeychainKey.refreshToken)

        // Login soll werfen — der Persist-Fehler muss nach oben durchschlagen.
        await #expect(throws: (any Error).self) {
            try await service.login(email: "fresh@example.com", password: "irrelevant")
        }

        // KRITISCH: vorheriger Credential-Satz ist KOMPLETT intakt.
        // Wäre die alte serielle-`try`-Variante noch im Spiel, läge jetzt
        // `hlk_bearer_FRESH` in `authToken` und `hlk_refresh_OLD` in
        // `refreshToken` → split-state.
        #expect(
            kc.getString(forKey: KeychainKey.authToken) == "hlk_bearer_OLD",
            "Bearer must roll back to previous value when refresh-write fails"
        )
        #expect(
            kc.getString(forKey: KeychainKey.refreshToken) == "hlk_refresh_OLD",
            "Refresh-token must keep previous value"
        )
        #expect(
            kc.getString(forKey: KeychainKey.accessTokenExpiresAt) == "2026-05-01T12:00:00Z",
            "Access-expiry must keep previous value"
        )
        #expect(
            kc.getString(forKey: KeychainKey.refreshTokenExpiresAt) == "2026-06-30T12:00:00Z",
            "Refresh-expiry must keep previous value"
        )
        #expect(
            kc.getString(forKey: KeychainKey.userID) == "user-old-1",
            "User-ID must keep previous value"
        )
    }

    @Test("partial-failure on first write: nothing previously persisted → state stays empty")
    func partialFailureFromEmpty() async throws {
        let kc = FailingKeychain()
        // KEIN bestehender Login-Zustand.
        let service = makeService(keychain: kc)

        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.freshLoginResponseBody()
            )
        }
        // Erster Write (authToken) failt.
        kc.setFailOnKey(KeychainKey.authToken)

        await #expect(throws: (any Error).self) {
            try await service.login(email: "fresh@example.com", password: "irrelevant")
        }

        // Keychain ist immer noch leer — kein Halb-Zustand.
        #expect(kc.getString(forKey: KeychainKey.authToken) == nil)
        #expect(kc.getString(forKey: KeychainKey.refreshToken) == nil)
        #expect(kc.getString(forKey: KeychainKey.userID) == nil)
    }

    @Test("happy path: no keychain failure → all five fields land with new values")
    func happyPathPersistsEverything() async throws {
        let kc = FailingKeychain()
        try kc.setString("hlk_bearer_OLD", forKey: KeychainKey.authToken)
        try kc.setString("hlk_refresh_OLD", forKey: KeychainKey.refreshToken)
        try kc.setString("user-old-1", forKey: KeychainKey.userID)

        let service = makeService(keychain: kc)

        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.freshLoginResponseBody()
            )
        }
        // No fail-key set.

        // #37 — `login` now returns a `LoginOutcome`; the no-MFA happy path
        // resolves to `.session`.
        guard case let .session(session) = try await service.login(email: "fresh@example.com", password: "irrelevant") else {
            Issue.record("expected .session outcome on the no-MFA happy path")
            return
        }
        #expect(session.token == "hlk_bearer_FRESH")

        #expect(kc.getString(forKey: KeychainKey.authToken) == "hlk_bearer_FRESH")
        #expect(kc.getString(forKey: KeychainKey.refreshToken) == "hlk_refresh_FRESH")
        #expect(kc.getString(forKey: KeychainKey.userID) == "user-fresh-99")
        #expect(kc.getString(forKey: KeychainKey.accessTokenExpiresAt) == "2026-06-01T12:00:00Z")
        #expect(kc.getString(forKey: KeychainKey.refreshTokenExpiresAt) == "2026-07-31T12:00:00Z")
        // build-75 — the cold-launch avatar seed: the best-available identity
        // label (here `displayName == "Fresh"`) is persisted so `bootstrap()`
        // can paint real initials before the server profile lands.
        #expect(kc.getString(forKey: KeychainKey.userDisplayName) == "Fresh")
    }

    @Test("identityHint precedence: displayName → username → email-local-part → nil")
    func identityHintFallbackLadder() {
        // displayName wins.
        #expect(
            AuthService.identityHint(
                for: User(id: "1", email: "x@y.z", username: "u", displayName: "Anna-Lena Fischer", createdAt: nil)
            ) == "Anna-Lena Fischer"
        )
        // username when displayName is blank.
        #expect(
            AuthService.identityHint(
                for: User(id: "1", email: "x@y.z", username: "anna_fischer", displayName: " ", createdAt: nil)
            ) == "anna_fischer"
        )
        // email-local-part when both name fields are absent.
        #expect(
            AuthService.identityHint(
                for: User(id: "1", email: "anna@example.com", username: nil, displayName: nil, createdAt: nil)
            ) == "anna"
        )
        // nothing usable → nil (caller skips the Keychain write).
        #expect(
            AuthService.identityHint(
                for: User(id: "1", email: nil, username: nil, displayName: nil, createdAt: nil)
            ) == nil
        )
    }
}
