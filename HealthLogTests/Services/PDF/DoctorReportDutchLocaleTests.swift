import Foundation
@testable import HealthLog
import Testing

/// Dutch as the third report language. Before, `ReportLocale` knew only DE and
/// EN and the sharing screen mapped every non-English reader to `.de`, so a
/// Dutch interface produced a German doctor report.
@Suite("Doctor report — Dutch locale")
struct DoctorReportDutchLocaleTests {
    // MARK: - Locale gate

    @Test("ReportLocale ships one case per interface language")
    func oneCasePerInterfaceLanguage() {
        #expect(ReportLocale.allCases == [.de, .en, .nl])
        #expect(AppLanguage.allCases.map { ReportLocale($0) } == ReportLocale.allCases)
    }

    @Test("NL formats dates and numbers as nl_NL")
    func dutchFoundationIdentifier() {
        #expect(ReportLocale.nl.foundationIdentifier == "nl_NL")
        #expect(ReportLocale.nl.bcp47 == "nl")
    }

    @Test("the sharing screen's locale code resolves to the matching report language")
    func serverCodeMapsToReportLocale() {
        #expect(ReportLocale(AppLanguage.resolve("nl")) == .nl)
        #expect(ReportLocale(AppLanguage.resolve("nl-BE")) == .nl)
        #expect(ReportLocale(AppLanguage.resolve("de")) == .de)
        #expect(ReportLocale(AppLanguage.resolve("en")) == .en)
        // An unknown code reads English, as the interface does; never German.
        #expect(ReportLocale(AppLanguage.resolve("fr")) == .en)
    }

    // MARK: - Labels

    @Test("the cover and section titles are Dutch")
    func dutchLabels() {
        #expect(LocaleText.coverTitle(for: .nl) == "Artsenrapport")
        #expect(PDFMeta.title(for: .nl) == "Artsenrapport")
        #expect(LocaleText.coverPatientLabel(for: .nl) == "Patiënt")
        #expect(LocaleText.coverFullNameLabel(for: .nl) == "Volledige naam")
        #expect(LocaleText.coverInsurerLabel(for: .nl) == "Zorgverzekeraar")
        #expect(LocaleText.coverInsuranceNumberLabel(for: .nl) == "Verzekeringsnummer")
        #expect(LocaleText.coverPeriodLabel(for: .nl) == "Rapportageperiode")
        #expect(LocaleText.coverGeneratedLabel(for: .nl) == "Aangemaakt op")
        #expect(LocaleText.coverVersionLabel(for: .nl) == "App-versie")
        #expect(LocaleText.vitalsTitle(for: .nl) == "Vitale waarden")
        #expect(LocaleText.colKind(for: .nl) == "Meetwaarde")
        #expect(LocaleText.colMean(for: .nl) == "Gemiddelde")
        #expect(LocaleText.colMedian(for: .nl) == "Mediaan")
        #expect(LocaleText.chartsTitle(for: .nl) == "Verloop")
        #expect(LocaleText.medicationsTitle(for: .nl) == "Medicatie")
        #expect(LocaleText.medicationsArchived(for: .nl) == "Eerder gebruikt")
        #expect(LocaleText.adherenceTitle(for: .nl) == "Therapietrouw")
        #expect(LocaleText.moodTitle(for: .nl) == "Stemming")
        #expect(LocaleText.moodTagsLabel(for: .nl) == "Meest gebruikte tags")
    }

    @Test("the mood summary keeps the German and English format specifiers")
    func moodFormatSpecifiersMatch() throws {
        let specifier = try Regex("%[0-9.]*[a-zA-Z@]")
        let specifiers = { (locale: ReportLocale) -> [String] in
            let format = LocaleText.moodSummaryFormat(for: locale)
            return format.matches(of: specifier).map { String(format[$0.range]) }
        }
        #expect(specifiers(.nl) == specifiers(.de))
        #expect(specifiers(.nl) == specifiers(.en))
        let summary = String(
            format: LocaleText.moodSummaryFormat(for: .nl),
            locale: Locale(identifier: ReportLocale.nl.foundationIdentifier),
            8,
            3.5
        )
        #expect(summary == "8 registraties, gemiddeld 3,5 / 5")
    }

    @Test("the report period reads 'tot' between two Dutch dates")
    func dutchDateRange() throws {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 5
        comps.day = 16
        comps.hour = 12
        let calendar = Calendar(identifier: .gregorian)
        let end = try #require(calendar.date(from: comps))
        let start = try #require(calendar.date(byAdding: .day, value: -30, to: end))
        let range = DateRangeFormatter.format(start: start, end: end, locale: .nl)
        #expect(range.contains(" tot "))
        #expect(range.contains("mei"), "nl_NL month name expected in \(range)")
    }

    // MARK: - Adherence wording

    @Test("adherence sentences are Dutch and keep their figures")
    func dutchAdherence() {
        let row = DoctorReportSpec.AdherenceBlock.Row(
            medicationId: "med-1",
            medicationName: "Levothyroxine",
            applicable: true,
            rate: 90,
            taken: 27,
            expected: 30
        )
        let line = LocaleText.adherenceRow(row, windowDays: 30, locale: .nl)
        #expect(line.hasPrefix("Levothyroxine: 27 van 30 ingenomen ("))
        #expect(line.hasSuffix(") in 30 dagen"))
        #expect(LocaleText.adherenceSource(windowDays: 30, locale: .nl).hasPrefix("Therapietrouw over de afgelopen 30 dagen"))
        #expect(LocaleText.adherenceWindowMismatch(windowDays: 30, periodDays: 90, locale: .nl).contains("90 dagen"))
        #expect(LocaleText.adherenceUnavailable(for: .nl).hasPrefix("Therapietrouw niet beschikbaar"))
    }

    @Test("a medication without a schedule is named, never printed as 0 %")
    func dutchAdherenceNotApplicable() {
        let row = DoctorReportSpec.AdherenceBlock.Row(
            medicationId: "med-1",
            medicationName: "Levothyroxine",
            applicable: false,
            rate: nil,
            taken: nil,
            expected: nil
        )
        let line = LocaleText.adherenceRow(row, windowDays: 30, locale: .nl)
        #expect(!line.contains("%"))
        #expect(line.contains("geen innameschema"))
    }
}
