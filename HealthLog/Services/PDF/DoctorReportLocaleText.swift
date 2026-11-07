import Foundation

// MARK: - Locale text

/// The doctor report's fixed labels in the report language. Since 1.5 every
/// label is a key of `DoctorReport.xcstrings` (``DoctorReportStrings``); the
/// per-language branches that came with Dutch (PR #29) became that table, so a
/// new report language is a translation, not a code change.
enum LocaleText {
    static func coverTitle(for locale: ReportLocale) -> String {
        DoctorReportStrings.text(.title, locale)
    }

    static func coverPatientLabel(for locale: ReportLocale) -> String {
        DoctorReportStrings.text(.coverPatient, locale)
    }

    static func coverFullNameLabel(for locale: ReportLocale) -> String {
        DoctorReportStrings.text(.coverFullName, locale)
    }

    static func coverInsurerLabel(for locale: ReportLocale) -> String {
        DoctorReportStrings.text(.coverInsurer, locale)
    }

    static func coverInsuranceNumberLabel(for locale: ReportLocale) -> String {
        DoctorReportStrings.text(.coverInsuranceNumber, locale)
    }

    static func coverPeriodLabel(for locale: ReportLocale) -> String {
        DoctorReportStrings.text(.coverPeriod, locale)
    }

    static func coverGeneratedLabel(for locale: ReportLocale) -> String {
        DoctorReportStrings.text(.coverGenerated, locale)
    }

    static func coverVersionLabel(for locale: ReportLocale) -> String {
        DoctorReportStrings.text(.coverAppVersion, locale)
    }

    static func vitalsTitle(for locale: ReportLocale) -> String {
        DoctorReportStrings.text(.vitalsTitle, locale)
    }

    static func colKind(for locale: ReportLocale) -> String {
        DoctorReportStrings.text(.columnMetric, locale)
    }

    static func colCount(for locale: ReportLocale) -> String {
        DoctorReportStrings.text(.columnCount, locale)
    }

    static func colMean(for locale: ReportLocale) -> String {
        DoctorReportStrings.text(.columnMean, locale)
    }

    static func colMedian(for locale: ReportLocale) -> String {
        DoctorReportStrings.text(.columnMedian, locale)
    }

    static func colMin(for locale: ReportLocale) -> String {
        DoctorReportStrings.text(.columnMin, locale)
    }

    static func colMax(for locale: ReportLocale) -> String {
        DoctorReportStrings.text(.columnMax, locale)
    }

    static func chartsTitle(for locale: ReportLocale) -> String {
        DoctorReportStrings.text(.chartsTitle, locale)
    }

    /// The chart fallback caption: "Weight: 12 data points".
    static func dataPoints(_ metric: String, count: Int, locale: ReportLocale) -> String {
        DoctorReportStrings.format(.chartsDataPoints, locale, metric, count)
    }

    static func medicationsTitle(for locale: ReportLocale) -> String {
        DoctorReportStrings.text(.medicationsTitle, locale)
    }

    static func medicationsArchived(for locale: ReportLocale) -> String {
        DoctorReportStrings.text(.medicationsArchived, locale)
    }

    static func adherenceTitle(for locale: ReportLocale) -> String {
        DoctorReportStrings.text(.adherenceTitle, locale)
    }

    static func moodTitle(for locale: ReportLocale) -> String {
        DoctorReportStrings.text(.moodTitle, locale)
    }

    /// The format of the mood line: entry count, then the average score.
    static func moodSummaryFormat(for locale: ReportLocale) -> String {
        DoctorReportStrings.text(.moodSummary, locale)
    }

    /// The mood line, numbers in the report locale ("3,5" in DE and NL).
    static func moodSummary(count: Int, average: Double, locale: ReportLocale) -> String {
        DoctorReportStrings.format(.moodSummary, locale, count, average)
    }

    static func moodTagsLabel(for locale: ReportLocale) -> String {
        DoctorReportStrings.text(.moodTags, locale)
    }

    /// "16 Apr 2026 to 16 May 2026", both dates in the report locale.
    static func periodRange(_ start: String, _ end: String, locale: ReportLocale) -> String {
        DoctorReportStrings.format(.periodRange, locale, start, end)
    }
}
