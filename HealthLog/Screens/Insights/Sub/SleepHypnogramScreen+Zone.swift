import Foundation

// #181 (server 1.49.0) — a night slept abroad. When `main.timeZone` or
// `naps[].timeZone` names a zone, the screen shows that session's clock times
// in it (bedtime, the nap span, the hypnogram axis, the VoiceOver chart), as
// the web's night card does. One quiet line under the summary names the zone,
// and only when its clock differs from the device's. Pure, so the decision is
// testable without a view host.

extension SleepHypnogramScreen {
    /// The zone a session's clock times are shown in: the one the server names,
    /// else the device's own.
    nonisolated static func displayZone(for session: SleepSession) -> TimeZone {
        ReadingTimeZone.zone(session.timeZone) ?? .current
    }

    /// "Zeiten in Ortszeit New York", or `nil` when the session's zone shows
    /// the same clock as `device` (or the server names none).
    nonisolated static func zoneNote(for session: SleepSession, device: TimeZone = .current) -> String? {
        guard let zone = ReadingTimeZone.awayZone(session.timeZone, at: session.start, device: device) else {
            return nil
        }
        return String(localized: "sleep.hypnogram.zone \(ReadingTimeZone.placeName(zone))")
    }

    /// The time of day of `date` in `zone`, in the 12- or 24-hour form the
    /// user chose.
    nonisolated static func clock(_ date: Date, in zone: TimeZone, defaults: UserDefaults = .standard) -> String {
        HLTimeFormat.shortTime(date, locale: HLTimeFormat.current(defaults: defaults).formattingLocale, timeZone: zone)
    }
}
