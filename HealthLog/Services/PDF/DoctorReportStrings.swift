import Foundation

/// **L10N-REPORT (1.5) — the doctor report's labels are a translation table.**
///
/// Every fixed word the local PDF prints lives in
/// `HealthLog/Resources/DoctorReport.xcstrings` and is read with the bundle of
/// the *report* language (`<language>.lproj`), not the interface language: a
/// reader on an English iPhone can print a German report for a doctor in
/// Germany. A new report language is therefore a translation of that table;
/// `DoctorReportStringsTests` checks every key in every `AppLanguage`.
enum DoctorReportString: String, CaseIterable, Sendable {
    case title = "report.title"
    case coverPatient = "report.cover.patient"
    case coverFullName = "report.cover.fullName"
    case coverInsurer = "report.cover.insurer"
    case coverInsuranceNumber = "report.cover.insuranceNumber"
    case coverPeriod = "report.cover.period"
    case coverGenerated = "report.cover.generated"
    case coverAppVersion = "report.cover.appVersion"
    /// Start date, end date.
    case periodRange = "report.period.range %@ %@"
    case vitalsTitle = "report.vitals.title"
    case columnMetric = "report.vitals.column.metric"
    case columnCount = "report.vitals.column.count"
    case columnMean = "report.vitals.column.mean"
    case columnMedian = "report.vitals.column.median"
    case columnMin = "report.vitals.column.min"
    case columnMax = "report.vitals.column.max"
    case chartsTitle = "report.charts.title"
    /// Metric name, number of points.
    case chartsDataPoints = "report.charts.dataPoints %@ %lld"
    case medicationsTitle = "report.medications.title"
    case medicationsArchived = "report.medications.archived"
    case adherenceTitle = "report.adherence.title"
    /// Window in days.
    case adherenceSource = "report.adherence.source %lld"
    /// Report period in days, window in days.
    case adherenceWindowMismatch = "report.adherence.windowMismatch %lld %lld"
    case adherenceUnavailable = "report.adherence.unavailable"
    /// Medication, taken, expected, percentage, window in days.
    case adherenceRow = "report.adherence.row %@ %lld %lld %@ %lld"
    /// Medication.
    case adherenceRowNoSchedule = "report.adherence.row.noSchedule %@"
    /// Medication count, taken, expected, percentage, window in days.
    case adherenceAccount = "report.adherence.account %lld %lld %lld %@ %lld"
    case moodTitle = "report.mood.title"
    /// Entry count, average score.
    case moodSummary = "report.mood.summary %lld %.1f"
    case moodTags = "report.mood.tags"
    /// Medical key (`scripts/l10n/medical-keys.json`).
    case disclaimer = "report.disclaimer"
}

enum DoctorReportStrings {
    static let table = "DoctorReport"

    /// The `<language>.lproj` bundle of `locale`, or `nil` when the app does
    /// not ship it (never the case for a shipped `AppLanguage`; the test over
    /// `allCases` holds that).
    static func bundle(for locale: ReportLocale) -> Bundle? {
        let host = Bundle(for: BundleToken.self)
        guard let path = host.path(forResource: locale.rawValue, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }

    /// The value of `key` in the table of `locale`, or `nil` when it is missing.
    static func lookup(_ key: DoctorReportString, locale: ReportLocale) -> String? {
        guard let bundle = bundle(for: locale) else { return nil }
        let value = bundle.localizedString(forKey: key.rawValue, value: missingMarker, table: table)
        return value == missingMarker ? nil : value
    }

    /// The label in the report language. A missing value falls back to
    /// English, then to the key, so a report is never blank; the test makes
    /// both fallbacks unreachable for every shipped language.
    static func text(_ key: DoctorReportString, _ locale: ReportLocale) -> String {
        lookup(key, locale: locale) ?? lookup(key, locale: .en) ?? key.rawValue
    }

    /// A format label filled with `arguments`, numbers in the report locale.
    static func format(_ key: DoctorReportString, _ locale: ReportLocale, _ arguments: CVarArg...) -> String {
        String(format: text(key, locale), locale: locale.formattingLocale, arguments: arguments)
    }

    /// A metric's name in the report language, from the app catalog's table for
    /// that language (the metric names are shared with the rest of the app).
    /// Falls back to the interface language's name.
    static func metricName(_ kind: MetricKind, _ locale: ReportLocale) -> String {
        let key = kind.descriptor.title.key
        guard let bundle = bundle(for: locale) else { return kind.displayName }
        let value = bundle.localizedString(forKey: key, value: missingMarker, table: nil)
        return value == missingMarker ? kind.displayName : value
    }

    /// POLISH-A F-PDF-3 — a mood tag in the report language. A stored tag is
    /// a catalog key (`tired`, `slept_well`, `factor_stress`); its label comes
    /// from the app catalog's table for that language, the same words the
    /// mood screen shows. A custom tag (`custom:<id>`) carries no label here
    /// and reads as the neutral "own tag" word. Anything else is free text the
    /// person wrote and stays as written.
    static func moodTagName(_ tag: String, _ locale: ReportLocale) -> String {
        let labelKey: String? = if tag.hasPrefix("custom:") {
            "mood.tag.customFallback"
        } else {
            MoodTagCatalogRepository.bundledFallback.categories
                .lazy.flatMap(\.tags).first { $0.key == tag }?.labelKey
                ?? MoodTagCatalog.ratedFactorLabelKey[tag]
        }
        guard let labelKey, let bundle = bundle(for: locale) else { return tag }
        let value = bundle.localizedString(forKey: labelKey, value: missingMarker, table: nil)
        return value == missingMarker ? tag : value
    }

    private static let missingMarker = "\u{0}missing"
    private final class BundleToken {}
}
