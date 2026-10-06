import Foundation

/// Per-channel reliability state from `GET /api/notifications/status`.
/// Mirrors the server shape at `<server-repo>/src/app/api/
/// notifications/status/route.ts:13-31` exactly. Sendable + Codable + Equatable
/// so the Store can diff frames cheaply.
///
/// Used by `NotificationsScreen` to render the "last delivery" + state-badge
/// rows the user expects from a finished settings surface (A7 §3.3 issue #2).
public struct NotificationChannelStatus: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let type: String
    public let label: String
    public let enabled: Bool
    public let state: ChannelState
    public let disabledReason: String?
    public let consecutiveFailures: Int
    public let lastSuccessAt: Date?
    public let lastFailureAt: Date?
    public let lastFailureReason: String?
    public let nextRetryAt: Date?

    public enum ChannelState: String, Codable, Sendable, Equatable, TolerantServerEnum {
        case active
        case autoDisabled = "auto_disabled"
        case manuallyDisabled = "manually_disabled"
        case sendingPaused = "sending_paused"
        /// #115 · 1.7 — a channel state this build does not know. Used to fail
        /// the whole `/api/notifications/status` payload; now the row falls
        /// back to its static `enabled` flag.
        case unknown

        public static let unknownFallback = ChannelState.unknown
        public static let wireVocabulary: StaticString = "notification channel state"
    }

    public init(
        id: String,
        type: String,
        label: String,
        enabled: Bool,
        state: ChannelState,
        disabledReason: String?,
        consecutiveFailures: Int,
        lastSuccessAt: Date?,
        lastFailureAt: Date?,
        lastFailureReason: String?,
        nextRetryAt: Date?
    ) {
        self.id = id
        self.type = type
        self.label = label
        self.enabled = enabled
        self.state = state
        self.disabledReason = disabledReason
        self.consecutiveFailures = consecutiveFailures
        self.lastSuccessAt = lastSuccessAt
        self.lastFailureAt = lastFailureAt
        self.lastFailureReason = lastFailureReason
        self.nextRetryAt = nextRetryAt
    }
}

/// Envelope for the `GET /api/notifications/status` payload: `{ channels: [...] }`.
public struct NotificationStatusPayload: Codable, Sendable, Equatable {
    public let channels: [NotificationChannelStatus]

    public init(channels: [NotificationChannelStatus]) {
        self.channels = channels
    }
}
