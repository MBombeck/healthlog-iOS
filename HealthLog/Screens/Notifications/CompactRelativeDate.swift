import Foundation

/// Compact past-only relative-date formatter used on the
/// Notifications screen channel-status line.
///
/// Replaces `RelativeDateTimeFormatter(dateTimeStyle: .named)`, which
/// rendered "vor 1 Stunde" / "vor 5 Sekunden" / "vor 2 Tagen" — a long
/// natural-language phrase. The channel-status row sits between two
/// other captions and operator feedback was that the long form drew the
/// eye away from the channel label. The compact form yields `vor 5min`,
/// `vor 2h`, `vor 3d` (German) and `5min ago`, `2h ago`, `3d ago`
/// (English) so the line reads as a glanceable timestamp.
///
/// Output rules:
/// - `< 60 s`     → `jetzt` / `now`
/// - `< 60 min`   → `vor Nmin` / `Nmin ago`
/// - `< 24 h`     → `vor Nh` / `Nh ago`
/// - `< 7 d`      → `vor Nd` / `Nd ago`
/// - otherwise    → `vor Nw` / `Nw ago`
///
/// Future-dated inputs (negative interval) clamp to `jetzt` so a
/// momentarily-skewed clock cannot render `vor -3min`.
///
/// Localization goes through `Localizable.xcstrings` so the abbreviated
/// units stay correct across both supported locales (DE primary, EN
/// secondary). The helper is `nonisolated` so it can be unit-tested
/// without MainActor ceremony.
enum CompactRelativeDate {
    /// Formats `date` relative to `reference` (default `.now`) as a
    /// compact past-only string. See type-level docs for output rules.
    static func string(from date: Date, relativeTo reference: Date = .now) -> String {
        let interval = reference.timeIntervalSince(date)
        let seconds = Int(interval.rounded())
        if seconds < 60 {
            return String(localized: "compact.relative.now")
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return String(format: String(localized: "compact.relative.minutes"), minutes)
        }
        let hours = minutes / 60
        if hours < 24 {
            return String(format: String(localized: "compact.relative.hours"), hours)
        }
        let days = hours / 24
        if days < 7 {
            return String(format: String(localized: "compact.relative.days"), days)
        }
        let weeks = days / 7
        return String(format: String(localized: "compact.relative.weeks"), weeks)
    }
}
