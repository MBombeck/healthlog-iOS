import Foundation

/// #115 · 1.2 — the doctor report's adherence wording (split from
/// `DoctorReportSectionDrawer.swift` for the file-length budget).
extension LocaleText {
    /// #115 · 1.2 — the sentences that frame the server's adherence.
    static func adherenceNotes(for block: DoctorReportSpec.AdherenceBlock, locale: ReportLocale) -> [String] {
        switch block.availability {
        case .unavailable:
            return [adherenceUnavailable(for: locale)]
        case .server:
            var notes = [adherenceSource(windowDays: block.windowDays, locale: locale)]
            if !block.windowMatchesPeriod {
                notes.append(adherenceWindowMismatch(windowDays: block.windowDays, periodDays: block.periodDays, locale: locale))
            }
            return notes
        }
    }

    static func adherenceRow(_ row: DoctorReportSpec.AdherenceBlock.Row, windowDays: Int, locale: ReportLocale) -> String {
        guard row.applicable, let rate = row.rate, let taken = row.taken, let expected = row.expected else {
            switch locale {
            case .de: return "\(row.medicationName): kein Einnahmeplan in HealthLog, keine Einnahmetreue"
            case .en: return "\(row.medicationName): no HealthLog schedule, no adherence rate"
            }
        }
        let percent = HLNumberFormat.percent(rate, locale: Locale(identifier: locale.foundationIdentifier))
        switch locale {
        case .de: return "\(row.medicationName): \(taken) von \(expected) eingenommen (\(percent)) · \(windowDays) Tage"
        case .en: return "\(row.medicationName): \(taken) of \(expected) taken (\(percent)) · \(windowDays) days"
        }
    }

    static func adherenceSource(windowDays: Int, locale: ReportLocale) -> String {
        switch locale {
        case .de: "Einnahmetreue der letzten \(windowDays) Tage, vom HealthLog-Server nach Einnahmeplan berechnet."
        case .en: "Adherence over the last \(windowDays) days, computed by the HealthLog server from the dosing schedule."
        }
    }

    static func adherenceWindowMismatch(windowDays: Int, periodDays: Int, locale: ReportLocale) -> String {
        switch locale {
        case .de: "Fuer den Berichtszeitraum von \(periodDays) Tagen liefert der Server keine Einnahmetreue; gezeigt sind die letzten \(windowDays) Tage."
        case .en: "The server provides no adherence for the \(periodDays)-day report period; the last \(windowDays) days are shown."
        }
    }

    static func adherenceUnavailable(for locale: ReportLocale) -> String {
        switch locale {
        case .de: "Einnahmetreue nicht verfuegbar: Der HealthLog-Server war beim Erstellen nicht erreichbar."
        case .en: "Adherence not available: the HealthLog server could not be reached when this report was made."
        }
    }
}
