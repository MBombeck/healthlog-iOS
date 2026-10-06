import Foundation
@testable import HealthLog
import Testing

/// #115 · 1.2 — the doctor report's adherence is the server's cadence-aware
/// `compliance30` (`GET /api/medications/compliance`, `MedicationComplianceSummaryEntry`
/// in `docs/api/openapi.yaml` at `v1.39.0`) with its window stated. Before, the
/// report divided TODAY's intakes by today's slots and printed that as the
/// adherence of a 30- to 365-day period.
@Suite("Doctor report — server adherence (#115 1.2)")
@MainActor
struct DoctorReportServerAdherenceTests {
    private static let periodStart = Date(timeIntervalSince1970: 1_778_000_000)
    private static let periodEnd = periodStart.addingTimeInterval(30 * 86400)

    private static func snapshot(
        medications: [Medication] = [],
        serverCompliance: [MedicationComplianceSummaryEntry]? = nil
    ) -> DoctorReportSpecBuilder.Snapshot {
        DoctorReportSpecBuilder.Snapshot(
            patientName: "Anna Fischer",
            appVersion: "0.5.0",
            measurements: [],
            medications: medications,
            serverCompliance: serverCompliance,
            moodEntries: []
        )
    }

    private static func serverEntry(
        _ id: String, taken: Int, missed: Int, skipped: Int = 0, rate: Int, applicable: Bool? = true
    ) -> MedicationComplianceSummaryEntry {
        let window = ComplianceWindowResult(
            totalExpected: taken + missed + skipped, taken: taken, skipped: skipped,
            missed: missed, rate: rate, streak: 0
        )
        return MedicationComplianceSummaryEntry(
            medicationId: id, compliance7: window, compliance30: window, applicable: applicable
        )
    }

    private static let levothyroxin = Medication(
        id: "med-1",
        name: "Levothyroxin",
        dose: "75 mcg",
        schedule: MedicationSchedule(times: [TimeOfDay(hour: 7, minute: 0)])
    )

    @Test("#115 1.2 — adherence rows are the server's compliance30, not today's intakes over the period")
    func adherenceFromServer() {
        // Server: 27 of 30 over its 30-day window (90 %). The report period
        // is 30 days — no window note.
        let end = Self.periodStart.addingTimeInterval(30 * 86400)
        let spec = DoctorReportSpecBuilder.build(
            snapshot: Self.snapshot(
                medications: [Self.levothyroxin],
                serverCompliance: [Self.serverEntry("med-1", taken: 27, missed: 3, skipped: 2, rate: 90)]
            ),
            periodStart: Self.periodStart,
            periodEnd: end
        )
        let block = spec.adherence
        #expect(block?.availability == .server)
        #expect(block?.perMedication.first?.rate == 90)
        #expect(block?.perMedication.first?.taken == 27)
        #expect(block?.perMedication.first?.expected == 30, "skips leave the denominator, as on the server")
        #expect(block?.windowMatchesPeriod == true)
    }

    @Test("#115 1.2 — a 90-day report says the server window is 30 days instead of computing 90")
    func adherenceWindowMismatchIsStated() throws {
        let end = Self.periodStart.addingTimeInterval(90 * 86400)
        let spec = DoctorReportSpecBuilder.build(
            snapshot: Self.snapshot(
                medications: [Self.levothyroxin],
                serverCompliance: [Self.serverEntry("med-1", taken: 27, missed: 3, rate: 90)]
            ),
            periodStart: Self.periodStart,
            periodEnd: end
        )
        let block = try #require(spec.adherence)
        #expect(block.periodDays == 90)
        #expect(block.windowDays == 30)
        #expect(!block.windowMatchesPeriod)
        let notes = LocaleText.adherenceNotes(for: block, locale: .en)
        #expect(notes.count == 2)
        #expect(notes[1].contains("90"))
    }

    @Test("#115 1.2 — without a server answer the report says adherence is unavailable")
    func adherenceUnavailableWithoutServer() throws {
        let spec = DoctorReportSpecBuilder.build(
            snapshot: Self.snapshot(medications: [Self.levothyroxin], serverCompliance: nil),
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd
        )
        let block = try #require(spec.adherence)
        #expect(block.availability == .unavailable)
        #expect(block.perMedication.isEmpty)
        #expect(LocaleText.adherenceNotes(for: block, locale: .de) == [LocaleText.adherenceUnavailable(for: .de)])
    }

    @Test("#115 1.2 — NO_LOCAL_SCHEDULE is named, never printed as 0 %")
    func adherenceNotApplicable() throws {
        let spec = DoctorReportSpecBuilder.build(
            snapshot: Self.snapshot(
                medications: [Self.levothyroxin],
                serverCompliance: [Self.serverEntry("med-1", taken: 0, missed: 0, rate: 0, applicable: false)]
            ),
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd
        )
        let row = try #require(spec.adherence?.perMedication.first)
        #expect(row.applicable == false)
        #expect(row.rate == nil)
        // F1 — English now writes "0%" (no gap), so the guard checks for any
        // percent sign, not one spelling of it.
        #expect(!LocaleText.adherenceRow(row, windowDays: 30, locale: .en).contains("%"))
        #expect(!LocaleText.adherenceRow(row, windowDays: 30, locale: .de).contains("%"))
    }
}
