// R2 / #115 A6 — a refresh never leaves without `X-Device-Id`.
//
// Server v1.39.3 (`src/app/api/auth/refresh/route.ts` +
// `src/lib/auth/refresh-token.ts` at tag v1.39.6): a refresh token that is bound
// to a device is refused with `401 auth.refresh.invalid` when the request
// carries no `X-Device-Id`. `RefreshOutcome` reads that — correctly — as a dead
// token, so the person is signed out. The app attached the header only when
// `keychain.deviceID()` succeeded (`try?` in `APIClient.buildURLRequest`), so a
// single failed Keychain read at refresh time sent the refresh without it.
//
// Drives the REAL `AuthService.refresh()` over the REAL `APIClient`; the stub
// transport answers exactly like the v1.39.3 route: no header → 401
// `auth.refresh.invalid`, header present → the token-only refresh body.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    @Suite("Refresh never sends without the device id (R2 / A6)", .serialized, .mockURLSession)
    struct RefreshDeviceIDTests {
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

        /// A Keychain whose device-id slot fails the first `failures` reads the
        /// way a locked Keychain does: the read answers `nil` and the
        /// generate-and-store fallback inside `deviceID()` throws. Every other
        /// slot behaves normally.
        private final class FlakyDeviceIDKeychain: KeychainStoring, @unchecked Sendable {
            private let base = InMemoryKeychain()
            private let lock = NSLock()
            private var remainingFailures: Int
            private(set) var deviceIDReads = 0

            init(storedDeviceID: String, failures: Int) {
                remainingFailures = failures
                try? base.setString(storedDeviceID, forKey: KeychainKey.deviceID)
            }

            private func failingNow() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                deviceIDReads += 1
                guard remainingFailures > 0 else { return false }
                remainingFailures -= 1
                return true
            }

            private var lastReadFailed = false

            func getString(forKey key: String) -> String? {
                if key == KeychainKey.deviceID {
                    let fail = failingNow()
                    lock.lock()
                    lastReadFailed = fail
                    lock.unlock()
                    if fail { return nil }
                }
                return base.getString(forKey: key)
            }

            func setString(_ value: String, forKey key: String) throws {
                if key == KeychainKey.deviceID {
                    lock.lock()
                    let refuse = lastReadFailed
                    lock.unlock()
                    if refuse { throw KeychainError.encoding }
                }
                try base.setString(value, forKey: key)
            }

            func setData(_ data: Data, forKey key: String) throws {
                try base.setData(data, forKey: key)
            }

            func getData(forKey key: String) -> Data? {
                base.getData(forKey: key)
            }

            func remove(forKey key: String) throws {
                try base.remove(forKey: key)
            }

            func removeAll() throws {
                try base.removeAll()
            }
        }

        /// What the stub server saw on each refresh.
        private final class Wire: @unchecked Sendable {
            private let lock = NSLock()
            private var seen: [String?] = []
            func record(_ deviceID: String?) {
                lock.lock()
                defer { lock.unlock() }
                seen.append(deviceID)
            }

            var deviceIDs: [String?] {
                lock.lock()
                defer { lock.unlock() }
                return seen
            }
        }

        private static let deviceID = "0b5c6f1e-device-bound"

        private func makeService(_ keychain: KeychainStoring) -> AuthService {
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            let api = APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
            return AuthService(api: api, keychain: keychain, passkey: NoopPasskey())
        }

        /// The v1.39.3 route for a token bound to ``deviceID``.
        private func installServer(_ wire: Wire) {
            MockURLProtocol.install { req in
                let presented = req.value(forHTTPHeaderField: "X-Device-Id")
                wire.record(presented)
                guard presented == Self.deviceID else {
                    return (
                        HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"data":null,"error":"Invalid refresh token","meta":{"errorCode":"auth.refresh.invalid"}}"#.utf8)
                    )
                }
                let body = #"""
                {"data":{"token":"hlk_bearer_NEW","tokenExpiresAt":"2027-06-01T12:00:00Z","refreshToken":"hlr_refresh_NEW","refreshTokenExpiresAt":"2027-07-31T12:00:00Z"},"error":null}
                """#
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8)
                )
            }
        }

        private func seed(_ keychain: KeychainStoring) throws {
            try keychain.setString("hlk_bearer_OLD", forKey: KeychainKey.authToken)
            try keychain.setString("hlr_refresh_OLD", forKey: KeychainKey.refreshToken)
            try keychain.setString("usr_1", forKey: KeychainKey.userID)
        }

        @Test("one failed Keychain read: the refresh retries the read and still sends the device id")
        func transientReadIsRetried() async throws {
            let keychain = FlakyDeviceIDKeychain(storedDeviceID: Self.deviceID, failures: 1)
            try seed(keychain)
            let wire = Wire()
            installServer(wire)

            let outcome = await makeService(keychain).refresh()

            #expect(outcome == .refreshed)
            #expect(wire.deviceIDs == [Self.deviceID])
            #expect(keychain.getString(forKey: KeychainKey.authToken) == "hlk_bearer_NEW")
        }

        @Test("two failed reads in a row are still inside the retry budget")
        func twoFailuresStillRefresh() async throws {
            let keychain = FlakyDeviceIDKeychain(storedDeviceID: Self.deviceID, failures: 2)
            try seed(keychain)
            let wire = Wire()
            installServer(wire)

            let outcome = await makeService(keychain).refresh()

            #expect(outcome == .refreshed)
            #expect(wire.deviceIDs == [Self.deviceID])
        }

        @Test("an unreadable device id defers the refresh: nothing is sent, the session is kept")
        func unreadableDeviceIDSendsNothing() async throws {
            let keychain = FlakyDeviceIDKeychain(storedDeviceID: Self.deviceID, failures: 1000)
            try seed(keychain)
            let wire = Wire()
            installServer(wire)

            let outcome = await makeService(keychain).refresh()

            // `.transient`, never `.authFailure`: the caller must not sign out.
            #expect(outcome == .transient)
            #expect(wire.deviceIDs.isEmpty)
            #expect(keychain.getString(forKey: KeychainKey.refreshToken) == "hlr_refresh_OLD")
            #expect(keychain.getString(forKey: KeychainKey.authToken) == "hlk_bearer_OLD")
            #expect(keychain.deviceIDReads == AuthService.refreshDeviceIDAttempts)
        }

        @Test("a healthy Keychain: exactly one refresh, carrying the stored id")
        func healthyKeychain() async throws {
            let keychain = FlakyDeviceIDKeychain(storedDeviceID: Self.deviceID, failures: 0)
            try seed(keychain)
            let wire = Wire()
            installServer(wire)

            #expect(await makeService(keychain).refresh() == .refreshed)
            #expect(wire.deviceIDs == [Self.deviceID])
        }
    }

#endif
