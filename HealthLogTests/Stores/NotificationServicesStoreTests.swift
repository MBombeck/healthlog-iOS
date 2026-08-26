import Foundation
@testable import HealthLog
import Testing

/// Decode + behaviour locks for the ntfy / Telegram notification-channel
/// settings surface (`NotificationServicesRepository` +
/// `NotificationServicesStore`), plus a secret-redaction guard.
///
/// What this suite pins:
/// 1. `NotificationServicesRepository` decodes the verbatim server shapes from
///    the v1.x `/api/settings/ntfy|telegram|global-services` routes — schema
///    drift surfaces here, not as a silent "channel missing" in Settings.
/// 2. `NotificationServicesStore` gates the cards on the server-wide flags and
///    walks load → save → test correctly, reverting nothing it shouldn't.
/// 3. The Telegram `botToken` (write-only secret) and ntfy `authToken` are
///    redacted by `LogSanitizer` if they ever reach a log line.
@MainActor
@Suite("NotificationServices")
struct NotificationServicesStoreTests {
    // MARK: - Stub APIClient

    /// Handler-based stub mirroring `WhoopIntegrationStoreTests` — each typed
    /// `send`/`sendVoid` routes through a closure, capturing PUT/POST bodies.
    private final class StubAPIClient: APIClientProtocol, @unchecked Sendable {
        var sendHandler: (@Sendable (any Sendable) async throws -> any Sendable)?
        var voidHandler: (@Sendable (APIRequest<EmptyPayload>) async throws -> Void)?

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            guard let handler = sendHandler else { throw HLError.unknown("no handler") }
            let result = try await handler(request)
            guard let typed = result as? T else {
                throw HLError.decoding("type mismatch — got \(type(of: result)), expected \(T.self)")
            }
            return typed
        }

