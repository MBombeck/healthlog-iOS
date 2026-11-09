import Foundation
@testable import HealthLog
import PDFKit
import Testing

private typealias Measurement = HealthLog.Measurement

/// **L10N-REPORT (1.5) — the report's labels are a table, read in the report
/// language.**
///
/// Before, every label was a `switch` over `ReportLocale` in Swift, and the
/// sharing screen mapped every non-English reader to German. Now the labels are
/// `DoctorReport.xcstrings`, read with the `<language>.lproj` of the report
/// language, so a new language is a translation and these tests say which key
/// is missing in which language.
@MainActor
@Suite("Doctor report — language table")
struct DoctorReportLanguageTableTests {
    // MARK: - The table

    @Test("every label has a value in every AppLanguage, read from that language's table")
    func everyLabelInEveryLanguage() {
        var missing: [String] = []
        for language in AppLanguage.allCases {
            let locale = ReportLocale(language)
            #expect(DoctorReportStrings.bundle(for: locale) != nil, "no \(language.rawValue).lproj in the app bundle")
            for key in DoctorReportString.allCases {
                let value = DoctorReportStrings.lookup(key, locale: locale)
                if value?.isEmpty ?? true { missing.append("\(language.rawValue): \(key.rawValue)") }
            }
        }
        #expect(missing.isEmpty, "labels without a value: \(missing)")
    }

    @Test("the compiled table holds exactly the keys the code reads, in every language")
    func tableMatchesTheEnum() throws {
        let expected = Set(DoctorReportString.allCases.map(\.rawValue))
        for language in AppLanguage.allCases {
            let bundle = try #require(DoctorReportStrings.bundle(for: ReportLocale(language)))
            let path = try #require(bundle.path(forResource: DoctorReportStrings.table, ofType: "strings"))
            let table = try #require(NSDictionary(contentsOfFile: path) as? [String: String])
            #expect(Set(table.keys) == expected, "\(language.rawValue): \(Set(table.keys).symmetricDifference(expected))")
        }
    }

