import Foundation
import PDFKit
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

private typealias Measurement = HealthLog.Measurement

/// T-7 Commit 5 — end-to-end integration: snapshot → builder → renderer →
/// PDFDocument re-load → page-count + footer-disclaimer assertions.
///
/// This is the "would the doctor read this" smoke test. Asserts the
/// rendered PDF carries every expected section page **and** the
/// MDR-locked disclaimer is present in the PDF body (PDFKit-extracted
/// text). Belongs in its own suite so it stays the canonical proof that
/// the whole pipeline still works after any refactor.
@MainActor
@Suite("DoctorReport end-to-end — snapshot → renderer → PDFDocument")
struct DoctorReportEndToEndTests {
    private static let calendar = Calendar(identifier: .gregorian)
    private static let periodEnd = makeDate(2026, 5, 16, 12)
    private static let periodStart = calendar.date(byAdding: .day, value: -30, to: periodEnd) ?? periodEnd

    private static func makeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.timeZone = TimeZone(identifier: "Europe/Berlin")
        // swiftlint:disable:next force_unwrapping
        return Calendar(identifier: .gregorian).date(from: comps)!
    }

    private static func fullSnapshot() -> DoctorReportSpecBuilder.Snapshot {
        let pulses: [Measurement] = (0 ..< 5).map { offset in
            Measurement(
                id: "p\(offset)",
                kind: .pulse,
                recordedAt: makeDate(2026, 5, 10 + offset),
                value: .scalar(70 + Double(offset * 2))
            )
        }
        let bps: [Measurement] = (0 ..< 3).map { offset in
            Measurement(
                id: "bp\(offset)",
                kind: .bloodPressure,
                recordedAt: makeDate(2026, 5, 11 + offset),
                value: .bloodPressure(systolic: 120 + Double(offset), diastolic: 80 + Double(offset))
            )
        }
        let weights: [Measurement] = (0 ..< 4).map { offset in
            Measurement(
                id: "w\(offset)",
                kind: .weight,
                recordedAt: makeDate(2026, 5, 10 + offset),
                value: .scalar(82 - Double(offset) * 0.3)
            )
        }
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
                name: "Metformin",
                dose: "1000 mg",
                treatmentClass: "Biguanid",
                schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0), TimeOfDay(hour: 20, minute: 0)])
            )
        ]
        let intakes: [MedicationIntake] = (0 ..< 10).map { offset in
            MedicationIntake(
                id: "i\(offset)",
                medicationId: offset.isMultiple(of: 2) ? "m1" : "m2",
                scheduledAt: makeDate(2026, 5, 8 + offset / 2),
                takenAt: offset < 7 ? makeDate(2026, 5, 8 + offset / 2, 8) : nil,
                status: offset < 7 ? .taken : .skipped
            )
        }
        let moodEntries: [MoodEntry] = (0 ..< 8).map { offset in
            MoodEntry(
                id: "md\(offset)",
                recordedAt: makeDate(2026, 5, 9 + offset),
                score: 3 + (offset % 3),
                tags: offset.isMultiple(of: 2) ? ["energetic"] : ["tired", "headache"]
            )
        }
        return DoctorReportSpecBuilder.Snapshot(
            patientName: "Anna Fischer",
            appVersion: "0.5.0 (8)",
            measurements: pulses + bps + weights,
            medications: meds,
            compliance: [],
            intakes: intakes,
            moodEntries: moodEntries
        )
    }

    // MARK: - Round-trip

    @Test("Full snapshot → renderer → PDFDocument reload yields 6 pages (DE)")
    func endToEndDE() async throws {
        let spec = DoctorReportSpecBuilder.build(
            snapshot: Self.fullSnapshot(),
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd,
            generatedAt: Self.periodEnd,
            locale: .de
        )
        let renderer = DoctorReportRenderer()
        let data = try await renderer.renderData(spec)
        let document = try #require(PDFDocument(data: data))
        // cover + vitals + charts + medications + adherence + mood
        #expect(document.pageCount == 6)
    }

    @Test("Full snapshot → renderer → PDFDocument reload yields 6 pages (EN)")
    func endToEndEN() async throws {
        let spec = DoctorReportSpecBuilder.build(
            snapshot: Self.fullSnapshot(),
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd,
            generatedAt: Self.periodEnd,
            locale: .en
        )
        let renderer = DoctorReportRenderer()
        let data = try await renderer.renderData(spec)
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount == 6)
    }

    // MARK: - Footer disclaimer presence (MDR boundary)

    @Test("DE disclaimer appears in every page of the rendered PDF")
    func footerDisclaimerPresentOnEveryPageDE() async throws {
        let spec = DoctorReportSpecBuilder.build(
            snapshot: Self.fullSnapshot(),
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd,
            locale: .de
        )
        let renderer = DoctorReportRenderer()
        let data = try await renderer.renderData(spec)
        let document = try #require(PDFDocument(data: data))
        for index in 0 ..< document.pageCount {
            let page = try #require(document.page(at: index))
            let text = page.string ?? ""
            #expect(
                text.contains("Lokaler Export"),
                "page \(index) is missing the DE disclaimer"
            )
            #expect(
                text.contains("kein medizinisches Dokument"),
                "page \(index) is missing the DE 'not a medical document' marker"
            )
        }
    }

    @Test("EN disclaimer appears in every page of the rendered PDF")
    func footerDisclaimerPresentOnEveryPageEN() async throws {
        let spec = DoctorReportSpecBuilder.build(
            snapshot: Self.fullSnapshot(),
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd,
            locale: .en
        )
        let renderer = DoctorReportRenderer()
        let data = try await renderer.renderData(spec)
        let document = try #require(PDFDocument(data: data))
        for index in 0 ..< document.pageCount {
            let page = try #require(document.page(at: index))
            let text = page.string ?? ""
            #expect(
                text.contains("Local export"),
                "page \(index) is missing the EN disclaimer"
            )
            #expect(
                text.contains("not a medical document"),
                "page \(index) is missing the EN 'not a medical document' marker"
            )
        }
    }

    @Test("Patient name appears on cover page (visible only — not in metadata)")
    func patientNameOnCoverNotInMetadata() async throws {
        let spec = DoctorReportSpecBuilder.build(
            snapshot: Self.fullSnapshot(),
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd,
            locale: .de
        )
        let renderer = DoctorReportRenderer()
        let data = try await renderer.renderData(spec)
        let document = try #require(PDFDocument(data: data))
        // Cover page is page 0 — patient name visible in body.
        let cover = try #require(document.page(at: 0))
        #expect(cover.string?.contains("Anna Fischer") == true)
        // Metadata MUST NOT contain the patient name.
        let attrs = try #require(document.documentAttributes)
        for (_, value) in attrs {
            if let string = value as? String {
                #expect(!string.contains("Anna Fischer"), "metadata leaked patient name into \(string)")
            }
        }
    }

    // MARK: - Empty-data round-trip

    @Test("Empty snapshot still produces a 1-page cover PDF with disclaimer")
    func emptySnapshotCoverOnly() async throws {
        let snapshot = DoctorReportSpecBuilder.Snapshot(
            patientName: "",
            appVersion: "0.0.0",
            measurements: [],
            medications: [],
            compliance: [],
            intakes: [],
            moodEntries: []
        )
        let spec = DoctorReportSpecBuilder.build(
            snapshot: snapshot,
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd,
            locale: .de
        )
        let renderer = DoctorReportRenderer()
        let data = try await renderer.renderData(spec)
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount == 1)
        let cover = try #require(document.page(at: 0))
        let text = cover.string ?? ""
        #expect(text.contains("Lokaler Export"))
    }

    // MARK: - Persistence round-trip

    @Test("render(_:) writes to temp dir + reload via PDFDocument(url:) works")
    func renderWritesAndReloadsViaURL() async throws {
        let spec = DoctorReportSpecBuilder.build(
            snapshot: Self.fullSnapshot(),
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd,
            locale: .de
        )
        let renderer = DoctorReportRenderer()
        let url = try await renderer.render(spec)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount == 6)
        // Verify disclaimer survived the disk round-trip.
        let cover = try #require(document.page(at: 0))
        #expect(cover.string?.contains("Lokaler Export") == true)
    }
}