        func sendVoid(_ request: APIRequest<EmptyPayload>) async throws {
            try await voidHandler?(request)
        }

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.canceled
        }
    }

    @MainActor
    private final class Capture {
        var globals = GlobalServicesFlags.allEnabled
        var ntfy = NtfyConfig.empty
        var telegram = TelegramConfig.empty
        var ntfyTest = NotificationChannelTestResult(sent: true)
        var telegramTest = NotificationChannelTestResult(sent: true)
        var putBodies: [(path: String, body: Data)] = []
        var voidPaths: [String] = []
        var errorOnNextSend: HLError?
        var errorOnNextVoid: HLError?

        func sendHandler() -> @Sendable (any Sendable) async throws -> any Sendable {
            { req in
                if let err = await self.takeSendError() { throw err }
                switch req {
                case is APIRequest<GlobalServicesFlags>: return await self.globals
                case is APIRequest<NtfyConfig>: return await self.ntfy
                case is APIRequest<TelegramConfig>: return await self.telegram
                case let r as APIRequest<NotificationChannelTestResult>:
                    return await r.path.contains("telegram") ? self.telegramTest : self.ntfyTest
                default:
                    throw HLError.unknown("unexpected shape: \(type(of: req))")
                }
            }
        }

        func voidHandler() -> @Sendable (APIRequest<EmptyPayload>) async throws -> Void {
            { req in
                if let err = await self.takeVoidError() { throw err }
                await self.recordVoid(path: req.path, body: req.body)
            }
        }

        func recordVoid(path: String, body: Data?) {
            voidPaths.append(path)
            if let body { putBodies.append((path, body)) }
        }

        func takeSendError() -> HLError? {
            defer { errorOnNextSend = nil }
            return errorOnNextSend
        }

        func takeVoidError() -> HLError? {
            defer { errorOnNextVoid = nil }
            return errorOnNextVoid
        }
    }

    private func makeStore() -> (NotificationServicesStore, Capture) {
        let stub = StubAPIClient()
        let capture = Capture()
        stub.sendHandler = capture.sendHandler()
        stub.voidHandler = capture.voidHandler()
        let repo = NotificationServicesRepository(api: stub)
        return (NotificationServicesStore(repo: repo), capture)
    }

    // MARK: - Decode locks (verbatim server shapes)

    @Test("ntfy GET shape decodes incl. hasAuthToken")
    func decodeNtfy() throws {
        let json = Data(#"""
        { "enabled": true, "serverUrl": "https://ntfy.example.com", "topic": "hl", "hasAuthToken": true }
        """#.utf8)
        let decoded = try JSONDecoder.hlDefault.decode(NtfyConfig.self, from: json)
        #expect(decoded.enabled == true)
        #expect(decoded.serverUrl == "https://ntfy.example.com")
        #expect(decoded.topic == "hl")
        #expect(decoded.hasAuthToken == true)
    }

    @Test("ntfy empty-channel GET shape (defaults)")
    func decodeNtfyDefault() throws {
        let json = Data(#"{ "enabled": false, "serverUrl": "https://ntfy.sh", "topic": "", "hasAuthToken": false }"#.utf8)
        let decoded = try JSONDecoder.hlDefault.decode(NtfyConfig.self, from: json)
        #expect(decoded.enabled == false)
        #expect(decoded.serverUrl == "https://ntfy.sh")
        #expect(decoded.hasAuthToken == false)
    }

    @Test("telegram GET shape decodes — token never present, only hasBotToken")
    func decodeTelegram() throws {
        let json = Data(#"{ "enabled": true, "hasBotToken": true, "chatId": "987654321" }"#.utf8)
        let decoded = try JSONDecoder.hlDefault.decode(TelegramConfig.self, from: json)
        #expect(decoded.enabled == true)
        #expect(decoded.hasBotToken == true)
        #expect(decoded.chatId == "987654321")
    }

    @Test("telegram GET shape with null chatId")
    func decodeTelegramNullChat() throws {
        let json = Data(#"{ "enabled": false, "hasBotToken": false, "chatId": null }"#.utf8)
        let decoded = try JSONDecoder.hlDefault.decode(TelegramConfig.self, from: json)
        #expect(decoded.chatId == nil)
    }

    @Test("global-services decodes the three notification flags, ignores extras")
    func decodeGlobals() throws {
        // Legacy shape: the server carried `moodLogGlobal` until the moodLog
        // bridge was retired in v1.32.33. It was never decoded, and a payload
        // that still carries it must keep decoding unchanged.
        let json = Data(#"""
        {
          "telegramGlobal": true, "ntfyGlobal": false, "webPushGlobal": true,
          "apiGlobal": true, "moodLogGlobal": false
        }
        """#.utf8)
        let decoded = try JSONDecoder.hlDefault.decode(GlobalServicesFlags.self, from: json)
        #expect(decoded.telegramGlobal == true)
        #expect(decoded.ntfyGlobal == false)
        #expect(decoded.webPushGlobal == true)
    }

    @Test("global-services decodes the current shape, which has no moodLogGlobal")
    func decodeGlobalsWithoutMoodLog() throws {
        // Current server shape (`src/lib/app-settings.ts:4-9`) after the
        // moodLog retirement — the absent flag must be a non-event, not a
        // decode failure and not a hidden card.
        let json = Data(#"""
        { "telegramGlobal": true, "ntfyGlobal": true, "webPushGlobal": false, "apiGlobal": true }
        """#.utf8)
        let decoded = try JSONDecoder.hlDefault.decode(GlobalServicesFlags.self, from: json)
        #expect(decoded.telegramGlobal == true)
        #expect(decoded.ntfyGlobal == true)
        #expect(decoded.webPushGlobal == false)
    }

    @Test("test-result shape decodes { sent: true }")
    func decodeTestResult() throws {
        let decoded = try JSONDecoder.hlDefault.decode(
            NotificationChannelTestResult.self,
            from: Data(#"{ "sent": true }"#.utf8)
        )
        #expect(decoded.sent == true)
    }

    // MARK: - Gating

    @Test("both flags on → both cards visible after load")
    func bothCardsVisible() async {
        let (store, capture) = makeStore()
        capture.globals = GlobalServicesFlags(telegramGlobal: true, ntfyGlobal: true, webPushGlobal: true)
        await store.load()
        #expect(store.showNtfyCard)
        #expect(store.showTelegramCard)
        #expect(store.ntfy != nil)
        #expect(store.telegram != nil)
    }

    @Test("ntfyGlobal false hides the ntfy card and skips its config fetch")
    func ntfyHiddenWhenGlobalOff() async {
        let (store, capture) = makeStore()
        capture.globals = GlobalServicesFlags(telegramGlobal: true, ntfyGlobal: false, webPushGlobal: true)
        await store.load()
        #expect(store.showNtfyCard == false)
        #expect(store.ntfy == nil, "globally-disabled ntfy must not fetch its config")
        #expect(store.showTelegramCard)
        #expect(store.telegram != nil)
    }

    @Test("telegramGlobal false hides only the Telegram card")
    func telegramHiddenWhenGlobalOff() async {
        let (store, capture) = makeStore()
        capture.globals = GlobalServicesFlags(telegramGlobal: false, ntfyGlobal: true, webPushGlobal: true)
        await store.load()
        #expect(store.showTelegramCard == false)
        #expect(store.telegram == nil)
        #expect(store.showNtfyCard)
        #expect(store.ntfy != nil)
    }

    @Test("a failed global-services fetch falls back to all-enabled (no card hidden)")
    func globalsFailureKeepsCardsVisible() async {
        let (store, capture) = makeStore()
        capture.errorOnNextSend = .offline
        await store.loadGlobals()
        #expect(store.showNtfyCard)
        #expect(store.showTelegramCard)
    }

    // MARK: - Save / test happy paths

    @Test("saveNtfy PUTs the body incl. authToken and re-loads")
    func saveNtfyPutsBody() async throws {
        let (store, capture) = makeStore()
        await store.load()
        await store.saveNtfy(enabled: true, serverUrl: "https://ntfy.sh", topic: "hl", authToken: "tk_secret123")
        let put = try #require(capture.putBodies.first { $0.path == "/api/settings/ntfy" })
        let body = try #require(try JSONSerialization.jsonObject(with: put.body) as? [String: Any])
        #expect(body["enabled"] as? Bool == true)
        #expect(body["serverUrl"] as? String == "https://ntfy.sh")
        #expect(body["topic"] as? String == "hl")
        #expect(body["authToken"] as? String == "tk_secret123")
        #expect(store.ntfyError == nil)
    }

    @Test("saveNtfy with nil authToken omits the field")
    func saveNtfyOmitsTokenWhenNil() async throws {
        let (store, capture) = makeStore()
        await store.load()
        await store.saveNtfy(enabled: true, serverUrl: "https://ntfy.sh", topic: "hl", authToken: nil)
        let put = try #require(capture.putBodies.first { $0.path == "/api/settings/ntfy" })
        let body = try #require(try JSONSerialization.jsonObject(with: put.body) as? [String: Any])
        #expect(body["authToken"] == nil, "nil authToken must not be encoded")
    }

    @Test("saveTelegram PUTs botToken + chatId")
    func saveTelegramPutsBody() async throws {
        let (store, capture) = makeStore()
        await store.load()
        await store.saveTelegram(enabled: true, botToken: "123456:ABCdefSECRET", chatId: "987654321")
        let put = try #require(capture.putBodies.first { $0.path == "/api/settings/telegram" })
        let body = try #require(try JSONSerialization.jsonObject(with: put.body) as? [String: Any])
        #expect(body["enabled"] as? Bool == true)
        #expect(body["botToken"] as? String == "123456:ABCdefSECRET")
        #expect(body["chatId"] as? String == "987654321")
    }

    @Test("testNtfy records success")
    func ntfyOk() async {
        let (store, capture) = makeStore()
        await store.load()
        capture.ntfyTest = NotificationChannelTestResult(sent: true)
        await store.testNtfy()
        #expect(store.ntfyTestSucceeded)
        #expect(store.ntfyError == nil)
    }

    @Test("testTelegram surfaces a server error honestly without claiming success")
    func testTelegramError() async {
        let (store, capture) = makeStore()
        await store.load()
        capture.errorOnNextSend = .server(status: 422, code: nil, message: "Bot token and chat ID must be saved first")
        await store.testTelegram()
        #expect(store.telegramTestSucceeded == false)
        if case .server = store.telegramError {} else {
            Issue.record("Expected .server error, got \(String(describing: store.telegramError))")
        }
    }

    @Test("a save failure surfaces the error and keeps the prior config")
    func saveFailurePreservesConfig() async {
        let (store, capture) = makeStore()
        capture.ntfy = NtfyConfig(enabled: true, serverUrl: "https://old.example", topic: "old", hasAuthToken: true)
        await store.load()
        let before = store.ntfy
        capture.errorOnNextVoid = .offline
        await store.saveNtfy(enabled: true, serverUrl: "https://new.example", topic: "new", authToken: nil)
        #expect(store.ntfyError != nil)
        // The store never optimistically mutated `ntfy` — it only re-reads on
        // success, so the prior server snapshot is intact.
        #expect(store.ntfy == before)
    }

    @Test("clearOnLogout wipes everything back to defaults")
    func clearOnLogout() async {
        let (store, _) = makeStore()
        await store.load()
        store.clearOnLogout()
        #expect(store.ntfy == nil)
        #expect(store.telegram == nil)
        #expect(store.showNtfyCard)
        #expect(store.showTelegramCard)
    }

    // MARK: - Secret redaction guard

    @Test("LogSanitizer redacts a Telegram bot token if it ever hits a log line")
    func telegramTokenRedacted() {
        // Realistic Telegram bot token: <digits>:<35-char base64-ish>.
        let token = "7123456789:AAH9wYcQbZxK2mPq3rStUvWxYz0123456789"
        let line = "telegram save token=\(token) chatId=987654321"
        let redacted = LogSanitizer.redact(line)
        #expect(!redacted.contains(token), "raw bot token must never survive redaction")
        #expect(!redacted.contains("AAH9wYcQbZxK2mPq3rStUvWxYz0123456789"))
    }

    @Test("LogSanitizer redacts an ntfy access token if it ever hits a log line")
    func ntfyTokenRedacted() {
        let token = "tk_a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7"
        let line = "ntfy save authToken=\(token) topic=hl"
        let redacted = LogSanitizer.redact(line)
        #expect(!redacted.contains(token), "raw ntfy token must never survive redaction")
    }
}
