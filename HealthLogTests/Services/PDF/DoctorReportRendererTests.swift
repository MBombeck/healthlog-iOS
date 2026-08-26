import Foundation
import PDFKit
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Disambiguate from Foundation.Measurement<Unit>.
private typealias Measurement = HealthLog.Measurement

/// T-7 Commit 2 — `DoctorReportRenderer` actor.
///
/// Covers paginate(), metadata sanitization, deterministic page-count,
/// and the basic cover + vitals draw path. Charts + medications +
/// mood + adherence sections each ship a single page in this commit
/// (placeholder rendering for charts); Commit 3 lands the full
/// chart-image rendering hop.
@Suite("DoctorReportRenderer — pagination + metadata")
struct DoctorReportRendererTests {
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

    @MainActor
    private static func buildCoverOnlySpec(locale: ReportLocale = .de) -> DoctorReportSpec {
        DoctorReportSpecBuilder.build(
            snapshot: DoctorReportSpecBuilder.Snapshot(
                patientName: "Anna Fischer",
                appVersion: "0.5.0",
                measurements: [],
                medications: [],
                compliance: [],
                intakes: [],
                moodEntries: []
            ),
            periodStart: periodStart,
            periodEnd: periodEnd,
            locale: locale
        )
    }

    @MainActor
    private static func buildVitalsSpec() -> DoctorReportSpec {
        let pulses: [Measurement] = (0 ..< 3).map { offset in
            Measurement(
                id: "p\(offset)",
                kind: .pulse,
                recordedAt: makeDate(2026, 5, 10 + offset),
                value: .scalar(70 + Double(offset * 5))
            )
        }
        return DoctorReportSpecBuilder.build(
            snapshot: DoctorReportSpecBuilder.Snapshot(
                patientName: "Anna Fischer",
                appVersion: "0.5.0",
                measurements: pulses,
                medications: [],
                compliance: [],
                intakes: [],
                moodEntries: []
            ),
            periodStart: periodStart,
            periodEnd: periodEnd
        )
    }

