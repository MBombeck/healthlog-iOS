import SwiftUI

// MARK: - Resolved channel state (REG-12)

/// Pre-baked glyph / tint / copy for a single channel row.
/// Centralising the rendering decision here keeps `channelRow`
/// declarative and makes the state matrix unit-testable.
///
/// Created for REG-12 (v0.5.6) when the Settings → Notifications row
/// grew status-awareness (active / auto-disabled / sending-paused /
/// manually-disabled) on top of the existing `enabled` boolean. The
/// previous inline ternary picked between "checkmark" and "empty
/// circle" only; the new states need distinct glyphs + tints + copy
/// + an "Erneut versuchen" affordance.
struct ResolvedChannelState {
    let glyph: String
    let tint: Color
    let stateLine: String
    let stateLineTint: Color
    let voiceOverLabel: String
    /// True when the channel is in a state the operator can fix by
    /// tapping "Erneut versuchen" — i.e. auto-disabled by the
    /// dispatcher or paused in the backoff cooldown. A
    /// manually-paused channel does NOT show the button because the
    /// user themselves turned it off and the retry endpoint would
    /// just bounce back.
    let needsRetryAction: Bool

    static let activeState = ResolvedChannelState(
        glyph: "checkmark.circle.fill",
        // Monochrome doctrine: the glyph shape (checkmark vs exclamation
        // vs pause) carries the state — no coloured "bubble". The
        // active row sits at full ink so it still reads as the healthy
        // default against the muted paused/disabled states.
        tint: HLText.primary,
        stateLine: String(localized: "Active"),
        stateLineTint: HLText.secondary,
        voiceOverLabel: String(localized: "notifications.channel.state.active"),
        needsRetryAction: false
    )
}

// MARK: - Failure-reason humanisation (REG-12)

/// Maps the server's stable failure-reason codes (see
/// `lib/notifications/retry-policy.ts`) to operator-friendly German /
/// English copy. Unknown codes fall through to the raw value rather
/// than being hidden so a new server reason surfaces in the UI the
/// first time it shows up.
///
/// Split into per-channel helpers to keep each switch under the
/// project's `cyclomatic_complexity` lint threshold while still
/// reading top-to-bottom.
enum NotificationFailureReason {
    static func label(for raw: String) -> String {
        if let apns = apnsLabel(for: raw) { return apns }
        if let webPush = webPushLabel(for: raw) { return webPush }
        if let telegram = telegramLabel(for: raw) { return telegram }
        if let generic = genericLabel(for: raw) { return generic }
        // Show the raw code so a fresh server reason isn't hidden;
        // operator can map it offline.
        return raw
    }

    /// APNs hard rejects + sender-internal failure reasons. Sourced
    /// from `PERMANENT_APNS_REASONS` in `lib/notifications/senders/apns.ts`.
    private static func apnsLabel(for raw: String) -> String? {
        switch raw {
        case "BadDeviceToken":
            String(localized: "Device unknown — reinstall the app or register the token.")
        case "Unregistered":
            String(localized: "App uninstalled on the device — renew the push token.")
        case "DeviceTokenNotForTopic":
            String(localized: "Bundle ID does not match the APNs topic.")
        case "apns_not_configured":
            String(localized: "APNs key missing on the server — check operator configuration.")
        case "apns_network_error":
            String(localized: "Network error connecting to Apple Push.")
        case "apns_unknown_failure":
            String(localized: "notifications.error.apns.unknown")
        default:
            nil
        }
    }

    /// Web-Push / ntfy hard rejects. Web-Push 410 + 404 both signal
    /// "subscription is dead", ntfy 410 signals "topic deleted".
    private static func webPushLabel(for raw: String) -> String? {
        switch raw {
        case "web_push_410_gone", "web_push_404_endpoint":
            String(localized: "notifications.error.webpush.expired")
        case "ntfy_410_gone":
            String(localized: "ntfy topic deleted — create a new one.")
        default:
            nil
        }
    }

    /// Telegram Bot API hard rejects (extracted from the `description`
    /// field by `classifyTelegramError` in `retry-policy.ts`).
    private static func telegramLabel(for raw: String) -> String? {
        switch raw {
        case "telegram_chat_not_found":
            String(localized: "Telegram chat not found — reconnect the bot.")
        case "telegram_blocked_by_user":
            String(localized: "The bot was blocked in Telegram.")
        default:
            nil
        }
    }

    /// Soft / generic give-up reasons from the channel-state machine.
    private static func genericLabel(for raw: String) -> String? {
        switch raw {
        case "give_up_after_5_failures":
            String(localized: "Five failures in a row — channel disabled.")
        case "hard_reject":
            String(localized: "Upstream rejected the channel permanently.")
        case "transient_failure":
            String(localized: "Temporary error — the dispatcher will retry.")
        default:
            nil
        }
    }
}
