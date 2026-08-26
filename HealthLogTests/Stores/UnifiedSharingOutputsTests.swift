import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **Phase 18 / 18-02 — the four outputs run from one state, and the wire does
/// not move.**
///
/// Each case drives the SAME service or store the corresponding old card drove,
/// with the request values the unified model produces, and compares what
/// `URLSession` received against the fixture
/// `SharingWireFixtureTests` captured from the untouched implementation in
/// `e9bfe8c5` — before anything was rewired. Consolidating the questions must
/// not consolidate the contracts.
///
/// The inputs are `SharingWireFixtureTests.Inputs` verbatim, including its UTC
/// calendar, so "identical inputs → identical bytes" is a claim about the same
/// inputs on both sides rather than a claim about two different ones.
@MainActor
@Suite("UnifiedSharingOutputs", .serialized)
struct UnifiedSharingOutputsTests {
    private typealias Inputs = SharingWireFixtureTests.Inputs

    /// A store loaded against the fixture vocabulary, with everything the
    /// current form may carry selected and the fixed inputs applied.
    private func makeLoadedStore(
        form: UnifiedSharingStore.OutputForm,
        selectAll: Bool = true
    ) async -> UnifiedSharingStore {
        let api = SharingWire.makeAPI()
        let store = UnifiedSharingStore(
            profile: ReportSelectionStore(
                capabilities: ServerCapabilitiesRepository(api: api),
                profiles: ReportSelectionRepository(api: api)
            ),
            form: form,
            now: { Inputs.anchor },
            calendar: Inputs.calendar
        )
        await store.load()
        if selectAll { store.selectAll() }
        store.periodDays = Inputs.periodDays
        store.includeCharts = Inputs.includeCharts
        store.linkLabel = Inputs.linkLabel
        store.practiceName = Inputs.practiceName
        store.expiresAt = Inputs.expiresAt
        return store
    }

