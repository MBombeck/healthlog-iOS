// swiftlint:disable force_unwrapping
import Foundation
@testable import HealthLog
import Testing

/// **AUDITC (1.5.0, #132 with the tightenings of 16.10.)** — answering
/// and removing AUDIT-C over the real `APIClient` and `MockURLProtocol`,
/// against a stub of the v1.47.0 routes whose read follows its writes.
///
/// The locale sent is the one the server offered, whatever the interface
/// language; `takenAt` is the moment of the first attempt; a retry carries
/// the same `externalId` and the server's 200 replay is success; 422 and 429
/// have their own sentence; the sum shown is the server's.
@MainActor
@Suite("LifeAuditCFlow", .serialized, .mockURLSession, .timeLimit(.minutes(2)))
struct LifeAuditCFlowTests {
    /// Network failures are retried inside one request; the test clock lets
    /// those retries run without waiting.
    final class Transport: @unchecked Sendable {
        private let lock = NSLock()
        private var dropping: URLError.Code?

        /// While set, an AUDIT-C POST reaches the server and its answer is
        /// lost on the way back (`.timedOut`), or never leaves the device.
        var failure: URLError.Code? {
            get { lock.withLock { dropping } }
            set { lock.withLock { dropping = newValue } }
        }
    }

    private func makeStore(_ server: LifeServerStub, transport: Transport = Transport()) -> LifeCircumstancesStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let api = APIClient(
            environment: env,
            keychain: InMemoryKeychain(),
            sessionConfiguration: .mock(),
            retryClock: APIRetryClock(now: { Date() }, sleep: { _ in })
        )
        MockURLProtocol.install { request in
            let isPost = request.httpMethod == "POST" && request.url?.path == LifeCircumstancesRepository.auditCPath
            if isPost, let code = transport.failure {
                if code == .timedOut { _ = server.handle(request) }
                throw URLError(code)
            }
            return server.handle(request)
        }
        return LifeCircumstancesStore(repo: LifeCircumstancesRepository(api: api))
    }

    private func posts(_ server: LifeServerStub) -> [LifeServerStub.Recorded] {
        server.requests.filter { $0.method == "POST" && $0.path == LifeCircumstancesRepository.auditCPath }
    }

    /// Opens the form and answers every item with `points`.
    private func answer(_ model: AuditCModel, _ store: LifeCircumstancesStore, _ points: [Int]) throws -> AuditCInstrument {
        let instrument = try #require(store.auditC?.instrument)
        model.open(instrument)
        for (index, value) in points.enumerated() {
            model.select(value, item: index)
        }
        #expect(model.isComplete)
        return instrument
    }

    // MARK: - locale exactly as offered (16.10.)

    @Test(
        "the locale sent is the one the server offered, never the interface language",
        arguments: [("de", AppLanguage.en), ("en", AppLanguage.nl), ("en", AppLanguage.de), ("pl", AppLanguage.de)]
    )
    func offeredLocaleIsSent(offered: String, interface: AppLanguage) async throws {
        let server = LifeServerStub()
        server.auditC { $0.offeredLocale = offered }
        let store = makeStore(server)
        let model = AuditCModel()
        await AppLanguage.$pinned.withValue(interface) {
            await store.load()
        }
        let instrument = try answer(model, store, [2, 1, 1])
        let before = Date()
        let saved = await AppLanguage.$pinned.withValue(interface) {
            await model.submit(instrument, store: store)
        }
        #expect(saved)
        let body = try #require(posts(server).first?.body)
        #expect(body["locale"] as? String == offered)
        #expect(body["source"] as? String == "IOS")
        #expect(body["items"] as? [Int] == [2, 1, 1])
        #expect((body["externalId"] as? String)?.isEmpty == false)
        #expect(body["tz"] as? String == TimeZone.current.identifier)
        let taken = try #require((body["takenAt"] as? String).flatMap(ISO8601DateFormatter.fractional.date(from:)))
        #expect(taken >= before.addingTimeInterval(-1) && taken <= Date().addingTimeInterval(1), "takenAt is now")
    }

    // MARK: - Result as delivered

    @Test("after saving, the page shows the server's sum and verdict; the form closes")
    func resultAsDelivered() async throws {
        let server = LifeServerStub()
        let store = makeStore(server)
        let model = AuditCModel()
        await store.load()
        #expect(store.auditC?.latest == nil)
        #expect(store.auditC?.offerDue == true)
        let instrument = try answer(model, store, [2, 1, 1])
        #expect(await model.submit(instrument, store: store))
        #expect(!model.isFormOpen)
        #expect(model.submitError == nil)
        let latest = try #require(store.auditC?.latest)
        #expect(latest.totalScore == 4)
        #expect(latest.aboveCutoff == true)
        #expect(AuditCResultBlock.verdict(latest) == String(localized: "life.auditC.result.above \(4)"))
        #expect(store.auditC?.offerDue == false)
        #expect(store.auditC?.history.count == 1)
    }

    // MARK: - Retry with the same externalId

    @Test("a lost answer is retried with the same externalId and takenAt; the 200 replay is success, one entry")
    func retryReplaysSameEntry() async throws {
        let server = LifeServerStub()
        let transport = Transport()
        let store = makeStore(server, transport: transport)
        let model = AuditCModel()
        await store.load()
        let instrument = try answer(model, store, [1, 1, 1])

        transport.failure = .timedOut
        #expect(await !model.submit(instrument, store: store, now: Date().addingTimeInterval(-30)))
        #expect(model.submitError != nil)
        #expect(model.isFormOpen, "the form and its answers stay")
        #expect(model.answer(0) == 1)
        let first = try #require(posts(server).first?.body)
        #expect(server.auditC { $0.entries.count } == 1, "the server stored the entry; only the answer was lost")

        transport.failure = nil
        #expect(await model.submit(instrument, store: store))
        let all = posts(server)
        let last = try #require(all.last?.body)
        #expect(last["externalId"] as? String == first["externalId"] as? String)
        #expect(last["takenAt"] as? String == first["takenAt"] as? String)
        #expect(Set(all.compactMap { $0.body["externalId"] as? String }).count == 1)
        #expect(server.auditC { $0.entries.count } == 1, "the replay stored nothing new")
        #expect(store.auditC?.latest?.totalScore == 3)
        #expect(model.pending == nil)
    }

    @Test("changed answers after a failure are a new entry with a new externalId")
    func changedAnswersAreNewEntry() async throws {
        let server = LifeServerStub()
        let transport = Transport()
        let store = makeStore(server, transport: transport)
        let model = AuditCModel()
        await store.load()
        let instrument = try answer(model, store, [1, 1, 1])
        transport.failure = .notConnectedToInternet
        #expect(await !model.submit(instrument, store: store))
        #expect(model.submitError == HLError.offline.userFacingDescription, "offline says so")
        let first = model.pending?.externalId
        transport.failure = nil
        model.select(3, item: 2)
        #expect(await model.submit(instrument, store: store))
        let sent = posts(server).last?.body["externalId"] as? String
        #expect(sent != nil && sent != first)
        #expect(store.auditC?.latest?.totalScore == 5)
    }

    // MARK: - 422 and 429

    @Test("422: own sentence, page reloaded; another wording on offer now clears the answers")
    func invalidReloadsAndStartsOver() async throws {
        let server = LifeServerStub()
        let store = makeStore(server)
        let model = AuditCModel()
        await store.load()
        let instrument = try answer(model, store, [1, 0, 0])
        // The account language changed on the web while the form was open.
        server.auditC { $0.offeredLocale = "en" }
        #expect(await !model.submit(instrument, store: store))
        #expect(model.submitError == String(localized: "life.auditC.error.invalid"))
        #expect(posts(server).first?.body["locale"] as? String == "de")
        #expect(store.auditC?.instrument?.locale == "en", "reloaded")
        #expect(model.answer(0) == nil, "answers given to the old wording start over")
        #expect(model.pending == nil)
        // Answered again in the wording now offered, it goes through.
        let fresh = try answer(model, store, [1, 0, 0])
        #expect(await model.submit(fresh, store: store))
        #expect(posts(server).last?.body["locale"] as? String == "en")
    }

    @Test("422 for a takenAt more than five minutes ahead names the same sentence")
    func futureTakenAtRefused() async throws {
        let server = LifeServerStub()
        let store = makeStore(server)
        let model = AuditCModel()
        await store.load()
        let instrument = try answer(model, store, [0, 0, 0])
        #expect(await !model.submit(instrument, store: store, now: Date().addingTimeInterval(10 * 60)))
        #expect(model.submitError == String(localized: "life.auditC.error.invalid"))
        #expect(model.answer(0) == 0, "same wording: the answers stay")
    }

    @Test("429: own sentence, answers kept, nothing stored")
    func rateLimited() async throws {
        let server = LifeServerStub()
        let store = makeStore(server)
        let model = AuditCModel()
        await store.load()
        server.override(
            "POST \(LifeCircumstancesRepository.auditCPath)",
            status: 429,
            body: #"{"data":null,"error":"Too many","meta":{"errorCode":"anamnesis.auditC.rateLimited","retryAt":"2099-01-01T00:00:00.000Z"}}"#
        )
        let instrument = try answer(model, store, [4, 4, 4])
        #expect(await !model.submit(instrument, store: store))
        #expect(model.submitError == String(localized: "life.auditC.error.rateLimited"))
        #expect(model.isFormOpen)
        #expect(model.answer(2) == 4)
        #expect(server.auditC { $0.entries.isEmpty })
    }

    // MARK: - Removal

    @Test("an entry is removed with DELETE and leaves the history; also one the server cannot open")
    func removeEntries() async {
        let server = LifeServerStub()
        server.auditC {
            $0.entries = [
                .init(id: "sealed", takenAt: "2026-10-01T08:00:00.000Z", items: [4, 4, 4], locale: "de", externalId: nil, readable: false),
                .init(id: "old", takenAt: "2025-01-01T08:00:00.000Z", items: [1, 0, 0], locale: "de", externalId: nil)
            ]
        }
        let store = makeStore(server)
        let model = AuditCModel()
        await store.load()
        #expect(store.auditC?.latest?.id == "old", "the newest readable entry")
        #expect(store.auditC?.history.map(\.id) == ["sealed", "old"], "the unreadable one is listed")

        model.askRemoval("sealed")
        await model.remove("sealed", store: store)
        #expect(server.requests.contains { $0.method == "DELETE" && $0.path == "/api/anamnesis/audit-c/sealed" })
        #expect(store.auditC?.history.map(\.id) == ["old"])
        #expect(model.confirmingRemovalID == nil)
        #expect(model.removeError == nil)

        // Already gone elsewhere: no error, the reload shows it.
        model.askRemoval("ghost")
        await model.remove("ghost", store: store)
        #expect(model.removeError == nil)
        #expect(model.confirmingRemovalID == nil)

        // A failure keeps the question open and says so.
        server.override("DELETE /api/anamnesis/audit-c/old", status: 500, body: #"{"data":null,"error":"boom"}"#)
        model.askRemoval("old")
        await model.remove("old", store: store)
        #expect(model.removeError == String(localized: "life.auditC.removeError"))
        #expect(model.confirmingRemovalID == "old")
        #expect(store.auditC?.history.map(\.id) == ["old"])
    }

    @Test("cancelling closes the form and forgets the answers and the retry identity")
    func cancelForgets() async throws {
        let server = LifeServerStub()
        let transport = Transport()
        let store = makeStore(server, transport: transport)
        let model = AuditCModel()
        await store.load()
        let instrument = try answer(model, store, [1, 1, 1])
        transport.failure = .notConnectedToInternet
        _ = await model.submit(instrument, store: store)
        #expect(model.pending != nil)
        model.cancel()
        #expect(!model.isFormOpen)
        #expect(model.pending == nil)
        #expect(model.answer(0) == nil)
        #expect(model.submitError == nil)
    }
}
