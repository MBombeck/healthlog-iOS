import Foundation

// DTOs for the per-user notification-channel settings (`ntfy` + `Telegram`)
// exposed under `Settings → Notifications`. These mirror the web's
// `settings → notifications → ntfy / telegram` cards, gated by the
// server-wide availability flags.
//
// **Wire contract (verbatim from the server `/api/settings/*` routes):**
//
// - `GET /api/settings/ntfy` → `{ enabled, serverUrl, topic, hasAuthToken }`
//   (`route.ts:24-49`). The auth token itself is **never** returned — only
//   `hasAuthToken` tells the client whether one is stored.
// - `PUT /api/settings/ntfy` body `{ enabled, serverUrl, topic, authToken? }`
//   → `{ saved: true }` (NOT the config — the screen re-fetches GET after).
// - `POST /api/settings/ntfy/test` → `{ sent: true }`.
// - `GET /api/settings/telegram` → `{ enabled, hasBotToken, chatId }`
//   (`route.ts:30-32`). The bot token is **write-only** — the server never
//   returns it, only `hasBotToken`.
// - `PUT /api/settings/telegram` body `{ enabled, botToken?, chatId? }`
//   → `{ updated: true }`.
// - `POST /api/settings/telegram/test` → `{ sent: true }`.
// - `GET /api/settings/global-services`
//   → `{ telegramGlobal, ntfyGlobal, webPushGlobal, apiGlobal }`
//   (`src/lib/app-settings.ts:4-9`). iOS decodes only the three notification
//   flags; `apiGlobal` is ignored. The shape used to carry `moodLogGlobal` too
//   — that flag went with the retired moodLog bridge in v1.32.33 (migration
//   0271 dropped the column). Unknown keys are ignored either way, so a
//   payload that still carries it decodes unchanged.
//
// **Secret handling:** neither the ntfy `authToken` nor the Telegram
// `botToken` is ever read back from the server or persisted client-side.
// They live only transiently in the View's `@State` and ride the in-flight
// `PUT` once. They are never logged (`LogSanitizer` + the dedicated
// `secretNotLogged` test).

/// Mirror of `GET /api/settings/ntfy`. Decoded tolerantly so a future server
/// field never breaks the screen.
public struct NtfyConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// The user's own ntfy server URL — the literal "Server-Einstellung".
    /// Defaults to the public `https://ntfy.sh` instance server-side.
    public var serverUrl: String
    public var topic: String
    /// `true` when an auth token is stored server-side. The token itself is
    /// never returned (server `route.ts:46`). Drives the "token saved" hint
    /// without echoing the secret.
    public var hasAuthToken: Bool

    public init(enabled: Bool, serverUrl: String, topic: String, hasAuthToken: Bool = false) {
        self.enabled = enabled
        self.serverUrl = serverUrl
        self.topic = topic
        self.hasAuthToken = hasAuthToken
    }

    /// Default empty config for a fresh server response shape parity (the
    /// server already returns this when no channel exists).
    public static let empty = NtfyConfig(
        enabled: false,
        serverUrl: "https://ntfy.sh",
        topic: "",
        hasAuthToken: false
    )
}

/// Mirror of `GET /api/settings/telegram`. The bot token is **write-only** —
/// the server returns only `hasBotToken`, never the token (`route.ts:30-32`).
public struct TelegramConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// `true` when a bot token is stored server-side. The token itself is
    /// never read back. Treat like the WHOOP `clientSecret` pattern.
    public var hasBotToken: Bool
    public var chatId: String?

    public init(enabled: Bool, hasBotToken: Bool = false, chatId: String? = nil) {
        self.enabled = enabled
        self.hasBotToken = hasBotToken
        self.chatId = chatId
    }

    public static let empty = TelegramConfig(enabled: false, hasBotToken: false, chatId: nil)
}

/// Mirror of `GET /api/settings/webhook` (v1.17.1). A generic outbound
/// webhook channel (covers Gotify / Discord / Slack / Matrix-bridge / Home
/// Assistant in one): the user supplies a public URL and an optional shared
/// secret header. The header **value** is write-only — the server returns
/// only `hasHeaderValue`, never the secret (`route.ts:43-48`). There is no
/// `webhookGlobal` availability flag, so the card always renders.
public struct WebhookConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// Public webhook URL. SSRF-guarded server-side (`isPublicUrl`).
    public var url: String
    /// Optional custom header name (e.g. `Authorization`, `X-Gotify-Key`).
    public var headerName: String
    /// `true` when a header value (shared secret) is stored server-side. The
    /// value itself is never read back; mirrors the ntfy `hasAuthToken` shape.
    public var hasHeaderValue: Bool

    public init(enabled: Bool, url: String, headerName: String = "", hasHeaderValue: Bool = false) {
        self.enabled = enabled
        self.url = url
        self.headerName = headerName
        self.hasHeaderValue = hasHeaderValue
    }

    public static let empty = WebhookConfig(enabled: false, url: "", headerName: "", hasHeaderValue: false)
}

/// Mirror of the notification-relevant subset of
/// `GET /api/settings/global-services`. The operator can disable a channel
/// server-wide; iOS hides the matching card when its flag is `false`. The
/// server also returns `apiGlobal`, which is out of scope for the notification
/// surface and simply not decoded here. The retired `moodLogGlobal` flag left
/// the server shape in v1.32.33; it was never decoded either, so its removal
/// is a no-op for this type — there is no notification card behind it.
public struct GlobalServicesFlags: Codable, Sendable, Equatable {
    public let telegramGlobal: Bool
    public let ntfyGlobal: Bool
    public let webPushGlobal: Bool

    public init(telegramGlobal: Bool, ntfyGlobal: Bool, webPushGlobal: Bool) {
        self.telegramGlobal = telegramGlobal
        self.ntfyGlobal = ntfyGlobal
        self.webPushGlobal = webPushGlobal
    }

    /// All-enabled fallback — mirrors the server default when app-settings can't
    /// be read (`app-settings.ts:34-40`). A missing flags response should not
    /// hide channels the user may already have configured.
    public static let allEnabled = GlobalServicesFlags(
        telegramGlobal: true,
        ntfyGlobal: true,
        webPushGlobal: true
    )
}

/// Mirror of the `POST …/test` success branch for both channels
/// (`{ sent: true }`). A failed test surfaces as `HLError.server` instead.
public struct NotificationChannelTestResult: Codable, Sendable, Equatable {
    public let sent: Bool

    public init(sent: Bool) {
        self.sent = sent
    }
}
