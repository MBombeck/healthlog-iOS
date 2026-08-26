import SwiftUI

/// **v0.8.4 WWIDGET-1 — extension-local copy.**
///
/// The Live-Activity / widget colour palette lives in the shared
/// `LiveActivityTokens.swift` (`LAColor`), compiled into both the app and
/// the extension so the surfaces match the app's documented Tonal-Mono
/// design system (no Dracula). This file now only carries the localised
/// copy helpers.
///
/// Localised copy for the Live Activity. Strings live in the extension's
/// own `Localizable.xcstrings` (EN + DE) so no hardcoded UI strings ship.
enum LAStrings {
    static var taken: LocalizedStringKey {
        "la.med.action.taken"
    }

    /// **v0.10 Walkthrough-2 LA2** — the relabel on the armed (pending-confirm)
    /// "Genommen" button: "Erneut tippen zum Bestätigen". The second tap on
    /// THIS state actually records the intake.
    static var confirmTaken: LocalizedStringKey {
        "la.med.action.taken.confirm"
    }

    /// VoiceOver hint for the armed confirm button — "Nochmal tippen, um die
    /// Einnahme zu bestätigen".
    static var confirmTakenHint: LocalizedStringKey {
        "la.med.action.taken.confirm.hint"
    }

    static var takenConfirmation: LocalizedStringKey {
        "la.med.status.taken"
    }

    static var snoozed: LocalizedStringKey {
        "la.med.status.snoozed"
    }

    /// "fällig um HH:mm" — formats the scheduled time honouring the user's
    /// server `timeFormat` preference (12h / 24h / auto) carried in the
    /// ContentState (`W-B187`), so the Live-Activity clock matches the in-app
    /// card + home-screen widget instead of the raw device locale.
    static func dueAt(_ date: Date, timeFormatRaw: String) -> String {
        let time = (HLTimeFormat(rawValue: timeFormatRaw) ?? .auto).formatTime(date)
        return String(
            format: String(localized: "la.med.due_at", defaultValue: "fällig um %@"),
            time
        )
    }

    /// "Genommen um HH:mm" — the in-place confirmation line shown once the
    /// dose is recorded (`v0.10 W-LiveActivity-POLISH`). Honours the user's
    /// `timeFormat` preference (`W-B187`).
    static func takenAt(_ date: Date, timeFormatRaw: String) -> String {
        let time = (HLTimeFormat(rawValue: timeFormatRaw) ?? .auto).formatTime(date)
        return String(
            format: String(localized: "la.med.taken_at", defaultValue: "Genommen um %@"),
            time
        )
    }

    /// VoiceOver hint for the "Genommen" button — "Erfasst <Name> als
    /// eingenommen".
    static func takenHint(_ medicationName: String) -> String {
        String(
            format: String(localized: "la.med.action.taken.hint", defaultValue: "Erfasst %@ als eingenommen"),
            medicationName
        )
    }

    /// VoiceOver label for the pending countdown — "Fällig in 4 Minuten" /
    /// "Überfällig seit 4 Minuten" — since raw `Text(timerInterval:)` is
    /// announced poorly.
    static func countdownAccessibilityLabel(target: Date, now: Date = .now) -> String {
        let overdue = now > target
        let interval = abs(target.timeIntervalSince(now))
        let spoken = Duration.seconds(interval).formatted(
            .units(allowed: [.hours, .minutes], width: .wide, maximumUnitCount: 2)
        )
        let template = overdue
            ? String(localized: "la.med.a11y.overdue", defaultValue: "Überfällig seit %@")
            : String(localized: "la.med.a11y.due_in", defaultValue: "Fällig in %@")
        return String(format: template, spoken)
    }

    /// Confirmation accessibility label — "Genommen".
    static var takenAccessibility: LocalizedStringKey {
        "la.med.a11y.taken"
    }

    /// Short label next to the pending countdown — "verbleibend".
    static var remainingShort: LocalizedStringKey {
        "la.med.remaining_short"
    }

    /// Short label next to the overdue (red) countdown — "überfällig".
    static var overdueShort: LocalizedStringKey {
        "la.med.overdue_short"
    }
}
