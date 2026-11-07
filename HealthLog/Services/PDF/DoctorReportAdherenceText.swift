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
            if let account = block.account {
                notes.append(adherenceAccount(account, windowDays: block.windowDays, locale: locale))
            }
            if !block.windowMatchesPeriod {
                notes.append(adherenceWindowMismatch(windowDays: block.windowDays, periodDays: block.periodDays, locale: locale))
            }
            return notes
        }
    }

    static func adherenceRow(_ row: DoctorReportSpec.AdherenceBlock.Row, windowDays: Int, locale: ReportLocale) -> String {
        guard row.applicable, let rate = row.rate, let taken = row.taken, let expected = row.expected else {
            return DoctorReportStrings.format(.adherenceRowNoSchedule, locale, row.medicationName)
        }
        let percent = HLNumberFormat.percent(rate, locale: locale.formattingLocale)
        return DoctorReportStrings.format(.adherenceRow, locale, row.medicationName, taken, expected, percent, windowDays)
    }

    static func adherenceSource(windowDays: Int, locale: ReportLocale) -> String {
        DoctorReportStrings.format(.adherenceSource, locale, windowDays)
    }

    static func adherenceWindowMismatch(windowDays: Int, periodDays: Int, locale: ReportLocale) -> String {
        DoctorReportStrings.format(.adherenceWindowMismatch, locale, periodDays, windowDays)
    }

    static func adherenceUnavailable(for locale: ReportLocale) -> String {
        DoctorReportStrings.text(.adherenceUnavailable, locale)
    }
}

/// #126 P2 (server v1.42.0) — the report's own adherence window.
///
/// `?days=` (the report period, 30/60/90/180/365) adds `complianceN` to every
/// row and to the account figure. The window is used only when the server
/// answered for exactly the period and for every applicable medication the
/// report lists; otherwise the block stays on `compliance30` and says so. Rows
/// are never mixed across windows.
struct DoctorReportAdherenceWindow {
    let days: Int
    let rows: [String: ComplianceWindowResult]

    init?(report: MedicationComplianceReport?, periodDays: Int, medications: [Medication]) {
        guard let report, let days = report.days, days == periodDays else { return nil }
        let applicable = report.entries.filter(\.isApplicable).map(\.medicationId)
        let listed = Set(medications.map(\.id))
        let needed = applicable.filter { listed.contains($0) }
        guard needed.allSatisfy({ report.rowWindows[$0] != nil }) else { return nil }
        self.days = days
        rows = report.rowWindows
    }

    /// The account figure for `days`, as the server sent it.
    static func accountFigure(
        _ aggregate: MedicationComplianceAggregate?,
        days: Int
    ) -> DoctorReportSpec.AdherenceBlock.AccountFigure? {
        guard let aggregate, let window = aggregate.window(days: days) else { return nil }
        return .init(
            rate: window.rate,
            taken: window.taken,
            expected: window.taken + window.missed,
            medicationCount: aggregate.medicationCount
        )
    }
}

extension LocaleText {
    /// #126 P2 — the account line under the source note.
    static func adherenceAccount(
        _ figure: DoctorReportSpec.AdherenceBlock.AccountFigure,
        windowDays: Int,
        locale: ReportLocale
    ) -> String {
        let percent = HLNumberFormat.percent(figure.rate, locale: locale.formattingLocale)
        return DoctorReportStrings.format(
            .adherenceAccount,
            locale,
            figure.medicationCount,
            figure.taken,
            figure.expected,
            percent,
            windowDays
        )
    }
}
