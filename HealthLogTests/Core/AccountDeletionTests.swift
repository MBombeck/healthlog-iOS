// Account-Deletion-Verhalten an der Service-Grenze: ein Round-Trip an
// `DELETE /api/settings/account` mit `{ confirm: "DELETE_ACCOUNT" }`.
// Bei 2xx wird der Keychain (Bearer + Refresh + Expiries + UserID + DeviceID)
// gewipt; bei jedem 4xx/5xx bleibt die Keychain unangetastet.
//
// Refs: A7-apple-compliance-research.md BLOCKER 5.1.1-A
//       /src/app/api/settings/account/route.ts (Server-Schema)

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

@Suite("AuthService.deleteAccount", .serialized)
struct AccountDeletionTests {
    /// Lokaler Passkey-Stub — die `StubPasskeyService`-Variante aus dem App-Target
    /// existiert nur in Non-iOS-Builds, hier brauchen wir aber etwas, das die
    /// AuthService-Signatur erfuellt, ohne je aufgerufen zu werden.
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

    private final class CapturedRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var _method: String?
        private var _path: String?
        private var _body: Data?

        func capture(_ req: URLRequest) {
            lock.withLock {
                _method = req.httpMethod
                _path = req.url?.path
                _body = req.httpBody ?? bodyFromStream(req)
            }
        }

