// **Phase 09 / plan 09-07 — the seams the cross-flow convergence proof runs on.**
//
// Six flows can end in an `AuthSession`: password, MFA (TOTP here, security key
// in the cancellation clause), registration, passkey, native OIDC SSO and the
// hosted web-handoff login. Proving they share one state transition means
// driving all six against one store shape and stopping each of them at exactly
// the same place — the hop that carries the accepted session home.
//
// Two deliberate choices:
//
//   * **A scripted `APIClientProtocol`, not `MockURLProtocol`.** The handler slot
//     is process-global (D-09-13-A / issue #82) and Swift Testing parallelises
//     suites; this file adds no assignment to it, which is also why the
//     repository audit receipt does not move. The REAL `AuthService`, the real
//     `AuthStore` and the real wire DTOs are exercised — only the socket is
//     replaced.
//   * **A barrier, not a sleep.** `Phase09Gate` (09-06) parks a flow at a named
//     path and stays there until the test opens it, so "what was true while the
//     newer attempt was still working" is a sampled fact rather than a race.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    // MARK: - Scripted transport

    /// One canned response per path, with an optional barrier and an optional
    /// failure status. Every auth leg in `AuthService` is addressed by path, so
    /// the script is exhaustive without being ordered.
    final class Phase09AuthScriptedAPI: APIClientProtocol, @unchecked Sendable {
        struct Response: Sendable {
            var status: Int = 200
            var body: Data
            var message: String = "scripted failure"
            var gate: Phase09Gate?
        }

        private let lock = NSLock()
        private var responses: [String: Response] = [:]
        private var requested: [String] = []

        init() {}

        func script(_ path: String, _ response: Response) {
            lock.lock()
            defer { lock.unlock() }
            responses[path] = response
        }

        /// Every path this client was asked for, in call order.
        var requestedPaths: [String] {
            lock.lock()
            defer { lock.unlock() }
            return requested
        }

        /// Synchronous under the lock — a lock held across a suspension point is
        /// exactly what `NSLock`'s `noasync` annotation exists to prevent.
        private func take(_ path: String) -> Response? {
            lock.lock()
            defer { lock.unlock() }
            requested.append(path)
            return responses[path]
        }

        private func resolve(_ path: String) async throws -> Data {
            guard let response = take(path) else {
                throw HLError.unknown("Phase09AuthScriptedAPI has no script for \(path)")
            }
            if let gate = response.gate { await gate.wait() }
            guard response.status < 400 else {
                throw HLError.server(status: response.status, code: nil, message: response.message)
            }
            return response.body
        }

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            let body = try await resolve(request.path)
            if let envelope = try? JSONDecoder.hlDefault.decode(APIEnvelope<T>.self, from: body),
               let payload = envelope.data
            {
                return payload
            }
            return try JSONDecoder.hlDefault.decode(T.self, from: body)
        }

        func sendVoid(_ request: APIRequest<EmptyPayload>) async throws {
            _ = try await resolve(request.path)
        }

        func download(_ request: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            let body = try await resolve(request.path)
            let url = URL(string: "https://test.healthlog.local\(request.path)")!
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
    }

    // MARK: - Ceremony doubles

    /// Answers the WebAuthn ceremony without a system sheet, or throws the error
    /// the test wants classified (a user-cancelled sheet, typically).
    final class Phase09AuthStubPasskey: PasskeyServiceProtocol, @unchecked Sendable {
        private let assertionError: (any Error)?

        init(assertionError: (any Error)? = nil) {
            self.assertionError = assertionError
        }

        @MainActor func register(
            challenge _: String, rpId _: String, rpName _: String,
            userID _: String, userName _: String, displayName _: String,
            anchor _: ASPresentationAnchorProvider
        ) async throws -> PasskeyRegistration {
            throw HLError.unknown("passkey enrolment is not part of this contract")
        }

        @MainActor func assert(
            challenge _: String, rpId _: String, allowCredentialIDs _: [String],
            anchor _: ASPresentationAnchorProvider
        ) async throws -> PasskeyAssertion {
            if let assertionError { throw assertionError }
            return PasskeyAssertion(
                credentialID: "cred-convergence",
                clientDataJSON: "Y2Rq",
                authenticatorData: "YXV0aA",
                signature: "c2ln",
                userHandle: nil
            )
        }
    }

    /// The flow-agnostic web-auth driver both the SSO and the hosted web-login
    /// legs share in production. Its optional barrier is the *sheet* window —
    /// the one stretch of an authentication flow that deliberately holds no
    /// account boundary.
    @MainActor
    final class Phase09AuthStubWebAuthenticator: OidcAuthenticating {
        var outcome: OidcAuthOutcome
        var gate: Phase09Gate?
        private(set) var capturedLoginURL: URL?
        /// Consumed in order when present, so one store can host two overlapping
        /// web-auth attempts with different outcomes and different barriers —
        /// which is the only way to observe an older sheet finishing underneath
        /// a newer one.
        private var scripted: [(outcome: OidcAuthOutcome, gate: Phase09Gate?)] = []

        init(outcome: OidcAuthOutcome, gate: Phase09Gate? = nil) {
            self.outcome = outcome
            self.gate = gate
        }

        func enqueue(_ outcome: OidcAuthOutcome, gate: Phase09Gate? = nil) {
            scripted.append((outcome, gate))
        }

        func authenticate(
            loginURL: URL,
            callbackScheme _: String,
            anchor _: ASPresentationAnchorProvider
        ) async -> OidcAuthOutcome {
            capturedLoginURL = loginURL
            let leg = scripted.isEmpty ? (outcome: outcome, gate: gate) : scripted.removeFirst()
            if let barrier = leg.gate { await barrier.wait() }
            return leg.outcome
        }
    }

    @MainActor
    final class Phase09AuthStubAnchor: ASPresentationAnchorProvider {
        func anchor() -> ASPresentationAnchor {
            ASPresentationAnchor()
        }
    }

    // MARK: - Wire bodies

    enum Phase09AuthBody {
        /// The standard native `AccessRefreshBundle` every one of the six flows
        /// resolves to — byte-identical apart from the identity it names.
        static func bundle(userID: String) -> Data {
            Data("""
            {
              "data": {
                "user": { "id": "\(userID)", "username": "convergence" },
                "token": "hlk_bearer_\(userID)",
                "tokenExpiresAt": "2027-07-01T12:00:00Z",
                "refreshToken": "hlr_refresh_\(userID)",
                "refreshTokenExpiresAt": "2027-09-01T12:00:00Z"
              },
              "error": null
            }
            """.utf8)
        }

        /// `data: null` + `meta.mfaRequired` — password accepted, second factor
        /// still required.
        static let mfaChallenge = Data(#"""
        {
          "data": null,
          "error": null,
          "meta": { "mfaRequired": true, "mfaTicket": "tkt_convergence", "methods": ["totp", "webauthn"] }
        }
        """#.utf8)

        static let passkeyOptions = Data(#"""
        {
          "data": {
            "challengeId": "chal-passkey",
            "options": {
              "challenge": "Y2hhbGxlbmdl",
              "rpId": "test.healthlog.local",
              "allowCredentials": [],
              "userVerification": "preferred"
            }
          },
          "error": null
        }
        """#.utf8)

        static let mfaWebauthnOptions = Data(#"""
        {
          "data": {
            "challengeId": "chal-mfa-webauthn",
            "options": {
              "challenge": "Y2hhbGxlbmdl",
              "rpId": "test.healthlog.local",
              "allowCredentials": []
            }
          },
          "error": null
        }
        """#.utf8)

        static let accepted = Data(#"{"data":null,"error":null}"#.utf8)
    }

    /// In-memory Keychain that refuses exactly one key, so the five-field atomic
    /// persistence contract can be driven **through the store** without
    /// duplicating `AuthServicePersistAtomicTests`' service-level proof.
    final class Phase09AuthFailingKeychain: KeychainStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var store: [String: Data] = [:]
        private var refusedKey: String?

        init() {}

        func refuse(_ key: String?) {
            lock.lock()
            defer { lock.unlock() }
            refusedKey = key
        }

        func setString(_ value: String, forKey key: String) throws {
            guard let data = value.data(using: .utf8) else { throw KeychainError.encoding }
            try setData(data, forKey: key)
        }

        func getString(forKey key: String) -> String? {
            getData(forKey: key).flatMap { String(data: $0, encoding: .utf8) }
        }

        func setData(_ data: Data, forKey key: String) throws {
            lock.lock()
            defer { lock.unlock() }
            if refusedKey == key { throw KeychainError.osStatus(-25300) }
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

#endif // !SWIFT_PACKAGE