    @Test("German and English are the 1.4 wording; German spelled with umlauts since 1.5")
    func germanAndEnglishUnchanged() {
        #expect(LocaleText.coverTitle(for: .de) == "Arztbericht")
        #expect(LocaleText.coverTitle(for: .en) == "Doctor Report")
        #expect(DoctorReportDisclaimer.de == "Lokaler Export, kein Server beteiligt, auf-Gerät erzeugt, kein medizinisches Dokument")
        #expect(DoctorReportDisclaimer.en == "Local export, no server involved, generated on-device, not a medical document")
        #expect(LocaleText.moodSummary(count: 8, average: 3.5, locale: .de) == "8 Einträge, Durchschnitt 3,5 / 5")
        #expect(LocaleText.moodSummary(count: 8, average: 3.5, locale: .en) == "8 entries, average 3.5 / 5")
        #expect(LocaleText.adherenceWindowMismatch(windowDays: 30, periodDays: 90, locale: .de)
            == "Für den Berichtszeitraum von 90 Tagen liefert der Server keine Einnahmetreue; gezeigt sind die letzten 30 Tage.")
        #expect(LocaleText.adherenceWindowMismatch(windowDays: 30, periodDays: 90, locale: .en)
            == "The server provides no adherence for the 90-day report period; the last 30 days are shown.")
        #expect(LocaleText.periodRange("1", "2", locale: .de) == "1 bis 2")
        #expect(LocaleText.periodRange("1", "2", locale: .en) == "1 to 2")
        #expect(LocaleText.periodRange("1", "2", locale: .nl) == "1 tot 2")
    }

    @Test("every format label fills its arguments in every language")
    func formatLabelsFill() {
        let row = DoctorReportSpec.AdherenceBlock.Row(
            medicationId: "m", medicationName: "Lisinopril", applicable: true, rate: 90, taken: 27, expected: 30
        )
        let figure = DoctorReportSpec.AdherenceBlock.AccountFigure(rate: 90, taken: 27, expected: 30, medicationCount: 2)
        for locale in ReportLocale.allCases {
            let lines = [
                LocaleText.adherenceRow(row, windowDays: 30, locale: locale),
                LocaleText.adherenceAccount(figure, windowDays: 30, locale: locale),
                LocaleText.adherenceSource(windowDays: 30, locale: locale),
                LocaleText.adherenceWindowMismatch(windowDays: 30, periodDays: 90, locale: locale),
                LocaleText.dataPoints("X", count: 12, locale: locale),
                LocaleText.moodSummary(count: 8, average: 3.5, locale: locale),
                LocaleText.periodRange("A", "B", locale: locale)
            ]
            // A literal "%" is fine (the adherence percentage); a format
            // specifier left in the text is not.
            let specifier = /%(\d+\$)?[-+ #0]*\d*(\.\d+)?(ll|l|h)?[@dDiuUxXoOfFeEgGaAcCsSp]/
            for line in lines {
                #expect(line.firstMatch(of: specifier) == nil, "\(locale.rawValue): unfilled specifier in \(line)")
            }
            #expect(lines[0].contains("27") && lines[0].contains("30") && lines[0].contains("Lisinopril"))
            // Korean keeps the medication counter inside the parentheses.
            let medicationCount = locale == .ko ? "(2개)" : "(2)"
            #expect(lines[1].contains(medicationCount), "\(locale.rawValue): missing medication count in \(lines[1])")
        }
    }

    @Test("metric names follow the report language, not the interface")
    func metricNamesFollowTheReport() {
        #expect(DoctorReportStrings.metricName(.bloodPressure, .de) == "Blutdruck")
        #expect(DoctorReportStrings.metricName(.bloodPressure, .en) == "Blood pressure")
        #expect(DoctorReportStrings.metricName(.bloodPressure, .nl) == "Bloeddruk")
        #expect(DoctorReportStrings.metricName(.pulse, .nl) == "Hartslag")
    }

    /// POLISH-A F-PDF-3 — the mood page printed the stored tag keys raw
    /// ("tired, slept_well") in every report language.
    @Test("mood tags follow the report language; a custom tag is neutral, free text stays as written")
    func moodTagsFollowTheReport() {
        #expect(DoctorReportStrings.moodTagName("tired", .de) == "müde")
        #expect(DoctorReportStrings.moodTagName("tired", .nl) == "moe")
        #expect(DoctorReportStrings.moodTagName("tired", .en) == "tired")
        #expect(DoctorReportStrings.moodTagName("slept_well", .de) == "gut geschlafen")
        #expect(DoctorReportStrings.moodTagName("factor_stress", .nl) == "Stress")
        #expect(DoctorReportStrings.moodTagName("custom:3f2a", .de) == "Eigener Tag")
        #expect(DoctorReportStrings.moodTagName("custom:3f2a", .nl) == "Eigen tag")
        #expect(DoctorReportStrings.moodTagName("Rückenschmerzen nach dem Lauf", .nl) == "Rückenschmerzen nach dem Lauf")
    }

    // MARK: - Report language from the interface language

    @Test("each AppLanguage has its report language, and back")
    func reportLocaleFollowsAppLanguage() {
        for language in AppLanguage.allCases {
            #expect(ReportLocale(language).appLanguage == language)
            #expect(ReportLocale(language).rawValue == language.rawValue)
            #expect(ReportLocale(language).foundationIdentifier == language.homeLocaleIdentifier)
        }
        #expect(ReportLocale(AppLanguage.resolve("fr-FR")) == .en)
    }

    @Test("the server report takes Dutch from 1.43.7 and Korean from 1.37.32, English before")
    func exportServerCode() throws {
        #expect(ReportLocale.de.exportServerCode(serverAcceptsDutch: false) == "de")
        #expect(ReportLocale.en.exportServerCode(serverAcceptsDutch: false) == "en")
        #expect(ReportLocale.nl.exportServerCode(serverAcceptsDutch: false) == "en")
        #expect(ReportLocale.nl.exportServerCode(serverAcceptsDutch: true) == "nl")
        #expect(ReportLocale.ko.exportServerCode(serverAcceptsDutch: false, serverAcceptsKorean: false) == "en")
        #expect(ReportLocale.ko.exportServerCode(serverAcceptsDutch: false, serverAcceptsKorean: true) == "ko")
        #expect(ReportLocale.ko.exportServerCode(serverAcceptsDutch: false) == "ko")
        let suite = "DoctorReportLanguageTableTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ReportLocale.nl.exportServerCode(defaults: defaults) == "en", "unknown version counts as too old")
        #expect(ReportLocale.ko.exportServerCode(defaults: defaults) == "en", "unknown version counts as too old")
        defaults.set("1.37.31", forKey: KnownServerVersion.defaultsKey)
        #expect(ReportLocale.ko.exportServerCode(defaults: defaults) == "en")
        defaults.set("1.37.32", forKey: KnownServerVersion.defaultsKey)
        #expect(ReportLocale.ko.exportServerCode(defaults: defaults) == "ko")
        defaults.set("1.43.6", forKey: KnownServerVersion.defaultsKey)
        #expect(ReportLocale.nl.exportServerCode(defaults: defaults) == "en")
        defaults.set("1.43.7", forKey: KnownServerVersion.defaultsKey)
        #expect(ReportLocale.nl.exportServerCode(defaults: defaults) == "nl")
        defaults.set("1.47.0", forKey: KnownServerVersion.defaultsKey)
        #expect(ReportLocale.nl.exportServerCode(defaults: defaults) == "nl")
        #expect(ReportLocale.ko.exportServerCode(defaults: defaults) == "ko")
        #expect(ReportLocale.de.exportServerCode(defaults: defaults) == "de")
    }

    // MARK: - Rendered PDFs

    @Test("a Dutch PDF carries the Dutch labels on its pages, and no German ones")
    func dutchPDFText() async throws {
        let text = try await Self.renderedText(.nl)
        for label in [
            "Artsenrapport",
            "Rapportageperiode",
            "Vitale waarden",
            "Meetwaarde",
            "Gemiddelde",
            "Mediaan",
            "Verloop",
            "Medicatie",
            "Therapietrouw",
            "Stemming",
            "Bloeddruk",
            "Hartslag",
            "geen medisch document"
        ] {
            #expect(text.contains(label), "missing \(label) in the Dutch PDF")
        }
        for german in ["Arztbericht", "Vitalwerte", "Mittelwert", "Einnahmetreue", "Blutdruck", "kein medizinisches"] {
            #expect(!text.contains(german), "German \(german) in the Dutch PDF")
        }
    }

    @Test("the report language wins over the interface language")
    func germanReportUnderEnglishInterface() async throws {
        let text = try await AppLanguage.$pinned.withValue(.en) {
            try await Self.renderedText(.de)
        }
        #expect(text.contains("Arztbericht"))
        #expect(text.contains("Vitalwerte"))
        #expect(text.contains("Blutdruck"))
        #expect(!text.contains("Doctor Report"))
        #expect(!text.contains("Blood pressure"))
    }

    @Test("numbers print with the report language's decimal separator")
    func decimalsFollowTheReport() async throws {
        let german = try await AppLanguage.$pinned.withValue(.en) { try await Self.renderedText(.de) }
        let english = try await AppLanguage.$pinned.withValue(.de) { try await Self.renderedText(.en) }
        // Weight mean 81.55 kg in the fixture, one decimal.
        #expect(german.contains("81,6 kg") || german.contains("81,5 kg"), "German decimals expected")
        #expect(english.contains("81.6 kg") || english.contains("81.5 kg"), "English decimals expected")
    }

    @Test("blood pressure prints its unit once, after the pair")
    func bloodPressureUnitOnce() async throws {
        let text = try await Self.renderedText(.nl)
        #expect(text.contains("121/81 mmHg"))
        #expect(!text.contains("mmHg/"))
        #expect(SectionDrawer.droppingUnit("121 mmHg", of: .bloodPressure) == "121")
        #expect(SectionDrawer.droppingUnit("4", of: .steps) == "4")
    }

    // MARK: - Fixture

    static let periodEnd: Date = {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 5
        comps.day = 16
        comps.hour = 12
        comps.timeZone = TimeZone(identifier: "Europe/Berlin")
        return Calendar(identifier: .gregorian).date(from: comps) ?? Date(timeIntervalSince1970: 1_778_925_600)
    }()

    static func renderedText(_ locale: ReportLocale) async throws -> String {
        let document = try #require(try await PDFDocument(data: renderedData(locale)))
        return (0 ..< document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
    }

    static func renderedData(_ locale: ReportLocale) async throws -> Data {
        let start = periodEnd.addingTimeInterval(-30 * 86400)
        let spec = DoctorReportSpecBuilder.build(
            snapshot: snapshot(),
            periodStart: start,
            periodEnd: periodEnd,
            generatedAt: periodEnd,
            locale: locale
        )
        return try await DoctorReportRenderer().renderData(spec)
    }

    /// Every section, with the metrics whose names run longest in Dutch and
    /// German, so a rendered page shows whether a column clips.
    private static func measurements(day: (Int) -> Date) -> [Measurement] {
        let scalarKinds: [(MetricKind, Double)] = [
            (.pulse, 70), (.weight, 82), (.bodyTemperature, 36.8), (.spo2, 97), (.restingHeartRate, 58),
            (.walkingDoubleSupport, 28), (.respiratoryRate, 14), (.hrv, 42), (.audioExposureHeadphone, 71)
        ]
        var measurements: [Measurement] = []
        for (kind, base) in scalarKinds {
            for offset in 0 ..< 4 {
                let value = kind == .weight ? base - Double(offset) * 0.3 : base + Double(offset)
                measurements.append(Measurement(
                    id: "\(kind.rawValue)\(offset)",
                    kind: kind,
                    recordedAt: day(offset + 2),
                    value: .scalar(value)
                ))
            }
        }
        for offset in 0 ..< 3 {
            measurements.append(Measurement(
                id: "bp\(offset)", kind: .bloodPressure, recordedAt: day(offset + 2),
                value: .bloodPressure(systolic: 120 + Double(offset), diastolic: 80 + Double(offset))
            ))
        }
        return measurements
    }

    static func snapshot() -> DoctorReportSpecBuilder.Snapshot {
        let day: (Int) -> Date = { periodEnd.addingTimeInterval(Double(-$0) * 86400) }
        let measurements = measurements(day: day)
        let meds = [
            Medication(
                id: "m1",
                name: "Lisinopril",
                dose: "5 mg",
                treatmentClass: "ACE-Hemmer",
                schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])
            ),
            Medication(
                id: "m2",
                name: "Levothyroxinenatrium Teva",
                dose: "100 microgram",
                treatmentClass: nil,
                schedule: MedicationSchedule(times: [TimeOfDay(hour: 7, minute: 0), TimeOfDay(hour: 19, minute: 0)])
            )
        ]
        let window = { (taken: Int, missed: Int) in
            ComplianceWindowResult(
                totalExpected: taken + missed, taken: taken, skipped: 0, missed: missed,
                rate: Int((Double(taken) / Double(taken + missed) * 100).rounded()), streak: 0
            )
        }
        let compliance = [
            MedicationComplianceSummaryEntry(medicationId: "m1", compliance7: window(6, 1), compliance30: window(27, 3)),
            MedicationComplianceSummaryEntry(medicationId: "m2", compliance7: window(12, 2), compliance30: window(50, 10))
        ]
        let mood: [MoodEntry] = (0 ..< 8).map { offset in
            MoodEntry(
                id: "md\(offset)",
                recordedAt: day(offset + 1),
                score: 3 + (offset % 3),
                tags: offset.isMultiple(of: 2) ? ["energetic"] : ["tired", "headache"]
            )
        }
        return DoctorReportSpecBuilder.Snapshot(
            patientName: "Anna Fischer",
            fullName: "Anna Wilhelmina van der Heijden-Fischer",
            insurerName: "Zilveren Kruis Achmea Zorgverzekeringen",
            insuranceNumber: "A123456789",
            appVersion: "1.5.0 (300)",
            measurements: measurements,
            medications: meds,
            serverCompliance: compliance,
            moodEntries: mood
        )
    }
}

/// Writes the three fixture PDFs to `HL_REPORT_PDF_DIR` for a person to look
/// at (`TEST_RUNNER_HL_REPORT_PDF_DIR=<dir>` on the xcodebuild line). Without
/// the variable it does nothing, so the suite never writes anywhere.
@MainActor
@Suite("Doctor report — language table, PDF export for review")
struct DoctorReportLanguageTablePDFExport {
    @Test("write de, en, nl fixture PDFs when asked")
    func writePDFs() async throws {
        guard let dir = ProcessInfo.processInfo.environment["HL_REPORT_PDF_DIR"], !dir.isEmpty else { return }
        let folder = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for locale in ReportLocale.allCases {
            let data = try await DoctorReportLanguageTableTests.renderedData(locale)
            try data.write(to: folder.appendingPathComponent("doctor-report-\(locale.rawValue).pdf"))
        }
    }
}