    /// The capabilities + profile reads every loaded store makes, answered with
    /// the fixture vocabulary and no saved profile (so nothing is preselected).
    private func stubSelectionReads(recorder: WireRecorder? = nil) {
        MockURLProtocol.handler = { req in
            recorder?.record(req)
            if req.url?.path == "/api/meta/capabilities" {
                return SharingWire.jsonOK(req, SharingWire.capabilitiesJSON(leaves: Inputs.vocabulary))
            }
            return SharingWire.jsonOK(req, #"{"profile":null}"#)
        }
    }

    // MARK: - 1. PDF

    @Test("Der Bericht (PDF) fährt aus dem einen Zustand — und die Leitung bleibt, wie sie war")
    func pdfMatchesFixture() async {
        stubSelectionReads()
        let store = await makeLoadedStore(form: .pdf)

        let recorder = WireRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return SharingWire.binaryOK(req, contentType: "application/pdf", bytes: Data("%PDF-1.4".utf8))
        }
        var violations: [String] = []
        if let arguments = store.pdfArguments(locale: Inputs.locale) {
            let reportStore = DoctorReportStore(service: DoctorReportService(api: SharingWire.makeAPI()))
            await reportStore.generate(
                days: arguments.days,
                locale: arguments.locale,
                selection: arguments.selection,
                practiceName: arguments.practiceName
            )
            reportStore.clearOnLogout()
        } else {
            violations.append("the model produced no PDF arguments")
        }
        violations += Self.fixtureViolations(recorder.captured, named: "pdf")

        #expect(
            violations.isEmpty,
            """
            EXPECTED_RED: the unified model does not yet drive the PDF export

            The PDF and the ZIP are the same server route differing in `format`; consolidating \
            the questions must not consolidate the contracts. Offen: \(violations)
            """
        )
    }

    // MARK: - 2. ZIP

    @Test("Die Akte (ZIP) fährt aus dem einen Zustand — dieselbe Route, nur ein anderes `format`")
    func zipMatchesFixture() async {
        stubSelectionReads()
        let store = await makeLoadedStore(form: .zip)

        let recorder = WireRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return SharingWire.binaryOK(req, contentType: "application/zip", bytes: Data("PK".utf8))
        }
        var violations: [String] = []
        if let request = store.packageRequest() {
            let exportStore = try? SharingWire.makeExportStore(api: SharingWire.makeAPI())
            let url = try? await exportStore?.downloadHealthRecordPackage(request)
            if let url { try? FileManager.default.removeItem(at: url) }
        } else {
            violations.append("the model produced no package request")
        }
        violations += Self.fixtureViolations(recorder.captured, named: "zip")

        #expect(
            violations.isEmpty,
            """
            EXPECTED_RED: the unified model does not yet drive the ZIP export

            The ZIP already contains the PDF and the FHIR bundle; that is why it is one output \
            of one flow and not a fourth surface. Offen: \(violations)
            """
        )
    }

    // MARK: - 3. Link, empty and full

    @Test("Der Link fährt aus dem einen Zustand — leer wie voll, byte-gleich zur Aufnahme")
    func linkMatchesFixture() async {
        var violations: [String] = []
        violations += await linkViolations(selectAll: false, fixture: "link-empty")
        violations += await linkViolations(selectAll: true, fixture: "link-full")

        #expect(
            violations.isEmpty,
            """
            EXPECTED_RED: the unified model does not yet drive link creation

            The empty selection is the documents-only link and the full one is the whole record; \
            both have to leave the device exactly as they did before. Offen: \(violations)
            """
        )
    }

    private func linkViolations(selectAll: Bool, fixture: String) async -> [String] {
        stubSelectionReads()
        let store = await makeLoadedStore(form: .link, selectAll: selectAll)

        let recorder = WireRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return req.httpMethod == "POST"
                ? SharingWire.jsonOK(req, SharingWire.shareLinkResponseJSON)
                : SharingWire.jsonOK(req, SharingWire.shareLinkListJSON)
        }
        var violations: [String] = []
        if let body = store.shareLinkBody() {
            let api = SharingWire.makeAPI()
            let linkStore = ShareLinkStore(
                repo: ShareLinkRepository(api: api),
                capabilities: ServerCapabilitiesRepository(api: api)
            )
            _ = await linkStore.create(body)
        } else {
            violations.append("\(fixture): the model produced no share-link body")
        }
        return violations + Self.fixtureViolations(recorder.captured, named: fixture)
    }

    // MARK: - 4. FHIR

    @Test("Der FHIR-Export fährt aus dem einen Zustand — und erbt das Profil nicht mehr still")
    func fhirMatchesFixture() async {
        let selectionTraffic = WireRecorder()
        stubSelectionReads(recorder: selectionTraffic)
        let store = await makeLoadedStore(form: .fhir)

        let recorder = WireRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            if req.url?.path == "/api/auth/me/report-selection" {
                return SharingWire.jsonOK(
                    req,
                    SharingWire.profileJSON(leaves: Inputs.vocabulary, format: "fhir")
                )
            }
            return SharingWire.jsonOK(
                req,
                #"{"resourceType":"Bundle","type":"searchset","total":0}"#,
                contentType: "application/fhir+json"
            )
        }
        var violations: [String] = []
        // The scope the server applies to `$everything` is the STORED profile —
        // the request itself carries none. Making the FHIR export follow the
        // visible selection therefore means writing it first; that write is the
        // end of the silent inheritance, and it is a different call, not a
        // changed one.
        let saved = await store.prepareFHIRScope()
        if !saved {
            violations.append("the model did not publish the visible selection as the FHIR scope")
        }
        if !recorder.all.contains(where: { $0.method == "PUT" && $0.path == "/api/auth/me/report-selection" }) {
            violations.append("no profile write preceded the bundle fetch")
        }
        _ = try? await ServerFHIREverythingService(api: SharingWire.makeAPI()).fetchEverything()
        let bundleRequest = recorder.all.first { $0.path == "/api/fhir/Patient/$everything" }
        violations += Self.fixtureViolations(bundleRequest, named: "fhir")

        #expect(
            violations.isEmpty,
            """
            EXPECTED_RED: the unified model does not yet drive the FHIR export

            FHIR was the one surface with no selection of its own; it inherited the stored \
            profile invisibly. Offen: \(violations)
            """
        )
    }

    // MARK: - Controls (green from the start)

    @Test("Kontrolle: eine leere Auswahl sagt vor dem Teilen, dass nur Dokumente mitgehen")
    func emptySelectionSaysDocumentsOnly() async {
        stubSelectionReads()
        let store = await makeLoadedStore(form: .link, selectAll: false)

        #expect(store.isDocumentsOnly, "an untouched selection is the documents-only case")
        #expect(store.currentSelection.leaves.isEmpty)
        // 18-01 landed the statement; this control holds it in place while
        // 18-02 wires the button it sits next to.
        let statement = String(localized: "sharing.unified.emptyMeaning")
        #expect(statement != "sharing.unified.emptyMeaning", "the documents-only statement is catalogued")

        store.selectAll()
        #expect(!store.isDocumentsOnly, "select-all leaves the documents-only case")
    }

    @Test("Kontrolle: die aufgenommenen Fixtures beschreiben weiterhin die alten Aufrufstellen")
    func fixturesStillDescribeTheOldCallSites() throws {
        for name in ["pdf", "zip", "link-empty", "link-full", "fhir"] {
            let fixture = try SharingWire.loadFixture(name)
            #expect(!fixture.method.isEmpty, "\(name) records a method")
            #expect(fixture.path.hasPrefix("/api/"), "\(name) records a server path")
        }
        // The two routes the four outputs share, named so a fixture that
        // silently moved to a new endpoint cannot pass this control.
        #expect(try SharingWire.loadFixture("pdf").path == "/api/export/health-record")
        #expect(try SharingWire.loadFixture("zip").path == "/api/export/health-record")
        #expect(try SharingWire.loadFixture("link-full").path == "/api/share-links")
        #expect(try SharingWire.loadFixture("fhir").path == "/api/fhir/Patient/$everything")
    }

    // MARK: - Helpers

    private static func fixtureViolations(_ captured: SharingWire.Capture?, named name: String) -> [String] {
        guard let captured else { return ["\(name): no request reached the wire"] }
        guard let expected = try? SharingWire.loadFixture(name) else {
            return ["\(name): the fixture is missing"]
        }
        guard captured != expected else { return [] }
        var violations = ["\(name): the wire drifted from the fixture"]
        if captured.method != expected.method { violations.append("method \(captured.method)") }
        if captured.path != expected.path { violations.append("path \(captured.path)") }
        if captured.query != expected.query { violations.append("query \(captured.query ?? "nil")") }
        if captured.accept != expected.accept { violations.append("accept \(captured.accept ?? "nil")") }
        if captured.body != expected.body { violations.append("body \(captured.body ?? "nil")") }
        return violations
    }
}
