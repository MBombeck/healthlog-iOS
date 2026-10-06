// J1 / 4 — "the assistant consent came back after a relaunch".
//
// The review walk (H3, 26.09.2026) saw the consent sheet again after Accept
// and no new `consent_receipts` row on the server. These tests drive the
// accept → relaunch → receipt path against the v1.39.2 server shapes:
// `GET /api/user/ai-provider` of the review account (provider
// `OPENAI_COMPATIBLE`, `aiAvailable: true`, `managedBy: "user"`),
// `GET /api/consent/ai/latest` (full keyspace incl. `ai_extraction`) and
// `POST /api/consent/ai` (`consentPostBody`: kind, artefact, signedAt+offset).

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @MainActor
    @Suite("AI consent accept survives a relaunch (J1)", .serialized, .mockURLSession)
    struct AIConsentAcceptRoundTripTests {
        private struct Call {
            let method: String
            let path: String
            let body: Data?
        }

        private final class Log: @unchecked Sendable {
            private let lock = NSLock()
            private var calls: [Call] = []
            func record(_ call: Call) {
                lock.lock()
                calls.append(call)
                lock.unlock()
            }

            var snapshot: [Call] {
                lock.lock()
                defer { lock.unlock() }
                return calls
            }
        }

        /// `GET /api/user/ai-provider` of the review account at v1.39.2.
        private static let reviewProviderPayload = Data(#"""
        {"provider":"OPENAI_COMPATIBLE","model":"gpt-5.6-sol","baseUrl":null,"aiAvailable":true,
         "managedBy":"user","hasAnthropicKey":false,"anthropicKeyPreview":null,"hasLocalKey":false,
         "hasOpenaiKey":false,"openaiKeyPreview":null,"compatBaseUrl":"https://openrouter.ai/api/v1",
         "compatModel":"gpt-5.6-sol","serverProviderHealth":"unknown","serverProviderConsent":false,
         "serverProviderOffer":false}
        """#.utf8)

        private nonisolated static func latest(aiFull: Bool) -> Data {
            let full = aiFull
                ? #"{"id":"r1","userId":"u1","kind":"ai_full","signedAt":"2026-08-08T12:00:00.000Z","revokedAt":null,"createdAt":"2026-08-08T12:00:00.000Z"}"#
                : "null"
            return Data(#"{"data":{"ai_full":\#(full),"ai_insights_only":null,"ai_coach":null,"ai_extraction":null}}"#.utf8)
        }

        private nonisolated static let minted = Data(#"""
        {"data":{"id":"r2","receipt":{"id":"r2","userId":"u1","kind":"ai_full","signedAt":"2026-09-26T18:00:00.000Z","revokedAt":null,"createdAt":"2026-09-26T18:00:00.000Z"}}}
        """#.utf8)

        private nonisolated static func body(of request: URLRequest) -> Data? {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            return data
        }

        private func makeContainer(_ keychain: KeychainStoring) -> AppContainer {
            AppContainer(
                environment: AppEnvironment(
                    baseURL: URL(string: "https://review.example.invalid"),
                    bundleID: "dev.healthlog.app.tests",
                    appVersion: "1.1.0",
                    buildNumber: "283"
                ),
                keychain: keychain,
                passkey: TestPasskeyService(),
                healthKit: MockHealthKitWriter()
            )
        }

        private func install(latestHasFull: Bool, mintStatus: Int, log: Log) {
            MockURLProtocol.install { req in
                let method = req.httpMethod ?? "GET"
                let path = req.url?.path ?? ""
                log.record(Call(method: method, path: path, body: Self.body(of: req)))
                let ok = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                switch (method, path) {
                case ("GET", "/api/consent/ai/latest"):
                    return (ok, Self.latest(aiFull: latestHasFull))
                case ("POST", "/api/consent/ai"):
                    let res = HTTPURLResponse(url: req.url!, statusCode: mintStatus, httpVersion: nil, headerFields: nil)!
                    return mintStatus == 200
                        ? (res, Self.minted)
                        : (res, Data(#"{"data":null,"error":"Too many consent requests, please wait a moment"}"#.utf8))
                default:
                    let missing = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                    return (missing, Data(#"{"data":null,"error":"not found"}"#.utf8))
                }
            }
        }

        /// The receipt client on the mock transport (the container's own
        /// client uses the default session).
        private func mockRepository() -> ConsentReceiptRepository {
            let env = AppEnvironment(
                baseURL: URL(string: "https://review.example.invalid")!,
                bundleID: "dev.healthlog.app.tests",
                appVersion: "1.1.0",
                buildNumber: "283"
            )
            return ConsentReceiptRepository(
                api: APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
            )
        }

        private func reviewConfig() throws -> AIProviderConfig {
            try JSONDecoder().decode(AIProviderConfig.self, from: Self.reviewProviderPayload)
        }

        @Test("review account: Accept grants the provider, a relaunch does not ask again")
        func acceptSurvivesRelaunch() async throws {
            let keychain = InMemoryKeychain()
            let config = try reviewConfig()
            #expect(config.aiConsentTarget == .provider(.openaiCompatible))

            let first = makeContainer(keychain)
            let request = try #require(
                AIConsentRequest.pending(config: config, consent: first.aiConsentStore, honourDecline: true),
                "a fresh install must ask"
            )
            #expect(request.provider == .openaiCompatible)
            #expect(!request.serverManaged)

            let log = Log()
            install(latestHasFull: false, mintStatus: 200, log: log)
            #expect(first.acceptAIConsent(request) == .granted)
            await first.syncServerAIConsentReceipt(repository: mockRepository())

            // The receipt went out in the v1.39.2 shape.
            let posts = log.snapshot.filter { $0.method == "POST" && $0.path == "/api/consent/ai" }
            #expect(posts.count == 1)
            let json = try #require(
                posts.first?.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            )
            #expect(json["kind"] as? String == "ai_full")
            #expect((json["artefact"] as? String)?.isEmpty == false)
            let signedAt = try #require(json["signedAt"] as? String)
            #expect(signedAt.hasSuffix("Z") || signedAt.contains("+"))

            // Relaunch: a new process reads the same Keychain.
            let relaunched = makeContainer(keychain)
            #expect(
                AIConsentRequest.pending(config: config, consent: relaunched.aiConsentStore, honourDecline: true) == nil,
                "the consent sheet came back after a relaunch"
            )
            #expect(relaunched.aiConsentStore.aiMode == .online)
        }

        @Test("a receipt already on file is not minted twice")
        func existingReceiptIsNotReminted() async {
            let keychain = InMemoryKeychain()
            let container = makeContainer(keychain)
            let log = Log()
            install(latestHasFull: true, mintStatus: 200, log: log)
            #expect(container.acceptAIConsent(AIConsentRequest(provider: .openaiCompatible)) == .granted)
            await container.syncServerAIConsentReceipt(repository: mockRepository())
            #expect(log.snapshot.map(\.path) == ["/api/consent/ai/latest"])
        }

        @Test("a refused receipt keeps the device grant: no second question")
        func refusedReceiptDoesNotLoop() async throws {
            let keychain = InMemoryKeychain()
            let config = try reviewConfig()
            let container = makeContainer(keychain)
            let log = Log()
            install(latestHasFull: false, mintStatus: 429, log: log)
            #expect(container.acceptAIConsent(AIConsentRequest(provider: .openaiCompatible)) == .granted)
            await container.syncServerAIConsentReceipt(repository: mockRepository())
            #expect(log.snapshot.contains { $0.method == "POST" && $0.path == "/api/consent/ai" })
            #expect(AIConsentRequest.pending(config: config, consent: container.aiConsentStore, honourDecline: true) == nil)
            let relaunched = makeContainer(keychain)
            #expect(AIConsentRequest.pending(config: config, consent: relaunched.aiConsentStore, honourDecline: true) == nil)
        }

        @Test("provider-opaque server AI: the server-managed scope survives a relaunch")
        func serverManagedSurvivesRelaunch() throws {
            let keychain = InMemoryKeychain()
            let config = AIProviderConfig(provider: "SOME_FUTURE_PROVIDER", aiAvailable: true, managedBy: "server")
            let first = makeContainer(keychain)
            let request = try #require(
                AIConsentRequest.pending(config: config, consent: first.aiConsentStore, honourDecline: true)
            )
            #expect(request.serverManaged)
            #expect(first.acceptAIConsent(request) == .granted)
            let relaunched = makeContainer(keychain)
            #expect(AIConsentRequest.pending(config: config, consent: relaunched.aiConsentStore, honourDecline: true) == nil)
        }

        @Test("no provider resolved: Accept grants nothing and the sheet stays")
        func noProviderGrantsNothing() {
            let container = makeContainer(InMemoryKeychain())
            #expect(container.acceptAIConsent(AIConsentRequest(provider: .unconfigured)) == .noProvider)
            #expect(!container.aiConsentStore.isAnyProviderGranted())
        }
    }

#endif