    @MainActor
    private static func buildFullSpec() -> DoctorReportSpec {
        let pulses: [Measurement] = (0 ..< 3).map { offset in
            Measurement(
                id: "p\(offset)",
                kind: .pulse,
                recordedAt: makeDate(2026, 5, 10 + offset),
                value: .scalar(72)
            )
        }
        let med = Medication(
            id: "m1",
            name: "Lisinopril",
            dose: "5 mg",
            treatmentClass: "ACE-Hemmer",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])
        )
        let intake = MedicationIntake(
            id: "i1",
            medicationId: "m1",
            scheduledAt: makeDate(2026, 5, 12),
            takenAt: makeDate(2026, 5, 12, 8),
            status: .taken
        )
        let moodEntries = [
            MoodEntry(id: "md1", recordedAt: makeDate(2026, 5, 11), score: 4, tags: ["happy"])
        ]
        return DoctorReportSpecBuilder.build(
            snapshot: DoctorReportSpecBuilder.Snapshot(
                patientName: "Anna Fischer",
                appVersion: "0.5.0",
                measurements: pulses,
                medications: [med],
                compliance: [],
                intakes: [intake],
                moodEntries: moodEntries
            ),
            periodStart: periodStart,
            periodEnd: periodEnd
        )
    }

    // MARK: - paginate()

    @Test("paginate emits exactly cover page when snapshot is empty")
    @MainActor
    func paginateEmptySnapshotIsCoverOnly() async {
        let spec = Self.buildCoverOnlySpec()
        let renderer = DoctorReportRenderer()
        let pages = await renderer.paginate(spec: spec)
        #expect(pages.count == 1)
        if case .cover = pages[0] {
            // ok
        } else {
            Issue.record("first page must be cover")
        }
    }

    @Test("paginate emits cover + vitals when vitals exist")
    @MainActor
    func paginateCoverPlusVitals() async {
        let spec = Self.buildVitalsSpec()
        let renderer = DoctorReportRenderer()
        let pages = await renderer.paginate(spec: spec)
        // cover + vitals + charts (auto-built from same measurements)
        #expect(pages.count == 3)
    }

    @Test("paginate emits one page per non-nil section")
    @MainActor
    func paginateOnePagePerSection() async {
        let spec = Self.buildFullSpec()
        let renderer = DoctorReportRenderer()
        let pages = await renderer.paginate(spec: spec)
        // cover + vitals + charts + medications + adherence + mood = 6
        #expect(pages.count == 6)
    }

    @Test("paginate drops sections that are nil in the spec")
    @MainActor
    func paginateSkipsDeselectedSections() async {
        let pulses: [Measurement] = [Measurement(
            id: "p1",
            kind: .pulse,
            recordedAt: Self.makeDate(2026, 5, 12),
            value: .scalar(72)
        )]
        let selection = DoctorReportSectionSelection(
            vitals: true,
            charts: false,
            medications: false,
            adherence: false,
            mood: false
        )
        let spec = DoctorReportSpecBuilder.build(
            snapshot: DoctorReportSpecBuilder.Snapshot(
                patientName: "Anna Fischer",
                appVersion: "0.5.0",
                measurements: pulses,
                medications: [],
                compliance: [],
                intakes: [],
                moodEntries: []
            ),
            periodStart: Self.periodStart,
            periodEnd: Self.periodEnd,
            selection: selection
        )
        let renderer = DoctorReportRenderer()
        let pages = await renderer.paginate(spec: spec)
        // cover + vitals only
        #expect(pages.count == 2)
    }

    // MARK: - renderData()

    @Test("renderData produces a non-empty PDF that PDFDocument can parse")
    @MainActor
    func renderDataIsPDFParseable() async throws {
        let spec = Self.buildFullSpec()
        let renderer = DoctorReportRenderer()
        let data = try await renderer.renderData(spec)
        #expect(!data.isEmpty)
        let document = try #require(PDFDocument(data: data))
        // 6 sections (cover/vitals/charts/medications/adherence/mood).
        #expect(document.pageCount == 6)
    }

    @Test("renderData metadata: Creator + Author are 'HealthLog' (PII-safe)")
    @MainActor
    func renderMetadataIsSanitized() async throws {
        let spec = Self.buildCoverOnlySpec()
        let renderer = DoctorReportRenderer()
        let data = try await renderer.renderData(spec)
        let document = try #require(PDFDocument(data: data))
        let attrs = try #require(document.documentAttributes)
        let creator = attrs[PDFDocumentAttribute.creatorAttribute] as? String
        let author = attrs[PDFDocumentAttribute.authorAttribute] as? String
        #expect(creator == "HealthLog")
        #expect(author == "HealthLog")
        // Patient name MUST NOT be in metadata — only on the visible cover.
        if let subject = attrs[PDFDocumentAttribute.subjectAttribute] as? String {
            #expect(!subject.contains("Anna Fischer"))
        }
    }

    @Test("renderData is deterministic across two calls for the same spec")
    @MainActor
    func renderDeterministicPageCount() async throws {
        let spec = Self.buildFullSpec()
        let renderer = DoctorReportRenderer()
        let data1 = try await renderer.renderData(spec)
        let data2 = try await renderer.renderData(spec)
        let doc1 = try #require(PDFDocument(data: data1))
        let doc2 = try #require(PDFDocument(data: data2))
        #expect(doc1.pageCount == doc2.pageCount)
    }

    // MARK: - render() + file persistence

    @Test("render writes a temp file we can re-open via PDFDocument(url:)")
    @MainActor
    func renderWritesValidPDFToTempDir() async throws {
        let spec = Self.buildCoverOnlySpec()
        let renderer = DoctorReportRenderer()
        let url = try await renderer.render(spec)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(url.lastPathComponent.hasPrefix("healthlog-doctor-report-"))
        #expect(url.pathExtension == "pdf")
        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount == 1)
    }

    @Test("render writes the file under FileManager.default.temporaryDirectory")
    @MainActor
    func renderTargetsTempDir() async throws {
        let spec = Self.buildCoverOnlySpec()
        let renderer = DoctorReportRenderer()
        let url = try await renderer.render(spec)
        defer { try? FileManager.default.removeItem(at: url) }
        let tempPath = FileManager.default.temporaryDirectory.standardizedFileURL.path
        #expect(url.standardizedFileURL.path.hasPrefix(tempPath))
    }

    // MARK: - PageElement Sendable conformance (compile-time)

    @Test("PageElement values can be carried across actor isolation")
    @MainActor
    func pageElementIsSendable() async {
        // Compile-time guarantee — if `PageElement` were not Sendable,
        // the actor.paginate(_:) declaration would not type-check. This
        // test exercises the boundary at runtime to keep the intent
        // visible in CI output.
        let spec = Self.buildCoverOnlySpec()
        let renderer = DoctorReportRenderer()
        let pages = await renderer.paginate(spec: spec)
        let receivedCount: Int = pages.count
        #expect(receivedCount == 1)
    }
}
