import Foundation

/// U1 (#16) — every sentence the top-of-screen sync surfaces say, in one pure
/// place so `SyncActivityCopyTests` can pin de and en without a view.
///
/// Two registers on purpose. The visible line is short ("vor 5 Min."), because
/// it sits in a small panel next to the avatar. VoiceOver gets the spelled-out
/// form ("vor 5 Minuten"), because an abbreviation read aloud is a stumble.
enum SyncActivityCopy {
    /// Below a minute a relative date reads "vor 12 Sek.", which is precision
    /// nobody asked for and changes every time the panel redraws.
    static let justNowWindow: TimeInterval = 60

    /// "Zuletzt synchronisiert vor 5 Min." / "…, im Hintergrund", or
    /// "Noch nicht synchronisiert" when nothing has synced yet.
    static func lastSyncLine(_ activity: SyncActivity?, now: Date, locale: Locale = .current) -> String {
        guard let activity else { return String(localized: "sync.activity.never") }
        let relative = relativeTime(activity.at, now: now, style: .short, locale: locale)
        return switch activity.channel {
        case .foreground: String(localized: "sync.activity.lastSynced \(relative)")
        case .background: String(localized: "sync.activity.lastSyncedBackground \(relative)")
        }
    }

    /// VoiceOver form: "Synchronisiert vor 5 Minuten" /
    /// "Im Hintergrund synchronisiert vor 5 Minuten".
    static func lastSyncAccessibility(_ activity: SyncActivity?, now: Date, locale: Locale = .current) -> String {
        guard let activity else { return String(localized: "sync.activity.never") }
        let relative = relativeTime(activity.at, now: now, style: .full, locale: locale)
        return switch activity.channel {
        case .foreground: String(localized: "sync.activity.a11y.synced \(relative)")
        case .background: String(localized: "sync.activity.a11y.syncedBackground \(relative)")
        }
    }

    /// The sentence for an attention state: a whole, calm sentence ("Die
    /// letzte Synchronisierung ist fehlgeschlagen."). Shown as plain text in
    /// the panel and read as the attention glyph's VoiceOver label, so the
    /// state never speaks only through a symbol. The time lives in the
    /// last-sync line right below it, so `stale` does not repeat it.
    static func attention(_ attention: SyncAttention, now _: Date, locale _: Locale = .current) -> String {
        switch attention {
        case let .failedWrites(count):
            String(localized: "sync.activity.attention.failedWrites \(count)")
        case .failed:
            String(localized: "sync.activity.attention.failed")
        case let .queued(count):
            String(localized: "sync.activity.attention.queued \(count)")
        case .stale:
            String(localized: "sync.activity.attention.stale")
        }
    }

    /// VoiceOver label of the slot next to the avatar.
    static func slot(_ glyph: SyncSlotGlyph, now: Date) -> String {
        switch glyph {
        case .syncing: String(localized: "sync.status.syncing")
        case .done: String(localized: "sync.activity.a11y.done")
        case let .attention(state): attention(state, now: now)
        }
    }

    static func relativeTime(
        _ date: Date,
        now: Date,
        style: RelativeDateTimeFormatter.UnitsStyle,
        locale: Locale
    ) -> String {
        if abs(now.timeIntervalSince(date)) < justNowWindow {
            return String(localized: "sync.activity.justNow")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = style
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
