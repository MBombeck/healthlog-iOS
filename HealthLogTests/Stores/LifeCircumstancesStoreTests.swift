// swiftlint:disable force_unwrapping
import Foundation
@testable import HealthLog
import Testing

/// **LIFE (1.5.0, #132, Server #614 and #1334)** — the store over the real
/// `APIClient` and `MockURLProtocol`, against an in-memory server whose reads
/// follow its writes. Every kind round-trips (write, correct, delete), the AI
/// switch follows `aiIncluded`, a stale token reloads and says so, and an
/// off module or a refused record shows the disabled card, not an error.
@MainActor
@Suite("LifeCircumstancesStore", .serialized, .mockURLSession)
struct LifeCircumstancesStoreTests {
    typealias Fx = LifeCircumstancesFixtures

    private func makeStore(_ server: LifeServerStub) -> LifeCircumstancesStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        MockURLProtocol.install { request in server.handle(request) }
        return LifeCircumstancesStore(repo: LifeCircumstancesRepository(api: api))
    }

    private func writes(_ server: LifeServerStub) -> [LifeServerStub.Recorded] {
        // POLISH-C (C7): the page also reads `GET /api/anamnesis/facts` for
        // the earlier alcohol answer; only the writes count here.
        server.requests.filter { $0.path.hasPrefix("/api/anamnesis/facts") && $0.method != "GET" }
    }

    // MARK: - Server #1334: former smoker with a quit date

    @Test("a former smoker with a quit month is saved and comes back on the next load (Server #1334)")
    func formerSmokerWithDateRoundTrips() async throws {
        let server = LifeServerStub()
        let store = makeStore(server)
        await store.load()
        #expect(store.phase == .loaded)

        var draft = try #require(store.draft(.tobacco))
        draft.smokingStatus = .former
        #expect(draft.asksQuitMonth, "the quit month is asked of a former smoker")
        draft.tobacco.products = [.cigarettes]
        draft.tobacco.cigarettesPerDay = 15
        draft.tobacco.startYear = 1995
        draft.tobacco.quitMonth = LifeYearMonth(year: 2019, month: 3)
        store.drafts[.tobacco] = draft
        #expect(store.hasChanges(.tobacco))

        #expect(await store.save(.tobacco))
        let posted = writes(server)
        #expect(posted.map(\.method) == ["POST", "POST"])
        #expect(posted.first?.body["kind"] as? String == "SMOKING_STATUS")
        #expect(posted.first?.body["value"] as? String == "FORMER")
        let detail = try #require(posted.last?.body["value"] as? [String: Any])
        #expect(posted.last?.body["kind"] as? String == "TOBACCO_DETAIL")
        #expect(detail["quitMonth"] as? String == "2019-03", "month precision, the contract's YYYY-MM")
        #expect(detail["startYear"] as? Int == 1995)

        // A fresh screen (new store) reads it back from the server.
        let reopened = makeStore(server)
        await reopened.load()
        let tobacco = try #require(reopened.payload?.section(.tobacco))
        #expect(tobacco.fact(.smokingStatus)?.value == .smokingStatus(.former))
        guard case let .tobacco(saved) = tobacco.fact(.tobaccoDetail)?.value else {
            Issue.record("the tobacco detail did not come back")
            return
        }
        #expect(saved.quitMonth == LifeYearMonth(year: 2019, month: 3))
        #expect(saved.cigarettesPerDay == 15)
        #expect(reopened.draft(.tobacco)?.tobacco.quitMonth == LifeYearMonth(year: 2019, month: 3))
        #expect(!reopened.hasChanges(.tobacco))
    }

    @Test("changing the quit month corrects the revision, with the chosen day as validFrom")
    func quitMonthCorrection() async throws {
        let server = LifeServerStub()
        server.seed(kind: "SMOKING_STATUS", valueJSON: #""FORMER""#, id: "s1")
        server.seed(kind: "TOBACCO_DETAIL", valueJSON: Fx.tobaccoValue, id: "t1")
        let store = makeStore(server)
        await store.load()
        store.drafts[.tobacco]?.tobacco.quitMonth = LifeYearMonth(year: 2021, month: 7)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 9)))
        #expect(await store.save(.tobacco, validFrom: day, calendar: calendar))
        let patch = try #require(writes(server).last)
        #expect(patch.method == "PATCH")
        #expect(patch.path == "/api/anamnesis/facts/t1")
        #expect(patch.body["validFrom"] as? String == "2026-10-02")
        #expect((patch.body["value"] as? [String: Any])?["quitMonth"] as? String == "2021-07")
        #expect(writes(server).count == 1, "the unchanged status sends nothing")
    }

    // MARK: - Every kind: write, correct, delete

    @Test("every kind round-trips: written, corrected and deleted through the read route")
    func everyKindRoundTrips() async throws {
        let server = LifeServerStub()
        let store = makeStore(server)
        await store.load()

        store.drafts[.tobacco]?.smokingStatus = .current
        store.drafts[.tobacco]?.tobacco.secondhandSmoke = true
        store.drafts[.activity]?.activity.moderateDaysPerWeek = 4
        store.drafts[.activity]?.activity.sittingHoursWorkday = 6.5
        store.drafts[.work]?.shiftSchedule = .fixedShift
        store.drafts[.work]?.work.nightWork = true
        store.drafts[.work]?.freeWeekdays.days = [.sunday]
        store.drafts[.habits]?.habits.latestCaffeine = .after18
        store.drafts[.goals]?.goals.goals = [.weight, .sleep]
        for key in [LifeSectionKey.tobacco, .activity, .work, .habits, .goals] {
            #expect(await store.save(key), "first save of \(key)")
        }
        let payload = try #require(store.payload)
        for kind in LifeFactKind.allCases {
            let found = payload.sections.contains { $0.fact(kind) != nil }
            #expect(found, "\(kind.rawValue) written")
        }
        #expect(payload.section(.work)?.fact(.workContext)?.value == .work(
            LifeWorkContext(situation: nil, physicalNature: nil, nightWork: true, exposures: [])
        ))

        // Correct each.
        store.drafts[.tobacco]?.smokingStatus = .former
        store.drafts[.activity]?.activity.moderateDaysPerWeek = 5
        store.drafts[.work]?.freeWeekdays.days = [.saturday, .sunday]
        store.drafts[.habits]?.habits.latestCaffeine = .before12
        store.drafts[.goals]?.goals.goals = [.fitness]
        for key in [LifeSectionKey.tobacco, .activity, .work, .habits, .goals] {
            #expect(await store.save(key), "correction of \(key)")
        }
        #expect(store.payload?.section(.tobacco)?.fact(.smokingStatus)?.value == .smokingStatus(.former))
        #expect(store.payload?.section(.goals)?.fact(.healthGoals)?.value == .goals(LifeHealthGoals(goals: [.fitness])))
        #expect(writes(server).contains { $0.method == "PATCH" })

        // Delete each by clearing it.
        for key in [LifeSectionKey.tobacco, .activity, .work, .habits, .goals] {
            let section = try #require(store.payload?.section(key))
            store.drafts[key] = LifeSectionDraft(section: LifeSection(
                key: key, aiSection: section.aiSection, aiIncluded: true, lastConfirmedAt: nil, reviewDue: false, facts: []
            ))
            #expect(await store.save(key), "clearing \(key)")
        }
        #expect(store.payload?.sections.allSatisfy(\.facts.isEmpty) == true)
        #expect(writes(server).contains { $0.method == "DELETE" })
    }

    // MARK: - Errors on save

    @Test("a refused write keeps the typed answers, names the reason and reloads")
    func failedSaveKeepsDraft() async {
        let server = LifeServerStub()
        let store = makeStore(server)
        await store.load()
        server.override(
            "POST /api/anamnesis/facts",
            status: 422,
            body: #"{"data":null,"error":"bad","meta":{"errorCode":"anamnesis.fact.invalidValue"}}"#
        )
        store.drafts[.goals]?.goals.goals = [.sleep]
        let saved = await store.save(.goals)
        #expect(!saved)
        #expect(store.sectionErrors[.goals] == AnamnesisFactFailure.invalidValue.userFacingDescription)
        #expect(store.drafts[.goals]?.goals.goals == [.sleep], "what was typed stays")
        #expect(store.hasChanges(.goals))
    }

    // MARK: - AI switches

    @Test("the AI switch is sent with the about-me token and follows aiIncluded")
    func aiSwitch() async throws {
        let server = LifeServerStub()
        let store = makeStore(server)
        await store.load()
        #expect(store.payload?.section(.habits)?.aiIncluded == true)
        await store.setAI("HABITS", included: false)
        let patch = try #require(server.requests.last { $0.path.hasSuffix("/ai-sections") })
        #expect(patch.method == "PATCH")
        #expect(patch.body["sections"] as? [String: Bool] == ["HABITS": false])
        #expect(patch.body["baseUpdatedAt"] as? String == "2026-11-01T08:00:00.000Z")
        #expect(store.payload?.section(.habits)?.aiIncluded == false)

        await store.setAI(LifeCircumstancesScreen.shiftAISection, included: true)
        #expect(store.payload?.shiftScheduleAIIncluded == true)
        let second = try #require(server.requests.last { $0.path.hasSuffix("/ai-sections") })
        #expect(second.body["baseUpdatedAt"] is String, "the token travels on every switch")
    }

    @Test("without a profile row yet the switch goes without a token, never as null")
    func aiSwitchWithoutToken() async throws {
        let server = LifeServerStub()
        server.aboutMeToken = nil
        let store = makeStore(server)
        await store.load()
        await store.setAI("GOALS", included: false)
        let patch = try #require(server.requests.last { $0.path.hasSuffix("/ai-sections") })
        #expect(patch.body.keys.contains("baseUpdatedAt") == false)
    }

    @Test("409 about_me_conflict reloads the page and says so; nothing is retried")
    func aiConflict() async {
        let server = LifeServerStub()
        let store = makeStore(server)
        await store.load()
        server.override(
            "PATCH /api/anamnesis/life-circumstances/ai-sections",
            status: 409,
            body: #"{"data":null,"error":"Self-context changed since it was loaded","meta":{"errorCode":"about_me_conflict"}}"#
        )
        let readsBefore = server.requests.count { $0.path == "/api/anamnesis/life-circumstances" }
        await store.setAI("WORK", included: false)
        #expect(store.notice == String(localized: "life.ai.conflict"))
        #expect(server.requests.count { $0.path.hasSuffix("/ai-sections") } == 1, "not retried")
        #expect(server.requests.count { $0.path == "/api/anamnesis/life-circumstances" } == readsBefore + 1, "reloaded")
        #expect(store.payload?.section(.work)?.aiIncluded == true)
    }

    @Test("'still true' confirms the section and reloads")
    func confirm() async throws {
        let server = LifeServerStub()
        let store = makeStore(server)
        await store.load()
        await store.confirm(.activity)
        let post = try #require(server.requests.last { $0.path.hasSuffix("/confirm") })
        #expect(post.method == "POST")
        #expect(post.body["section"] as? String == "activity")
        #expect(store.notice == nil)
    }

    // MARK: - Off, refused, failed, stale

    @Test("403 module.disabled shows the disabled card, not an error")
    func moduleDisabled() async {
        let server = LifeServerStub()
        server.override(
            "GET /api/anamnesis/life-circumstances",
            status: 403,
            body: #"{"data":null,"error":"Module disabled","meta":{"errorCode":"module.disabled","module":"profile"}}"#
        )
        let store = makeStore(server)
        await store.load()
        #expect(store.phase == .disabled(nil))
        #expect(store.payload == nil)
    }

    @Test("a refused record (a grant without the profile) shows the disabled card with its reason")
    func refusedRecord() async {
        let server = LifeServerStub()
        server.override("GET /api/anamnesis/life-circumstances", status: 403, body: #"{"data":null,"error":"Forbidden"}"#)
        let store = makeStore(server)
        await store.load()
        #expect(store.phase == .disabled(ModuleAccessState.notGranted.offReason))
    }

    @Test("a failed first load offers a retry; a failed refresh keeps the answers and marks them stale")
    func failedAndStale() async {
        let server = LifeServerStub()
        server.override("GET /api/anamnesis/life-circumstances", status: 500, body: #"{"data":null,"error":"boom"}"#)
        let store = makeStore(server)
        await store.load()
        guard case .failed = store.phase else {
            Issue.record("expected the failed state, got \(store.phase)")
            return
        }
        server.clearOverride("GET /api/anamnesis/life-circumstances")
        server.seed(kind: "HEALTH_GOALS", valueJSON: Fx.goalsValue, id: "g1")
        await store.load()
        #expect(store.phase == .loaded)
        #expect(!store.isStale)

        server.override("GET /api/anamnesis/life-circumstances", status: 500, body: #"{"data":null,"error":"boom"}"#)
        await store.load()
        #expect(store.phase == .loaded)
        #expect(store.isStale)
        #expect(store.payload?.section(.goals)?.fact(.healthGoals) != nil, "the last answers stay on screen")
    }
}