        private func bodyFromStream(_ req: URLRequest) -> Data? {
            guard let stream = req.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufSize = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: bufSize)
                if read <= 0 { break }
                data.append(buf, count: read)
            }
            return data
        }

        var method: String? {
            lock.withLock { _method }
        }

        var path: String? {
            lock.withLock { _path }
        }

        var body: Data? {
            lock.withLock { _body }
        }
    }

    /// Keychain double for the post-2xx failure path. A targeted delete can
    /// fail while the service-wide fail-closed fallback still succeeds; a
    /// second switch lets us verify that an unrecoverable Keychain failure
    /// never skips the app-level cleanup/phase transition after the account is
    /// already gone on the server.
    private final class RemovalFailingKeychain: KeychainStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var store: [String: Data] = [:]
        private let failedRemovalKey: String
        private let failRemoveAll: Bool

        init(failedRemovalKey: String, failRemoveAll: Bool = false) {
            self.failedRemovalKey = failedRemovalKey
            self.failRemoveAll = failRemoveAll
        }

        func setString(_ value: String, forKey key: String) throws {
            guard let data = value.data(using: .utf8) else { throw KeychainError.encoding }
            try setData(data, forKey: key)
        }

        func getString(forKey key: String) -> String? {
            getData(forKey: key).flatMap { String(data: $0, encoding: .utf8) }
        }

        func setData(_ data: Data, forKey key: String) throws {
            lock.withLock { store[key] = data }
        }

        func getData(forKey key: String) -> Data? {
            lock.withLock { store[key] }
        }

        func remove(forKey key: String) throws {
            if key == failedRemovalKey { throw KeychainError.osStatus(-1) }
            lock.withLock { _ = store.removeValue(forKey: key) }
        }

        func removeAll() throws {
            if failRemoveAll { throw KeychainError.osStatus(-1) }
            lock.withLock { store.removeAll() }
        }
    }

    private final class CleanupSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var owner: String?

        func record(owner: String? = nil) {
            lock.withLock {
                count += 1
                self.owner = owner
            }
        }

        var calls: Int {
            lock.withLock { count }
        }

        var cleanedOwner: String? {
            lock.withLock { owner }
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

    private func seedAuthenticatedKeychain(_ kc: KeychainStoring) throws {
        try kc.setString("hlk_bearer_xyz", forKey: KeychainKey.authToken)
        try kc.setString("hlk_refresh_abc", forKey: KeychainKey.refreshToken)
        try kc.setString("2026-05-30T12:00:00Z", forKey: KeychainKey.accessTokenExpiresAt)
        try kc.setString("2026-07-13T12:00:00Z", forKey: KeychainKey.refreshTokenExpiresAt)
        try kc.setString("user-42", forKey: KeychainKey.userID)
        try kc.setString("Account Fixture", forKey: KeychainKey.userDisplayName)
        try kc.setString("device-uuid-existing", forKey: KeychainKey.deviceID)

        // Account-bound AI choices must never cross the deletion boundary.
        // Seed every persistence shape, including the provider-less server-
        // managed scope that cannot be reached by the AIProvider loop.
        try kc.setString("granted", forKey: AIConsentStore.keyPrefix + AIProvider.anthropic.rawValue)
        try kc.setString("declined-marker", forKey: AIConsentStore.declinedKeyPrefix + AIProvider.local.rawValue)
        try kc.setString("granted", forKey: AIConsentStore.serverManagedScope)
        try kc.setString("declined-marker", forKey: AIConsentStore.serverManagedDeclinedKey)
        try kc.setString("granted", forKey: AIConsentStore.byoKeyPrefix + BYOProviderID.openAI.rawValue)
        try kc.setString("provider-secret-fixture", forKey: BYOKeyStore.keyPrefix + BYOProviderID.openAI.rawValue)
        try kc.setString("model-fixture", forKey: BYOKeyStore.modelPrefix + BYOProviderID.openAI.rawValue)
        try kc.setString(
            "https://provider.invalid/v1",
            forKey: BYOKeyStore.baseURLPrefix + BYOProviderID.openAICompatible.rawValue
        )
    }

    @Test("happy path: 2xx -> Keychain wird vollständig gewipt")
    func happyPathWipesKeychain() async throws {
        let kc = InMemoryKeychain()
        try seedAuthenticatedKeychain(kc)
        let captured = CapturedRequest()
        let service = makeService(keychain: kc)
        let ownerCleanup = CleanupSpy()
        await service.setOnLogoutCleanup { ownerCleanup.record(owner: $0) }

        MockURLProtocol.handler = { req in
            captured.capture(req)
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{"deleted":true}}"#.utf8)
            )
        }

        try await service.deleteAccount()

        // Server hat genau einen DELETE auf den richtigen Pfad mit dem
        // confirm-Body bekommen.
        #expect(captured.method == "DELETE")
        #expect(captured.path == "/api/settings/account")
        let body = captured.body
        #expect(body != nil, "expected confirm-body on DELETE")
        if let body,
           let parsed = try JSONSerialization.jsonObject(with: body) as? [String: String]
        {
            #expect(parsed["confirm"] == "DELETE_ACCOUNT")
        } else {
            Issue.record("body did not decode as { confirm: String }")
        }

        // Keychain ist leer.
        #expect(kc.getString(forKey: KeychainKey.authToken) == nil)
        #expect(kc.getString(forKey: KeychainKey.refreshToken) == nil)
        #expect(kc.getString(forKey: KeychainKey.refreshTokenExpiresAt) == nil)
        #expect(kc.getString(forKey: KeychainKey.accessTokenExpiresAt) == nil)
        #expect(kc.getString(forKey: KeychainKey.userID) == nil)
        #expect(kc.getString(forKey: KeychainKey.userDisplayName) == nil)
        #expect(kc.getString(forKey: KeychainKey.deviceID) == nil)
        #expect(kc.getString(forKey: AIConsentStore.keyPrefix + AIProvider.anthropic.rawValue) == nil)
        #expect(kc.getString(forKey: AIConsentStore.declinedKeyPrefix + AIProvider.local.rawValue) == nil)
        #expect(kc.getString(forKey: AIConsentStore.serverManagedScope) == nil)
        #expect(kc.getString(forKey: AIConsentStore.serverManagedDeclinedKey) == nil)
        #expect(kc.getString(forKey: AIConsentStore.byoKeyPrefix + BYOProviderID.openAI.rawValue) == nil)
        #expect(kc.getString(forKey: BYOKeyStore.keyPrefix + BYOProviderID.openAI.rawValue) == nil)
        #expect(kc.getString(forKey: BYOKeyStore.modelPrefix + BYOProviderID.openAI.rawValue) == nil)
        #expect(kc.getString(forKey: BYOKeyStore.baseURLPrefix + BYOProviderID.openAICompatible.rawValue) == nil)
        #expect(ownerCleanup.calls == 1)
        #expect(ownerCleanup.cleanedOwner == "user-42", "owner cleanup must receive the pre-wipe account ID")
    }

    @Test("2xx + targeted Keychain removal failure -> fail-closed fallback clears the whole local Keychain")
    func targetedCleanupFailureFallsBackToFullWipe() async throws {
        let kc = RemovalFailingKeychain(failedRemovalKey: KeychainKey.authToken)
        try seedAuthenticatedKeychain(kc)
        let service = makeService(keychain: kc)

        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                nil
            )
        }

        try await service.deleteAccount()

        #expect(kc.getString(forKey: KeychainKey.authToken) == nil)
        #expect(kc.getString(forKey: KeychainKey.refreshToken) == nil)
        #expect(kc.getString(forKey: KeychainKey.userID) == nil)
        #expect(kc.getString(forKey: AIConsentStore.serverManagedScope) == nil)
        #expect(kc.getString(forKey: AIConsentStore.serverManagedDeclinedKey) == nil)
    }

    @Test("2xx + unrecoverable Keychain failure -> app cleanup still runs and session becomes unauthenticated")
    @MainActor
    func unrecoverableCleanupFailureStillClosesSession() async throws {
        let kc = RemovalFailingKeychain(
            failedRemovalKey: KeychainKey.authToken,
            failRemoveAll: true
        )
        try seedAuthenticatedKeychain(kc)
        let service = makeService(keychain: kc)
        let suite = try #require(UserDefaults(suiteName: "account-delete.\(UUID().uuidString)"))
        let store = AuthStore(auth: service, keychain: kc, defaults: suite)
        store.setPhaseForTesting(.authenticated(
            User(id: "user-42", email: nil, username: nil, displayName: nil, createdAt: .now)
        ))
        store.markPendingWebDeletion()
        let cleanup = CleanupSpy()
        store.localCleanupHook = { cleanup.record() }

        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{"deleted":true}}"#.utf8)
            )
        }

        let deleted = await store.deleteAccount()

        #expect(deleted, "the server already deleted the account; local teardown failure must not report a false retry")
        #expect(cleanup.calls == 1, "the sensitive-cache cascade must still run")
        #expect(store.phase == .unauthenticated)
        #expect(!store.hasPendingWebDeletion, "stale web-deletion state must not cross into a later session")
    }

    @Test("Server-Fehler (422 missing confirm) -> wirft + Keychain bleibt komplett intakt")
    func failureKeepsKeychainIntact() async throws {
        let kc = InMemoryKeychain()
        try seedAuthenticatedKeychain(kc)
        let service = makeService(keychain: kc)

        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null,"error":"Confirmation missing"}"#.utf8)
            )
        }

        await #expect(throws: HLError.self) {
            try await service.deleteAccount()
        }

        // Alles muss noch da sein — sonst würde ein blosser Server-Hiccup
        // den User stillschweigend aus seinem eigenen Konto kicken.
        #expect(kc.getString(forKey: KeychainKey.authToken) == "hlk_bearer_xyz")
        #expect(kc.getString(forKey: KeychainKey.refreshToken) == "hlk_refresh_abc")
        #expect(kc.getString(forKey: KeychainKey.userID) == "user-42")
        #expect(kc.getString(forKey: KeychainKey.deviceID) == "device-uuid-existing")
    }

    @Test("#37/#38 MFA step-up (401 auth.stepup.required) -> typed .server body preserved, Keychain intakt, isMfaStepUpRequired")
    func mfaStepUpPreservesBodyAndKeychain() async throws {
        let kc = InMemoryKeychain()
        try seedAuthenticatedKeychain(kc)
        let service = makeService(keychain: kc)

        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null,"error":"Fresh two-factor confirmation required","errorCode":"auth.stepup.required"}"#.utf8)
            )
        }

        // The 401 must NOT collapse to `.unauthorized` (that would churn a refresh
        // and read as "please re-login"); it surfaces the typed body so the delete
        // flow can route the user to the web deletion page.
        let thrown: HLError? = await {
            do {
                try await service.deleteAccount()
                return nil
            } catch let err as HLError {
                return err
            } catch {
                return nil
            }
        }()

        let err = try #require(thrown)
        #expect(err.isMfaStepUpRequired)
        #expect(err == .server(status: 401, code: "auth.stepup.required", message: "Fresh two-factor confirmation required"))
        // The account is NOT gone — tokens + device identity must survive so the
        // user can still complete the deletion on the web (or cancel).
        #expect(kc.getString(forKey: KeychainKey.authToken) == "hlk_bearer_xyz")
        #expect(kc.getString(forKey: KeychainKey.refreshToken) == "hlk_refresh_abc")
        #expect(kc.getString(forKey: KeychainKey.deviceID) == "device-uuid-existing")
    }

    @Test("500 server error -> wirft + Keychain bleibt intakt")
    func serverErrorKeepsKeychainIntact() async throws {
        let kc = InMemoryKeychain()
        try seedAuthenticatedKeychain(kc)
        let service = makeService(keychain: kc)

        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null,"error":"Internal"}"#.utf8)
            )
        }

        await #expect(throws: HLError.self) {
            try await service.deleteAccount()
        }
        #expect(kc.getString(forKey: KeychainKey.authToken) == "hlk_bearer_xyz")
        #expect(kc.getString(forKey: KeychainKey.deviceID) == "device-uuid-existing")
    }
}
