import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **The wire-invariance spine.**
///
/// The consolidation's core risk is that a UI refactor quietly changes what the
/// server receives. The guard is this file plus the fixtures beside it: the
/// request each of the four **current** implementations produces for a fixed
/// set of inputs, captured BEFORE the unified surface drives anything, and
/// committed. `UnifiedSharingOutputsTests` then asserts the unified model
/// produces byte-identical requests for the same inputs.
///
/// A fixture recorded after the change would prove only that the new code
/// agrees with itself, so the capture order is the whole point:
///
///  1. this suite runs against the untouched call sites,
///  2. the fixtures are written from what it captured,
///  3. only then is anything rewired.
///
/// **Nothing here is a mock server.** Every case drives the real service /
/// store / repository over the real `APIClient` with a stubbed `URLSession`
/// (`MockURLProtocol`), exactly as the project doctrine requires, so the
/// captured bytes are the bytes `URLSession` would have put on the wire.
///
/// Two of the four original call sites lived inside SwiftUI `View`s
/// (`CreateShareLinkSheet.submit()`, `HealthRecordExportScreen.run(_:)`), so
/// this suite reproduces how they built their request. Both views are gone;
/// `UnifiedSharingOutputsTests` holds the unified surface to these fixtures.
@MainActor
@Suite("SharingWireFixtures", .serialized, .mockURLSession)
struct SharingWireFixtureTests {
    // MARK: - The fixed inputs every fixture was captured with

    enum Inputs {
        /// 2023-11-14T22:13:20Z. Fixed so every date on the wire is a constant.
        static let anchor = Date(timeIntervalSince1970: 1_700_000_000)

        /// **A UTC calendar, and the fixtures depend on it.** Both the old call
        /// site and the unified model derive `rangeStart` / `expiresAt` by
        /// adding days to a reference, and day arithmetic in a DST-observing
        /// zone is not a constant number of seconds — captured in Europe/Berlin
        /// the 90-day rollback lands an hour off the anchor. Production keeps
        /// `Calendar.current` (that is today's behaviour and it must not
        /// change); the fixtures pin a zone so the committed bytes mean the
        /// same thing on any machine that verifies them.
        static let calendar: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            return calendar
        }()

        static let periodDays = 90
        static let locale = "de"
        static let practiceName = "Praxis Test"
        static let includeCharts = true
        static let linkLabel = "Dr. Test"
        static let expiryDays = 30

        /// The test vocabulary, in catalogue order. Production never carries a
        /// list like this — it reads `capabilities.share.leaves`.
        static let vocabulary = ["WEIGHT", "PULSE", "LAB_RESULTS", "MEDICATION_LIST", "MOOD", "INSURANCE"]

        /// What the export route may carry: everything.
        static var exportSelection: ReportSelection {
            ReportSelection(leaves: vocabulary)
        }

        /// What a share link may carry: everything the route does not refuse.
        static var linkSelection: ReportSelection {
            ReportSelection(leaves: ShareLinkSelectionPolicy.offeredLeaves(from: vocabulary))
        }

        static var rangeStart: Date {
            calendar.date(byAdding: .day, value: -periodDays, to: anchor)!
        }

        static var expiresAt: Date {
            calendar.date(byAdding: .day, value: expiryDays, to: anchor)!
        }
    }

    // MARK: - Cases

    @Test("the current PDF call site sends what pdf.json records")
    func pdfCallSiteMatchesFixture() async throws {
        let recorder = WireRecorder()
        MockURLProtocol.install { req in
            recorder.record(req)
            return SharingWire.binaryOK(req, contentType: "application/pdf", bytes: Data("%PDF-1.4".utf8))
        }
        let store = DoctorReportStore(service: DoctorReportService(api: SharingWire.makeAPI()))
        await store.generate(
            days: Inputs.periodDays,
            locale: Inputs.locale,
            selection: Inputs.exportSelection,
            practiceName: Inputs.practiceName
        )
        defer { store.clearOnLogout() }

        try SharingWire.assertMatchesFixture(recorder.captured, named: "pdf")
    }

    @Test("the current ZIP call site sends what zip.json records")
    func zipCallSiteMatchesFixture() async throws {
        let recorder = WireRecorder()
        MockURLProtocol.install { req in
            recorder.record(req)
            return SharingWire.binaryOK(req, contentType: "application/zip", bytes: Data("PK".utf8))
        }
        // Transcribed from the former `HealthRecordExportScreen.run(_:)`.
        let request = HealthRecordExportRequest(
            format: .package,
            selection: Inputs.exportSelection,
            range: HealthRecordExportRequest.Range(days: Inputs.periodDays),
            includeCharts: Inputs.includeCharts
        )
        let store = try SharingWire.makeExportStore(api: SharingWire.makeAPI())
        let url = try await store.downloadHealthRecordPackage(request)
        defer { try? FileManager.default.removeItem(at: url) }

        try SharingWire.assertMatchesFixture(recorder.captured, named: "zip")
    }

    @Test("the current link call site sends what link-empty.json records for an empty selection")
    func linkEmptyCallSiteMatchesFixture() async throws {
        try await captureLink(selection: .empty, fixture: "link-empty")
    }

    @Test("the current link call site sends what link-full.json records for a full selection")
    func linkFullCallSiteMatchesFixture() async throws {
        try await captureLink(selection: Inputs.linkSelection, fixture: "link-full")
    }

    @Test("the current FHIR call site sends what fhir.json records")
    func fhirCallSiteMatchesFixture() async throws {
        let recorder = WireRecorder()
        MockURLProtocol.install { req in
            recorder.record(req)
            return SharingWire.jsonOK(
                req,
                #"{"resourceType":"Bundle","type":"searchset","total":0}"#,
                contentType: "application/fhir+json"
            )
        }
        let service = ServerFHIREverythingService(api: SharingWire.makeAPI())
        _ = try await service.fetchEverything()

        try SharingWire.assertMatchesFixture(recorder.captured, named: "fhir")
    }

    // MARK: - Helpers

    private func captureLink(selection: ReportSelection, fixture: String) async throws {
        let recorder = WireRecorder()
        MockURLProtocol.install { req in
            recorder.record(req)
            return req.httpMethod == "POST"
                ? SharingWire.jsonOK(req, SharingWire.shareLinkResponseJSON)
                : SharingWire.jsonOK(req, SharingWire.shareLinkListJSON)
        }
        // Transcribed from the former `CreateShareLinkSheet.submit()`.
        let body = CreateShareLinkBody(
            label: Inputs.linkLabel,
            rangeStart: ShareLinkDateFormat.string(from: Inputs.rangeStart),
            rangeEnd: nil,
            expiresAt: ShareLinkDateFormat.string(from: Inputs.expiresAt),
            selection: selection
        )
        let api = SharingWire.makeAPI()
        let store = ShareLinkStore(
            repo: ShareLinkRepository(api: api),
            capabilities: ServerCapabilitiesRepository(api: api)
        )
        _ = await store.create(body)

        try SharingWire.assertMatchesFixture(recorder.captured, named: fixture)
    }
}
