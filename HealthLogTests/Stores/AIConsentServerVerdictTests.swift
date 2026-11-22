// Server v1.43.2: AI consent only on an explicit Accept.
//
// `POST /api/consent/ai` requires `"confirm": true` (else 400
// `consent.ai.confirmRequired`, nothing written). The standing consent is read
// from `ai.consent` on `GET /api/auth/me` (`AiConsentState`: `status`
// given/needed/not_needed, `since`, `recipients[{via, name}]`). Fixtures follow
// `docs/api/openapi.yaml` on the server tag `v1.43.2` (`59f910df5`).

// swiftlint:disable force_unwrapping file_length

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @MainActor
    @Suite("AI consent follows the server verdict (#143)", .serialized, .mockURLSession)
    struct AIConsentServerVerdictTests {
        // MARK: - Wire recorder

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

            /// Every request to the consent family.
            var consentCalls: [Call] {
                snapshot.filter { $0.path.hasPrefix("/api/consent/ai") }
            }

            var posts: [Call] {
                consentCalls.filter { $0.method == "POST" }
            }
        }

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

        // MARK: - v1.43.2 fixtures

        /// `ai.consent` in each state the schema allows.
        private nonisolated static let consentNeeded = """
        {"status":"needed","since":null,"recipients":[{"via":"operator_key","name":"OpenAI"},\
        {"via":"operator_chatgpt","name":"ChatGPT (OpenAI)"}]}
        """
        private nonisolated static let consentGiven = """
        {"status":"given","since":"2026-10-12T08:30:00.000Z","recipients":[{"via":"operator_key","name":"Anthropic"}]}
        """
        private nonisolated static let consentNotNeeded = #"{"status":"not_needed","since":null,"recipients":[]}"#

        /// An `AiUsageState` (v1.43), to prove a usage update keeps `consent`.
        private nonisolated static let usageJSON = """
        {"level":"standard","preference":null,"defaultLevel":"standard","maxLevel":"full","source":"default",\
        "options":[{"level":"standard","allowed":true,"estimatedTokensPerDay":4800}],\
        "measuredTokensPerDay":null,"measuredDays":0}
        """

        /// An `AiAccountBlock` (capabilities, provider, consent required).
        private nonisolated static func aiBlock(consent: String?, managedBy: String = "server") -> String {
            let reason = consent == consentNeeded ? #""consent_required""# : "null"
            let available = consent == consentNeeded ? "false" : "true"
            let consentField = consent.map { #","consent":\#($0)"# } ?? ""
            return """
            {"capabilities":{"coach":{"available":\(available),"reason":\(reason),"onDeviceAllowed":true},\
            "briefing":{"available":\(available),"reason":\(reason),"onDeviceAllowed":true}},\
            "provider":{"configured":true,"managedBy":"\(managedBy)","canConfigure":true,"responseTimeoutMs":60000}\
            \(consentField)}
            """
        }

        private nonisolated static func me(consent: String?) -> Data {
            Data(#"{"id":"u1","modules":{},"moduleAccess":{},"ai":\#(aiBlock(consent: consent))}"#.utf8)
        }

        private nonisolated static func latest(aiFull: Bool) -> Data {
            let full = aiFull
                ? #"{"id":"r1","userId":"u1","kind":"ai_full","signedAt":"2026-08-08T12:00:00.000Z","revokedAt":null,"createdAt":"2026-08-08T12:00:00.000Z"}"#
                : "null"
            return Data(#"{"data":{"ai_full":\#(full),"ai_insights_only":null,"ai_coach":null,"ai_extraction":null}}"#.utf8)
        }

        private nonisolated static let minted = Data(#"""
        {"data":{"id":"r2","receipt":{"id":"r2","userId":"u1","kind":"ai_full","signedAt":"2026-10-17T09:00:00.000Z","revokedAt":null,"createdAt":"2026-10-17T09:00:00.000Z"}}}
        """#.utf8)

        /// The 400 a v1.43.2 server answers a POST without `confirm: true`.
        private nonisolated static let confirmRequired = Data(#"""
        {"data":null,"error":"Consent is recorded only from an explicit confirmation","meta":{"errorCode":"consent.ai.confirmRequired","requestId":"req-143"}}
        """#.utf8)

        /// A v1.43.2 server: a POST without `confirm: true` writes nothing and
        /// answers 400; with it, mints. `meConsent` is what `/api/auth/me` reports.
        private func installServer(meConsent: String?, latestHasFull: Bool = false, log: Log) {
            MockURLProtocol.install { req in
                let method = req.httpMethod ?? "GET"
                let path = req.url?.path ?? ""
                let body = Self.body(of: req)
                log.record(Call(method: method, path: path, body: body))
                func reply(_ status: Int, _ data: Data) -> (HTTPURLResponse, Data) {
                    (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, data)
                }
                switch (method, path) {
                case ("GET", "/api/auth/me"):
                    return reply(200, Self.me(consent: meConsent))
                case ("GET", "/api/consent/ai/latest"):
                    return reply(200, Self.latest(aiFull: latestHasFull))
                case ("POST", "/api/consent/ai"):
                    let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    guard json?["confirm"] as? Bool == true else { return reply(400, Self.confirmRequired) }
                    return reply(200, Self.minted)
                default:
                    return reply(404, Data(#"{"data":null,"error":"not found"}"#.utf8))
                }
            }
        }

        private func makeContainer(_ keychain: KeychainStoring = InMemoryKeychain()) -> AppContainer {
            AppContainer(
                environment: AppEnvironment(
                    baseURL: URL(string: "https://test.healthlog.local"),
                    bundleID: "dev.healthlog.app.tests",
                    appVersion: "1.3.0",
                    buildNumber: "296"
                ),
                keychain: keychain,
                passkey: TestPasskeyService(),
                healthKit: MockHealthKitWriter(),
                apiSessionConfiguration: .mock()
            )
        }

        private func block(_ consent: String?) throws -> AIAccountBlock {
            try JSONDecoder.hlDefault.decode(AIAccountBlock.self, from: Data(Self.aiBlock(consent: consent).utf8))
        }

        private func serverManagedConfig() -> AIProviderConfig {
            AIProviderConfig(provider: nil, aiAvailable: true, managedBy: "server")
        }

        /// Lets the container's own start-up traffic settle before a test reads
        /// the wire log, so a late request is not misread as the test's own.
        private func settle() async {
            for _ in 0 ..< 5 {
                await Task.yield()
            }
        }

        // MARK: - Decoding `ai.consent`

        @Test("ai.consent decodes all three states with since and recipients")
        func decodesStandingConsent() throws {
            let needed = try #require(try block(Self.consentNeeded).consent)
            #expect(needed.verdict == .needed)
            #expect(needed.since == nil)
            #expect(needed.recipients == [
                AIConsentRecipient(via: .operatorKey, name: "OpenAI"),
                AIConsentRecipient(via: .operatorChatGPT, name: "ChatGPT (OpenAI)")
            ])
            #expect(needed.recipientNames == ["OpenAI", "ChatGPT (OpenAI)"])

            let given = try #require(try block(Self.consentGiven).consent)
            #expect(given.verdict == .given)
            #expect(given.since == Date(timeIntervalSince1970: 1_791_793_800))

            let notNeeded = try #require(try block(Self.consentNotNeeded).consent)
            #expect(notNeeded.verdict == .notNeeded)
            #expect(notNeeded.recipients.isEmpty)
        }

        @Test("tolerant: unknown status is no verdict, a broken recipient drops alone, a broken block keeps the rest")
        func decodesTolerantly() throws {
            let future = try #require(try block(#"{"status":"pending_review","since":null,"recipients":[]}"#).consent)
            #expect(future.status == .unknown)
            #expect(future.verdict == nil)

            let lossy = try #require(try block("""
            {"status":"needed","since":"not a date","recipients":[{"via":"operator_key","name":"OpenAI"},\
            {"via":"operator_key"},{"via":"operator_relay","name":"llm.example.org"},{"via":"operator_key","name":"OpenAI"}]}
            """).consent)
            #expect(lossy.since == nil)
            #expect(lossy.recipients.count == 3)
            #expect(lossy.recipients[1].via == .unknown)
            #expect(lossy.recipientNames == ["OpenAI", "llm.example.org"])

            let broken = try block(#"{"status":42}"#)
            #expect(broken.consent == nil)
            #expect(broken.state(.coach).available)

            let older = try block(nil)
            #expect(older.consent == nil)
        }

        @Test("the gate exposes the verdict; an unknown status and an older server read as none")
        func gateExposesVerdict() throws {
            let gate = AICapabilityGate()
            #expect(gate.standingConsent == nil)
            try gate.apply(block(Self.consentNeeded))
            #expect(gate.standingConsent?.verdict == .needed)
            try gate.apply(block(#"{"status":"pending_review","since":null,"recipients":[]}"#))
            #expect(gate.standingConsent == nil)
            try gate.apply(block(nil))
            #expect(gate.standingConsent == nil)
            let usage = try JSONDecoder.hlDefault.decode(AIUsageState.self, from: Data(Self.usageJSON.utf8))
            try gate.apply(block(Self.consentGiven).replacingUsage(usage))
            #expect(gate.standingConsent?.verdict == .given, "a usage update must not drop the consent block")
        }

        // MARK: - Status mapping: when the sheet asks, and what it names

        @Test("needed asks and carries the recipients; given with a local grant does not ask")
        func neededAsksWithRecipients() throws {
            installServer(meConsent: nil, log: Log())
            let container = makeContainer()
            let standing = try #require(try block(Self.consentNeeded).consent)
            let request = try #require(AIConsentRequest.pending(
                config: serverManagedConfig(),
                consent: container.aiConsentStore,
                honourDecline: true,
                standing: standing
            ))
            #expect(request.serverManaged)
            #expect(request.recipients == ["OpenAI", "ChatGPT (OpenAI)"])

            container.aiConsentStore.grantServerManaged()
            let given = try #require(try block(Self.consentGiven).consent)
            #expect(AIConsentRequest.pending(
                config: serverManagedConfig(), consent: container.aiConsentStore, honourDecline: true, standing: given
            ) == nil)
        }

        @Test("not_needed never raises the sheet by itself; the explicit prompt still can, without recipients")
        func notNeededDoesNotAsk() throws {
            installServer(meConsent: nil, log: Log())
            let container = makeContainer()
            let standing = try #require(try block(Self.consentNotNeeded).consent)
            let config = AIProviderConfig(provider: "ANTHROPIC", aiAvailable: true, managedBy: "user")
            #expect(AIConsentRequest.pending(
                config: config, consent: container.aiConsentStore, honourDecline: true, standing: standing
            ) == nil)
            let explicit = try #require(AIConsentRequest.pending(
                config: config, consent: container.aiConsentStore, honourDecline: false, standing: standing
            ))
            #expect(explicit.recipients.isEmpty)
        }

        @Test("older server (no ai.consent): the sheet asks exactly as before")
        func olderServerAsksAsBefore() {
            installServer(meConsent: nil, log: Log())
            let container = makeContainer()
            let config = AIProviderConfig(provider: "ANTHROPIC", aiAvailable: true, managedBy: "user")
            let request = AIConsentRequest.pending(config: config, consent: container.aiConsentStore, honourDecline: true)
            #expect(request == AIConsentRequest(provider: .anthropic))
        }

        @Test("the sheet names the recipients in de and en")
        func recipientsText() {
            let names = ["OpenAI", "Anthropic"]
            for (locale, expectFragment) in [("de", "an OpenAI und Anthropic weiter"), ("en", "to OpenAI and Anthropic to")] {
                let bundle = Self.bundle(for: locale)
                let list = names.formatted(.list(type: .and).locale(Locale(identifier: locale)))
                let forwarded = String(
                    format: bundle.localizedString(forKey: "consent.recipients.forwarded", value: nil, table: nil),
                    list
                )
                let bullet = String(
                    format: bundle.localizedString(forKey: "consent.recipients.bullet", value: nil, table: nil),
                    list
                )
                #expect(forwarded.contains(expectFragment), "\(locale): \(forwarded)")
                #expect(bullet.hasPrefix(list), "\(locale): \(bullet)")
                for mark in ["\u{00B7}", "\u{2014}", "\u{2013}", "\u{2192}", "%@"] {
                    #expect(!forwarded.contains(mark) && !bullet.contains(mark), "\(locale) carries \(mark)")
                }
            }
        }

        private static func bundle(for locale: String) -> Bundle {
            let main = Bundle(for: AppContainer.self)
            guard let path = main.path(forResource: locale, ofType: "lproj"), let bundle = Bundle(path: path) else {
                return main
            }
            return bundle
        }
    }

    // MARK: - Read-only paths: launch, shell mount, Coach

    extension AIConsentServerVerdictTests {
        @Test("launch / shell mount with a local grant and a receipt-less server sends nothing")
        func mountSendsNothing() async {
            let log = Log()
            installServer(meConsent: Self.consentGiven, latestHasFull: false, log: log)
            let container = makeContainer()
            container.aiConsentStore.grantServerManaged()
            await container.moduleGate.load()
            // The shell `.task` and the `standingConsent` change handler.
            container.reconcileAIConsentWithServer()
            _ = AIConsentRequest.pending(
                config: serverManagedConfig(), consent: container.aiConsentStore, honourDecline: true,
                standing: container.aiCapabilityGate.standingConsent
            )
            await settle()
            #expect(log.consentCalls.isEmpty, "the mount touched the consent routes: \(log.consentCalls.map(\.path))")
            #expect(container.aiConsentStore.hasServerManagedConsent(), "given keeps the device grant")
        }

        @Test("older server (no ai.consent): the mount sends nothing either")
        func olderServerMountSendsNothing() async {
            let log = Log()
            installServer(meConsent: nil, latestHasFull: false, log: log)
            let container = makeContainer()
            container.aiConsentStore.grant(for: .anthropic)
            await container.moduleGate.load()
            #expect(container.aiCapabilityGate.standingConsent == nil)
            #expect(!container.reconcileAIConsentWithServer())
            await settle()
            #expect(log.consentCalls.isEmpty)
            #expect(container.aiConsentStore.hasConsent(for: .anthropic))
        }

        // MARK: - Withdrawn on the web / update path

        @Test("withdrawn on the web: the local grant is set aside, the sheet asks once, nothing is minted")
        func withdrawnOnWebAsksOnce() async throws {
            let log = Log()
            installServer(meConsent: Self.consentNeeded, log: log)
            let keychain = InMemoryKeychain()
            // An install from 1.2.0: the device holds the grant the old launch
            // sync used to turn into a receipt.
            let container = makeContainer(keychain)
            container.aiConsentStore.grantServerManaged()
            #expect(container.aiConsentStore.aiMode == .online)

            await container.moduleGate.load()
            #expect(container.aiCapabilityGate.standingConsent?.verdict == .needed)
            #expect(container.reconcileAIConsentWithServer())
            #expect(!container.aiConsentStore.hasServerManagedConsent(), "local state follows the server")
            #expect(container.aiConsentStore.isOnlineIntentPending, "the choice stays visible as pending")

            let request = try #require(AIConsentRequest.pending(
                config: serverManagedConfig(), consent: container.aiConsentStore, honourDecline: true,
                standing: container.aiCapabilityGate.standingConsent
            ), "the sheet must ask once")
            #expect(request.recipients == ["OpenAI", "ChatGPT (OpenAI)"])
            await settle()
            #expect(log.posts.isEmpty, "a withdrawn consent was re-created without a tap")

            // Declined: never asked again by itself, and nothing goes out.
            container.aiConsentStore.declineServerManaged()
            #expect(!container.reconcileAIConsentWithServer())
            #expect(AIConsentRequest.pending(
                config: serverManagedConfig(), consent: container.aiConsentStore, honourDecline: true,
                standing: container.aiCapabilityGate.standingConsent
            ) == nil)
            let relaunched = makeContainer(keychain)
            try relaunched.aiCapabilityGate.apply(block(Self.consentNeeded))
            #expect(!relaunched.reconcileAIConsentWithServer())
            #expect(AIConsentRequest.pending(
                config: serverManagedConfig(), consent: relaunched.aiConsentStore, honourDecline: true,
                standing: relaunched.aiCapabilityGate.standingConsent
            ) == nil)
            await settle()
            #expect(log.posts.isEmpty)
        }

        @Test("a BYO-key grant is never set aside by the server verdict")
        func byoGrantUntouched() throws {
            installServer(meConsent: nil, log: Log())
            let container = makeContainer()
            container.aiConsentStore.grantBYO(for: .anthropic)
            try container.aiCapabilityGate.apply(block(Self.consentNeeded))
            #expect(!container.reconcileAIConsentWithServer())
            #expect(container.aiConsentStore.aiMode == .byoKey)
        }

        // MARK: - The Accept tap

        @Test("needed: the Accept tap sends confirm:true exactly once, then re-reads the verdict")
        func acceptSendsConfirmOnce() async throws {
            let log = Log()
            installServer(meConsent: Self.consentNeeded, log: log)
            let container = makeContainer()
            await container.moduleGate.load()
            let request = try #require(AIConsentRequest.pending(
                config: serverManagedConfig(), consent: container.aiConsentStore, honourDecline: true,
                standing: container.aiCapabilityGate.standingConsent
            ))
            #expect(container.acceptAIConsent(request) == .granted)
            var refreshed = 0
            let outcome = await container.recordAcceptedAIConsent(refresh: { refreshed += 1 })
            #expect(outcome == .recorded)
            #expect(refreshed == 1)
            let posts = log.posts
            #expect(posts.count == 1)
            #expect(!log.consentCalls.contains { $0.method == "GET" }, "needed skips the receipt read")
            let json = try #require(posts.first?.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
            #expect(json["confirm"] as? Bool == true)
            #expect(json["kind"] as? String == "ai_full")
            #expect((json["artefact"] as? String)?.contains("server_managed") == true)
            let signedAt = try #require(json["signedAt"] as? String)
            #expect(signedAt.hasSuffix("Z") || signedAt.contains("+"))
        }

        @Test("not_needed (own provider): Accept grants on the device and sends nothing")
        func acceptNotNeededSendsNothing() async {
            let log = Log()
            installServer(meConsent: Self.consentNotNeeded, log: log)
            let container = makeContainer()
            await container.moduleGate.load()
            #expect(container.acceptAIConsent(AIConsentRequest(provider: .anthropic)) == .granted)
            let outcome = await container.recordAcceptedAIConsent(refresh: {})
            #expect(outcome == .notNeeded)
            await settle()
            #expect(log.consentCalls.isEmpty)
            #expect(container.aiConsentStore.hasConsent(for: .anthropic))
        }

        @Test("given: Accept sends nothing")
        func acceptGivenSendsNothing() async {
            let log = Log()
            installServer(meConsent: Self.consentGiven, log: log)
            let container = makeContainer()
            await container.moduleGate.load()
            #expect(container.acceptAIConsent(AIConsentRequest(provider: .unconfigured, serverManaged: true)) == .granted)
            #expect(await container.recordAcceptedAIConsent(refresh: {}) == .alreadyOnFile)
            await settle()
            #expect(log.consentCalls.isEmpty)
        }

        @Test("older server: Accept reads the receipt and mints once with confirm:true")
        func acceptOlderServer() async throws {
            let log = Log()
            installServer(meConsent: nil, latestHasFull: false, log: log)
            let container = makeContainer()
            await container.moduleGate.load()
            #expect(container.acceptAIConsent(AIConsentRequest(provider: .anthropic)) == .granted)
            #expect(await container.recordAcceptedAIConsent(refresh: {}) == .recorded)
            #expect(log.consentCalls.map(\.method) == ["GET", "POST"])
            let json = try #require(log.posts.first?.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
            #expect(json["confirm"] as? Bool == true)
        }

        @Test("older server with a receipt on file: Accept sends no POST")
        func acceptOlderServerReceiptOnFile() async {
            let log = Log()
            installServer(meConsent: nil, latestHasFull: true, log: log)
            let container = makeContainer()
            await container.moduleGate.load()
            #expect(container.acceptAIConsent(AIConsentRequest(provider: .anthropic)) == .granted)
            #expect(await container.recordAcceptedAIConsent(refresh: {}) == .alreadyOnFile)
            #expect(log.posts.isEmpty)
        }

        @Test("no device grant (Keychain refused): nothing is sent")
        func noGrantSendsNothing() async {
            let log = Log()
            installServer(meConsent: Self.consentNeeded, log: log)
            let container = makeContainer()
            await container.moduleGate.load()
            #expect(await container.recordAcceptedAIConsent(refresh: {}) == .noGrant)
            await settle()
            #expect(log.consentCalls.isEmpty)
        }

        // MARK: - 400 consent.ai.confirmRequired

        @Test("400 consent.ai.confirmRequired reads as needs-explicit-consent, never as an error")
        func confirmRequiredIsNotAnError() async {
            let log = Log()
            MockURLProtocol.install { req in
                log.record(Call(method: req.httpMethod ?? "GET", path: req.url?.path ?? "", body: Self.body(of: req)))
                if req.url?.path == "/api/consent/ai" {
                    return (HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Self.confirmRequired)
                }
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Self.me(consent: Self.consentNeeded)
                )
            }
            let container = makeContainer()
            await container.moduleGate.load()
            #expect(container.acceptAIConsent(AIConsentRequest(provider: .unconfigured, serverManaged: true)) == .granted)
            var refreshed = 0
            let outcome = await container.recordAcceptedAIConsent(refresh: { refreshed += 1 })
            #expect(outcome == .needsExplicitConsent)
            #expect(refreshed == 1, "the verdict is re-read from /api/auth/me")
            #expect(log.posts.count == 1, "no retry loop")
            #expect(ConsentReceiptRepository.isConfirmRequired(
                .server(status: 400, code: "consent.ai.confirmRequired", message: "")
            ))
            #expect(!ConsentReceiptRepository.isConfirmRequired(.server(status: 400, code: nil, message: "")))
            #expect(!ConsentReceiptRepository.isConfirmRequired(
                .server(status: 403, code: "consent.ai.confirmRequired", message: "")
            ))
        }

        // MARK: - Tree-wide: only the Accept tap sends a receipt

        // Consent may only be recorded from an explicit tap; a new call site anywhere
        // in the app would mint a receipt the user never gave, which no unit test sees.

        @Test("only the two Accept closures call recordAcceptedAIConsent; nothing else mints")
        func onlyAcceptTapsMint() throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // Stores
                .deletingLastPathComponent() // HealthLogTests
                .deletingLastPathComponent() // <repo>
                .appendingPathComponent("HealthLog")
            var hits: [String: [String]] = [:]
            let needles = [
                "recordAcceptedAIConsent(",
                ".recordAcceptedConsent(",
                "mintFullConsentReceipt(",
                "\"/api/consent/ai\"",
                "/api/consent/ai/web"
            ]
            let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in files where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                for line in text.components(separatedBy: .newlines) {
                    let code = line.trimmingCharacters(in: .whitespaces)
                    guard !code.hasPrefix("//") else { continue }
                    for needle in needles where code.contains(needle) {
                        hits[needle, default: []].append(url.lastPathComponent)
                    }
                }
            }
            #expect(hits["recordAcceptedAIConsent("]?.sorted() == [
                "AppContainer+AIConsentGate.swift", // the declaration
                "AskCoachSheet+ServerFallback.swift", // Coach Accept, server-managed
                "AskCoachSheet+ServerFallback.swift", // Coach Accept, provider
                "AuthenticatedShell.swift" // shell Accept
            ])
            #expect(hits[".recordAcceptedConsent("] == ["AppContainer+AIConsentGate.swift"])
            #expect(Set(hits["mintFullConsentReceipt("] ?? []) == ["ConsentReceiptRepository.swift"])
            #expect(hits["\"/api/consent/ai\""] == ["ConsentReceiptRepository.swift"])
            #expect(hits["/api/consent/ai/web"] == nil)
        }
    }

#endif
