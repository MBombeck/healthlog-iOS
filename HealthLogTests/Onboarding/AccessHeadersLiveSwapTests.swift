// swiftlint:disable force_unwrapping

// App-target symbols (`AppContainer`); the SPM test build skips the file.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// #153 (public #27, cnrd) — changed access headers must reach the very
    /// next request of a signed-in session, without relaunching the app.
    ///
    /// Until 1.5 the Settings screen stored the list and called
    /// `reloadEnvironment()`, which hands the whole environment to
    /// `APIClient.setEnvironment`. With an auth token in the Keychain that call was
    /// refused (and asserted in DEBUG), so the running client kept the headers it
    /// was launched with.
    @MainActor
    @Suite("Access headers apply without relaunch (#153)", .serialized, .mockURLSession)
    struct AccessHeadersLiveSwapTests {
        private static let owner = "user-153"

        private static func makeSignedInContainer(keychain: InMemoryKeychain) throws -> AppContainer {
            try keychain.setString(owner, forKey: KeychainKey.userID)
            try keychain.setString("token-153", forKey: KeychainKey.authToken)
            try keychain.setString("https://test.healthlog.local", forKey: KeychainKey.serverURL)
            let container = AppContainer(
                environment: AppEnvironment.resolve(keychain: keychain),
                keychain: keychain,
                passkey: TestPasskeyService(),
                healthKit: MockHealthKitWriter(),
                apiSessionConfiguration: .mock()
            )
            container.authStore.setPhaseForTesting(
                .authenticated(User(id: owner, email: nil, username: nil, displayName: nil, createdAt: .now))
            )
            return container
        }

        /// Captures the named header of every request that reaches the stub.
        private final class Captured: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [String?] = []

            func record(_ value: String?) {
                lock.lock()
                defer { lock.unlock() }
                values.append(value)
            }

            var last: String?? {
                lock.lock()
                defer { lock.unlock() }
                return values.last
            }
        }

        private static func installStub(capturing name: String, into captured: Captured) {
            MockURLProtocol.install { req in
                captured.record(req.value(forHTTPHeaderField: name))
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null}"#.utf8)
                )
            }
        }

        @Test("Settings path: saving while signed in changes the next request's header")
        func settingsSaveReachesNextRequest() async throws {
            let keychain = InMemoryKeychain()
            try ServerAccessHeaders.save([ServerAccessHeader(name: "X-Proxy-Key", value: "old")], keychain: keychain)
            let container = try Self.makeSignedInContainer(keychain: keychain)
            let captured = Captured()
            Self.installStub(capturing: "X-Proxy-Key", into: captured)
            let api = try #require(container.api as? APIClient)

            _ = try? await api.send(APIRequest<EmptyPayload>.get("/api/x"))
            #expect(captured.last == "old")

            // What `ServerAccessHeadersScreen.save()` does on Save.
            try ServerAccessHeaders.save([ServerAccessHeader(name: "X-Proxy-Key", value: "new")], keychain: keychain)
            _HLAPIClientTestHook.suppressAssertion = true
            defer { _HLAPIClientTestHook.suppressAssertion = false }
            await container.reloadEnvironment()

            _ = try? await api.send(APIRequest<EmptyPayload>.get("/api/x"))
            #expect(captured.last == "new", "the next request must carry the new value without a relaunch")
        }

        @Test("saveAccessHeaders: signed in, the next API call and both probes carry the new value")
        func containerPathReachesEveryServerRequest() async throws {
            let keychain = InMemoryKeychain()
            try ServerAccessHeaders.save([ServerAccessHeader(name: "X-Proxy-Key", value: "old")], keychain: keychain)
            let container = try Self.makeSignedInContainer(keychain: keychain)
            let captured = Captured()
            Self.installStub(capturing: "X-Proxy-Key", into: captured)
            let api = try #require(container.api as? APIClient)

            // No test hook: the swap must not hit the M-2 assertion at all.
            let stored = try await container.saveAccessHeaders([ServerAccessHeader(name: " X-Proxy-Key ", value: "new")])
            #expect(stored == [ServerAccessHeader(name: "X-Proxy-Key", value: "new")])

            _ = try? await api.send(APIRequest<EmptyPayload>.get("/api/x"))
            #expect(captured.last == "new")
            _ = await api.probeHealth()
            #expect(captured.last == "new", "the health probe reads the headers from the client")
            _ = await api.probeWebLoginRoute(codeChallenge: "challenge")
            #expect(captured.last == "new", "the web-login probe reads the headers from the client")
            #expect(container.environment.accessHeaders == [ServerAccessHeader(name: "X-Proxy-Key", value: "new")])
            #expect(ServerAccessHeaders.load(keychain: keychain) == stored)
            #expect(await api.environment.baseURL?.host == "test.healthlog.local", "a header edit is never a host change")
        }

        @Test("saveAccessHeaders: an empty list removes the headers from the next request")
        func clearingReachesNextRequest() async throws {
            let keychain = InMemoryKeychain()
            try ServerAccessHeaders.save([ServerAccessHeader(name: "X-Proxy-Key", value: "old")], keychain: keychain)
            let container = try Self.makeSignedInContainer(keychain: keychain)
            let captured = Captured()
            Self.installStub(capturing: "X-Proxy-Key", into: captured)
            let api = try #require(container.api as? APIClient)

            try await container.saveAccessHeaders([])
            _ = try? await api.send(APIRequest<EmptyPayload>.get("/api/x"))
            #expect(captured.last == .some(nil))
            #expect(keychain.getString(forKey: KeychainKey.serverAccessHeaders) == nil)
        }

        @Test("saveAccessHeaders: an invalid list changes nothing")
        func invalidListChangesNothing() async throws {
            let keychain = InMemoryKeychain()
            try ServerAccessHeaders.save([ServerAccessHeader(name: "X-Proxy-Key", value: "old")], keychain: keychain)
            let container = try Self.makeSignedInContainer(keychain: keychain)
            let captured = Captured()
            Self.installStub(capturing: "X-Proxy-Key", into: captured)
            let api = try #require(container.api as? APIClient)

            await #expect(throws: ServerAccessHeaders.ValidationError.reservedName(index: 0)) {
                try await container.saveAccessHeaders([ServerAccessHeader(name: "Origin", value: "https://evil.example")])
            }
            _ = try? await api.send(APIRequest<EmptyPayload>.get("/api/x"))
            #expect(captured.last == "old")
        }

        /// (f) — rule 11: the update path. 1.4.1 stored the list as JSON under
        /// the same Keychain key; 1.5 reads it unchanged at launch and sends it.
        /// An entry 1.4.1 still accepted but 1.5 reserves (`Origin`) is left
        /// out without taking the Cloudflare pair down with it.
        @Test("Update from 1.4.1: stored headers keep working, a stored Origin is left out")
        func headersFrom141KeepWorking() async throws {
            let keychain = InMemoryKeychain()
            // Byte for byte what 1.4.1's `ServerAccessHeaders.save` wrote.
            let stored141 = #"[{"name":"CF-Access-Client-Id","value":"id-141.access"},"#
                + #"{"name":"CF-Access-Client-Secret","value":"secret-141"},"#
                + #"{"name":"Origin","value":"https:\/\/health.example.com"}]"#
            try keychain.setString(stored141, forKey: KeychainKey.serverAccessHeaders)
            let container = try Self.makeSignedInContainer(keychain: keychain)
            nonisolated(unsafe) var seen: [String: String] = [:]
            MockURLProtocol.install { req in
                for name in ["CF-Access-Client-Id", "CF-Access-Client-Secret", "Origin"] {
                    seen[name] = req.value(forHTTPHeaderField: name)
                }
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null}"#.utf8)
                )
            }
            let api = try #require(container.api as? APIClient)

            _ = try? await api.send(APIRequest<EmptyPayload>.get("/api/x"))
            #expect(seen["CF-Access-Client-Id"] == "id-141.access")
            #expect(seen["CF-Access-Client-Secret"] == "secret-141")
            #expect(seen["Origin"] == nil)
            // Settings and the onboarding draft read the same list.
            #expect(ServerAccessHeaders.load(keychain: keychain).map(\.name) == ["CF-Access-Client-Id", "CF-Access-Client-Secret"])
            // Untouched until the user saves: the stored bytes are still 1.4.1's.
            #expect(keychain.getString(forKey: KeychainKey.serverAccessHeaders) == stored141)
        }
    }

#endif
