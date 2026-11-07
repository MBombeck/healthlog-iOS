import Foundation
@testable import HealthLog
import PDFKit
import Testing

/// **L10N-REPORT (1.5) — the report language on the sharing screen.**
///
/// The PDF starts in the interface language and can be switched under
/// "Advanced". The same value goes to the server report and to the on-device
/// one, so an English reader can hand a German report to a doctor in Germany.
@MainActor
@Suite("UnifiedSharing — report language", .serialized, .mockURLSession)
struct UnifiedSharingReportLanguageTests {
    private typealias Inputs = SharingWireFixtureTests.Inputs

    private func makeStore(api: APIClient) -> UnifiedSharingStore {
        UnifiedSharingStore(
            profile: ReportSelectionStore(
                capabilities: ServerCapabilitiesRepository(api: api),
                profiles: ReportSelectionRepository(api: api)
            ),
            form: .pdf,
            now: { Inputs.anchor },
            calendar: Inputs.calendar
        )
    }

    private func makeLocalStore() throws -> LocalDoctorReportStore {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let suite = "UnifiedSharingReportLanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return LocalDoctorReportStore(
            measurementsStore: MeasurementsStore(repo: MeasurementsRepository(api: api, outbox: outbox)),
            medicationsStore: MedicationsStore(repo: MedicationsRepository(api: api, outbox: outbox)),
            moodStore: MoodStore(repo: MoodRepository(api: api, outbox: outbox)),
            settingsStore: SettingsStore(repo: SettingsRepository(api: api), defaults: defaults),
            now: { Inputs.anchor }
        )
    }

    private func context(
        store: UnifiedSharingStore,
        api: APIClient,
        local: LocalDoctorReportStore,
        reachable: Bool
    ) throws -> UnifiedSharingStore.OutputContext {
        try UnifiedSharingStore.OutputContext(
            exportStore: SharingWire.makeExportStore(api: api),
            reportStore: DoctorReportStore(service: DoctorReportService(api: api)),
            localReportStore: local,
            linkStore: ShareLinkStore(
                repo: ShareLinkRepository(api: api),
                capabilities: ServerCapabilitiesRepository(api: api)
            ),
            snapshot: DoctorReportSpecBuilder.Snapshot(
                patientName: "Anna", appVersion: "1.5.0 (1)", measurements: [], medications: [], moodEntries: []
            ),
            // Exactly what the screen passes.
            locale: store.reportLanguage.rawValue,
            isBackendReachable: reachable
        )
    }

    private func stubSelectionReads(pdf recorder: WireRecorder? = nil) {
        MockURLProtocol.install { req in
            if req.url?.path == "/api/meta/capabilities" {
                return SharingWire.jsonOK(req, SharingWire.capabilitiesJSON(leaves: Inputs.vocabulary))
            }
            if req.url?.path == "/api/export/health-record" {
                recorder?.record(req)
                return SharingWire.binaryOK(req, contentType: "application/pdf", bytes: Data("%PDF-1.4".utf8))
            }
            return SharingWire.jsonOK(req, #"{"profile":null}"#)
        }
    }

    @Test("the report language starts as the interface language")
    func startsAsInterfaceLanguage() {
        for language in AppLanguage.allCases {
            let store = AppLanguage.$pinned.withValue(language) { makeStore(api: SharingWire.makeAPI()) }
            #expect(store.reportLanguage == ReportLocale(language))
        }
    }

    @Test("an English reader makes a German report on the device")
    func englishReaderGermanLocalReport() async throws {
        stubSelectionReads()
        let api = SharingWire.makeAPI()
        let local = try makeLocalStore()
        let store = AppLanguage.$pinned.withValue(.en) { makeStore(api: api) }
        await store.load()
        store.selectAll()
        #expect(store.reportLanguage == .en)
        store.reportLanguage = .de
        let ctx = try context(store: store, api: api, local: local, reachable: false)
        await AppLanguage.$pinned.withValue(.en) { await store.produce(ctx) }
        #expect(store.outcome == .produced)
        let url = try #require(local.pdfURL)
        defer { try? FileManager.default.removeItem(at: url) }
        let cover = try #require(PDFDocument(url: url)?.page(at: 0)?.string)
        #expect(cover.contains("Arztbericht"))
        #expect(cover.contains("Berichtszeitraum"))
        #expect(!cover.contains("Doctor Report"))
    }

    @Test("an English reader asks the server for a German report")
    func englishReaderGermanServerReport() async throws {
        let recorder = WireRecorder()
        stubSelectionReads(pdf: recorder)
        let api = SharingWire.makeAPI()
        let store = AppLanguage.$pinned.withValue(.en) { makeStore(api: api) }
        await store.load()
        store.selectAll()
        store.reportLanguage = .de
        let ctx = try context(store: store, api: api, local: makeLocalStore(), reachable: true)
        await store.produce(ctx)
        #expect(store.outcome == .produced)
        #expect(store.artifactSource == .server)
        let body = try #require(recorder.captured?.body)
        #expect(body.contains(#""locale":"de""#), "body: \(body)")
    }
}
