import Foundation

/// #191 (server 1.49.0) — a symptom's distance to the day's dose in words, as
/// the web words it (`doseOffsetText`, `day.doseOffset.*`): "2 Std. 10 Min.
/// nach Metformin", "40 Min. vor Metformin", "Zur Zeit von Metformin". The
/// minutes are the server's; only their wording happens here. A distance in
/// time, never a cause.
enum DoseOffsetFormat {
    static func text(_ offset: DayDoseOffset, locale: Locale = .current) -> String {
        let name = offset.title
        guard offset.minutes != 0 else {
            return String(localized: "symptoms.doseOffset.atDose \(name)")
        }
        let duration = HLTimeFormat.duration(TimeInterval(abs(offset.minutes) * 60), locale: locale)
        return offset.minutes > 0
            ? String(localized: "symptoms.doseOffset.after \(duration) \(name)")
            : String(localized: "symptoms.doseOffset.before \(duration) \(name)")
    }
}
