import Foundation
@testable import HealthLog
import Testing

/// **1.5 VISIT** — the visit's window (`preparation.from` to `.to`) on the
/// sharing surface, at day edges, across both 2026 clock changes in
/// Europe/Berlin and in a zone without one (Asia/Tokyo), and through the store
/// seam into the requests the outputs send.
@MainActor
@Suite("Next visit: report window (VISIT)", .serialized, .mockURLSession)
struct NextVisitWindowTests {
    private typealias Inputs = SharingWireFixtureTests.Inputs

    static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .gmt
        return calendar
    }

    static func instant(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso) ?? .distantPast
    }

    static let berlin = calendar("Europe/Berlin")
    static let tokyo = calendar("Asia/Tokyo")
    /// 2026-11-05 11:00 in Berlin.
    static let now = instant("2026-11-05T10:00:00Z")
    static let visitWindow: ReportWindow = {
        guard let window = ReportWindow(from: "2026-08-12", to: "2026-11-18") else { preconditionFailure("fixture window") }
        return window
    }()

    // MARK: - The window as instants

    @Test("day keys: only real calendar days, never a window that ends before it starts")
    func validation() {
        #expect(ReportWindow(from: "2026-08-12", to: "2026-08-12") != nil)
        #expect(ReportWindow(from: "2026-08-13", to: "2026-08-12") == nil)
        #expect(ReportWindow(from: "2026-02-30", to: "2026-03-01") == nil)
        #expect(ReportWindow(from: "2026-8-12", to: "2026-11-18") == nil)
        #expect(ReportWindow(from: "", to: "2026-11-18") == nil)
        #expect(ReportWindow(from: "2028-02-29", to: "2028-03-01") != nil)
    }

    @Test("Berlin, 25 October 2026: the day of the clock change back is 25 hours long")
    func berlinAutumn() throws {
        let window = try #require(ReportWindow(from: "2026-10-25", to: "2026-10-25"))
        let interval = try #require(window.interval(calendar: Self.berlin, now: Self.now))
        #expect(interval.start == Self.instant("2026-10-24T22:00:00Z"))
        #expect(interval.end == Self.instant("2026-10-25T23:00:00Z"))
        #expect(interval.duration == 25 * 3600)
    }

    @Test("Berlin, 29 March 2026: the day of the clock change forward is 23 hours long")
    func berlinSpring() throws {
        let window = try #require(ReportWindow(from: "2026-03-29", to: "2026-03-29"))
        let interval = try #require(window.interval(calendar: Self.berlin, now: Self.now))
        #expect(interval.start == Self.instant("2026-03-28T23:00:00Z"))
        #expect(interval.end == Self.instant("2026-03-29T22:00:00Z"))
        #expect(interval.duration == 23 * 3600)
    }

    @Test("Tokyo has no clock change: both days are 24 hours", arguments: ["2026-03-29", "2026-10-25"])
    func tokyo(day: String) throws {
        let window = try #require(ReportWindow(from: day, to: day))
        let interval = try #require(window.interval(calendar: Self.tokyo, now: Self.now))
        #expect(interval.duration == 24 * 3600)
        #expect(ReportWindow.instant(interval.start) == "\(Self.previousDay(day))T15:00:00Z")
    }

    private static func previousDay(_ day: String) -> String {
        day == "2026-03-29" ? "2026-03-28" : "2026-10-24"
    }

    @Test("a window into the future stops at now; a window starting after now has no instants")
    func stopsAtNow() throws {
        let interval = try #require(Self.visitWindow.interval(calendar: Self.berlin, now: Self.now))
        #expect(interval.start == Self.instant("2026-08-11T22:00:00Z"))
        #expect(interval.end == Self.now)
        let future = try #require(ReportWindow(from: "2026-11-06", to: "2026-11-18"))
        #expect(future.interval(calendar: Self.berlin, now: Self.now) == nil)
    }

    @Test("day edges: one second before and after local midnight")
    func midnight() throws {
        let window = try #require(ReportWindow(from: "2026-11-05", to: "2026-11-18"))
        // 23:59:59 on the 4th in Berlin: the window has not begun.
        #expect(window.interval(calendar: Self.berlin, now: Self.instant("2026-11-04T22:59:59Z")) == nil)
        // 00:00:01 on the 5th: one second of it.
        let first = try #require(window.interval(calendar: Self.berlin, now: Self.instant("2026-11-04T23:00:01Z")))
        #expect(first.duration == 1)
        // The same instant in Tokyo is already 08:00:01 on the 5th.
        let tokyo = try #require(window.interval(calendar: Self.tokyo, now: Self.instant("2026-11-04T23:00:01Z")))
        #expect(tokyo.start == Self.instant("2026-11-04T15:00:00Z"))
    }

    @Test("the export range carries both edges with an offset")
    func exportRange() throws {
        let range = try #require(Self.visitWindow.exportRange(calendar: Self.berlin, now: Self.now))
        #expect(range.startDate == "2026-08-11T22:00:00Z")
        #expect(range.endDate == "2026-11-05T10:00:00Z")
        #expect(range.days == nil)
    }

    // MARK: - The store seam

    private func makeStore(api: APIClient, form: UnifiedSharingStore.OutputForm = .pdf) -> UnifiedSharingStore {
        UnifiedSharingStore(
            profile: ReportSelectionStore(
                capabilities: ServerCapabilitiesRepository(api: api),
                profiles: ReportSelectionRepository(api: api)
            ),
            form: form,
            now: { Self.now },
            calendar: Self.berlin
        )
    }

    private func stubReads(_ recorder: WireRecorder) {
        MockURLProtocol.install { req in
            if req.url?.path == "/api/meta/capabilities" {
                return SharingWire.jsonOK(req, SharingWire.capabilitiesJSON(leaves: Inputs.vocabulary))
            }
            if req.url?.path == "/api/export/health-record" {
                recorder.record(req)
                let zip = req.value(forHTTPHeaderField: "Accept")?.contains("zip") == true
                return SharingWire.binaryOK(
                    req,
                    contentType: zip ? "application/zip" : "application/pdf",
                    bytes: Data(zip ? "PK".utf8 : "%PDF-1.4".utf8)
                )
            }
            return SharingWire.jsonOK(req, #"{"profile":null}"#)
        }
    }

    @Test("the preset reaches the PDF arguments, the package and the link; the look-back is untouched")
    func presetReachesOutputs() async throws {
        stubReads(WireRecorder())
        let store = makeStore(api: SharingWire.makeAPI())
        await store.load()
        store.selectAll()
        let days = store.periodDays
        store.presetWindow(Self.visitWindow)
        #expect(store.window == Self.visitWindow)
        #expect(store.pdfArguments(locale: "de")?.window == Self.visitWindow)
        #expect(store.periodDays == days)

        store.setOutputForm(.zip)
        let range = try #require(store.packageRequest()?.range)
        #expect(range.startDate == "2026-08-11T22:00:00Z")
        #expect(range.days == nil)

        store.setOutputForm(.link)
        store.linkLabel = "Dr. Weber"
        let link = try #require(store.shareLinkBody())
        #expect(link.rangeStart == "2026-08-11T22:00:00Z")
        #expect(link.rangeEnd == nil)
    }

    @Test("a look-back or FHIR ends the preset; without a preset everything is as before")
    func presetEnds() async {
        stubReads(WireRecorder())
        let store = makeStore(api: SharingWire.makeAPI())
        await store.load()
        store.selectAll()
        #expect(store.pdfArguments(locale: "de")?.window == nil)
        #expect(store.exportRange.days == store.periodDays)

        store.presetWindow(Self.visitWindow)
        store.chooseLookBack(30)
        #expect(store.window == nil)
        #expect(store.periodDays == 30)

        store.presetWindow(Self.visitWindow)
        store.setOutputForm(.fhir)
        #expect(store.window == nil)
        store.presetWindow(Self.visitWindow)
        #expect(store.window == nil, "FHIR cannot carry a window")
    }

    @Test("the server PDF asks for the window, not for days")
    func serverPDFBody() async throws {
        let recorder = WireRecorder()
        stubReads(recorder)
        let api = SharingWire.makeAPI()
        let store = makeStore(api: api)
        await store.load()
        store.selectAll()
        store.presetWindow(Self.visitWindow)
        let reportStore = DoctorReportStore(service: DoctorReportService(api: api))
        let arguments = try #require(store.pdfArguments(locale: "de"))
        await reportStore.generate(
            days: arguments.days,
            locale: arguments.locale,
            selection: arguments.selection,
            practiceName: arguments.practiceName,
            range: store.exportRange
        )
        if let url = reportStore.pdfURL { try? FileManager.default.removeItem(at: url) }
        let body = try #require(recorder.captured?.body)
        #expect(body.contains(#""range":{"endDate":"2026-11-05T10:00:00Z","startDate":"2026-08-11T22:00:00Z"}"#), "body: \(body)")
    }

    @Test("the on-device report covers the window and the compliance read reaches back to its start")
    func localReportWindow() throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let defaults = try #require(UserDefaults(suiteName: "NextVisitWindowTests.\(UUID().uuidString)"))
        let local = LocalDoctorReportStore(
            measurementsStore: MeasurementsStore(repo: MeasurementsRepository(api: api, outbox: outbox)),
            medicationsStore: MedicationsStore(repo: MedicationsRepository(api: api, outbox: outbox)),
            moodStore: MoodStore(repo: MoodRepository(api: api, outbox: outbox)),
            settingsStore: SettingsStore(repo: SettingsRepository(api: api), defaults: defaults),
            calendar: Self.berlin,
            now: { Self.now }
        )
        let start = Self.instant("2026-08-11T22:00:00Z")
        #expect(local.complianceDays(from: start) == local.periodDays, "no window: the look-back")
        local.window = Self.visitWindow.interval(calendar: Self.berlin, now: Self.now)
        // 12 August to 5 November in Berlin: 85 days back.
        #expect(local.complianceDays(from: start) == 85)
        local.clearOnLogout()
        #expect(local.window == nil)
    }

    // MARK: - The reads

    @Test("the visit read asks for booked visits; the notable read sends no window")
    func repositoryRequests() async throws {
        let recorder = WireRecorder()
        MockURLProtocol.install { req in
            recorder.record(req)
            if req.url?.path == "/api/encounters" {
                let list = #"{"upcoming":[],"past":[]}"#
                return SharingWire.jsonOK(req, #"{"data":\#(list),"error":null,"meta":{}}"#)
            }
            let window = #"{"from":"2026-08-12","to":"2026-11-05","anchor":"nextVisit","observations":[],"changes":[]}"#
            return SharingWire.jsonOK(req, #"{"data":\#(window),"error":null,"meta":{}}"#)
        }
        let repository = EncountersRepository(api: SharingWire.makeAPI())
        let list = try await repository.upcoming()
        #expect(list.upcoming.isEmpty)
        let window = try await repository.notableSinceLastVisit()
        #expect(window.anchor == "nextVisit")
        let captures = recorder.all
        #expect(captures.count == 2)
        #expect(captures.first?.path == "/api/encounters")
        #expect(captures.first?.query?.contains("status=PLANNED") == true)
        #expect(captures.last?.path == "/api/day/notable")
        #expect(captures.last?.query == nil || captures.last?.query?.isEmpty == true)
    }
}
