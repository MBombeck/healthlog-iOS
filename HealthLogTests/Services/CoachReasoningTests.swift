import Foundation
@testable import HealthLog
import Testing

#if canImport(SpeziChat)
    import SpeziChat
#endif

/// **1.5 COACH-R (server v1.41)** — the Coach's live trail, proposals, trail
/// read and thinking depth, each with a server that sends the field and one that
/// does not. The stream-shape cases (cut off, stalled, cancelled) carry a time
/// limit: a hanging spinner shows up as a timeout, not as a stuck run.
@Suite("COACH-R — Coach live trail, proposals, trail, thinking depth", .timeLimit(.minutes(1)))
@MainActor
struct CoachReasoningTests {
    // MARK: - Fixtures

    static let activityFrames = [
        #"data: {"type":"activity","activity":{"id":"a1","phase":"thinking","status":"running","round":1,"labelKey":"insights.coach.activity.thinking","label":"Denkt nach…"}}"#,
        #"data: {"type":"activity","activity":{"id":"a1","phase":"thinking","status":"done","round":1,"#
            + #""labelKey":"insights.coach.activity.thinking","label":"Denkt nach…","title":"Schlaf der letzten Woche ansehen"}}"#,
        #"data: {"type":"activity","activity":{"id":"a2","phase":"fetch","status":"running","round":1,"labelKey":"insights.coach.activity.fetching","label":"Holt Schlaf, 7 Tage…","stepRef":"s1"}}"#
    ]
    static let memoryNoteFrame =
        #"data: {"type":"memoryNote","note":{"proposal":true,"proposalId":"p1","category":"preference","fact":"Läuft lieber morgens"}}"#
    static let planFrame =
        #"data: {"type":"planProposal","proposal":{"planId":"pl1","metric":"sleep","reviewInDays":14,"ifCue":"es nach 22 Uhr ist","thenAction":"lege ich das Handy weg"}}"#
    static let doneFrame = #"data: {"type":"done","conversationId":"c1","messageId":"m1"}"#

    static func tokens(_ text: String) -> [String] {
        text.split(separator: " ", omittingEmptySubsequences: false).enumerated().map { index, word in
            let token = index == 0 ? String(word) : " " + word
            let data = (try? JSONEncoder().encode(["type": "token", "token": token])) ?? Data()
            return "data: " + (String(bytes: data, encoding: .utf8) ?? "{}")
        }
    }

    static func makeStore(api: ReasoningStubAPI) -> CoachConversationStore {
        CoachConversationStore(
            service: LocalLLMService(forcedAvailability: .unsupported),
            serverService: CoachServerService(api: api),
            serverConsentGate: { true }
        )
    }

    static func lastText(_ store: CoachConversationStore) -> String? {
        #if canImport(SpeziChat)
            store.chat.last.map(\.content)
        #else
            store.chat.last
        #endif
    }

    // MARK: - 2. activity frames: one status line while the turn runs

    @Test("server with activity frames: the status line follows the latest frame and is gone after the answer")
    func statusLineFollowsActivityAndClears() async throws {
        let api = ReasoningStubAPI(lines: Self.activityFrames + Self.tokens("Du schläfst ruhig.") + [Self.doneFrame])
        let store = Self.makeStore(api: api)
        var seen: [String?] = []
        await api.setProbe { seen.append(store.live.statusLine) }
        await store.send("Wie schlafe ich?")
        // Before frame 2: the label; before frame 3: the screened title.
        #expect(seen.contains("Denkt nach…"))
        #expect(seen.contains("Schlaf der letzten Woche ansehen"))
        #expect(seen.contains("Holt Schlaf, 7 Tage…"))
        #expect(store.live.statusLine == nil)
        #expect(store.isResponding == false)
        #expect(Self.lastText(store) == "Du schläfst ruhig.")
        #expect(try store.live.hasTrail(#require(store.chat.last?.id)))
    }

    @Test("server without activity frames: no status line, no trail link, the turn reads as in 1.4")
    func noActivityFramesReadsAsBefore() async throws {
        let api = ReasoningStubAPI(lines: Self.tokens("Alles im Rahmen.") + [Self.doneFrame])
        let store = Self.makeStore(api: api)
        var seen: [String?] = []
        await api.setProbe { seen.append(store.live.statusLine) }
        await store.send("Hallo")
        #expect(seen.allSatisfy { $0 == nil })
        #expect(Self.lastText(store) == "Alles im Rahmen.")
        #expect(try store.live.hasTrail(#require(store.chat.last?.id)) == false)
        #expect(store.live.proposals.isEmpty)
        #expect(store.lastError == nil)
    }

    @Test("unknown and malformed frames are tolerated and never cost the answer")
    func unknownFramesTolerated() async {
        let lines = [
            #"data: {"type":"somethingNew","x":1}"#,
            #"data: {"type":"activity","activity":{"id":42}}"#,
            #"data: {"type":"planProposal","proposal":{"planId":"x"}}"#
        ] + Self.tokens("Gut.") + [Self.doneFrame]
        let store = Self.makeStore(api: ReasoningStubAPI(lines: lines))
        await store.send("Hallo")
        #expect(Self.lastText(store) == "Gut.")
        #expect(store.live.proposals.isEmpty)
        #expect(store.lastError == nil)
    }

    // MARK: - MDR filter on the live trail and the streamed answer

    @Test("a reasoning title the filter refuses is never shown; the catalog label stands in")
    func refusedTitleNeverShown() async {
        let forbidden = "Du leidest an Diabetes."
        let lines = [
            #"data: {"type":"activity","activity":{"id":"a1","phase":"thinking","status":"running","round":1,"labelKey":"k","label":"Denkt nach…","title":"\#(forbidden)"}}"#,
            #"data: {"type":"activity","activity":{"id":"a2","phase":"answer","status":"running","round":1,"labelKey":"k","label":"Schreibt die Antwort…"}}"#
        ] + Self.tokens("Gut.") + [Self.doneFrame]
        let api = ReasoningStubAPI(lines: lines)
        let store = Self.makeStore(api: api)
        var seen: [String?] = []
        await api.setProbe { seen.append(store.live.statusLine) }
        await store.send("Hallo")
        #expect(seen.contains("Denkt nach…"))
        #expect(!seen.contains(forbidden))
    }

    @Test("streamed text the filter would refuse is never painted, not even as a partial")
    func refusedTokensNeverPainted() async {
        let api = ReasoningStubAPI(lines: Self
            .tokens("Deine Werte sind stabil. Ich empfehle dir, die Dosis zu erhöhen.") + [Self.doneFrame])
        let store = Self.makeStore(api: api)
        var painted: [String] = []
        await api.setProbe { if let text = Self.lastText(store) { painted.append(text) } }
        await store.send("Hallo")
        let filter = MDRSafetyFilter()
        for text in painted {
            #expect(await filter.containsForbiddenPattern(in: text) == false, "painted: \(text)")
        }
        #expect(painted.contains { $0.hasPrefix("Deine Werte sind stabil.") })
        // The final verdict on the whole reply settles the refusal.
        #expect(Self.lastText(store) == String(localized: "coach.filtered.refusal"))
    }

    @Test("trail rows drop refused model text and keep the catalog label")
    func trailRowsScreened() async {
        let trail = CoachServerService.CoachTrail(
            entries: [
                .init(id: "a1", title: "Schlaf ansehen", text: "Du leidest an Diabetes."),
                .init(id: "a2", title: "Ich empfehle dir, die Dosis zu erhöhen.")
            ],
            recalled: ["Läuft lieber morgens", "Du bist krank."]
        )
        let rows = await CoachConversationStore.trailRows(
            trail,
            labels: ["a1": "Denkt nach…", "a2": "Holt Schlaf"],
            filter: MDRSafetyFilter()
        )
        let all = rows.flatMap { [$0.label, $0.detail ?? ""] }.joined(separator: "|")
        #expect(!all.contains("Diabetes"))
        #expect(!all.contains("Dosis"))
        #expect(!all.contains("krank"))
        #expect(rows.map(\.label) == ["Denkt nach…", "Holt Schlaf", String(localized: "coach.trail.recalled")])
        #expect(rows[0].detail == "Schlaf ansehen")
        #expect(rows[1].detail == nil)
    }

    // MARK: - 3. proposals

    @Test("server with memoryNote: a proposal under the answer, nothing sent until answered, then memoryDecision")
    func memoryProposalAnsweredOnTap() async throws {
        let api = ReasoningStubAPI(lines: Self.tokens("Notiert.") + [Self.memoryNoteFrame, Self.doneFrame])
        let store = Self.makeStore(api: api)
        await store.send("Ich laufe lieber morgens.")
        let entity = try #require(store.chat.last?.id)
        let proposal = try #require(store.live.proposals[entity])
        // The transcript scrolls the proposal into view when this moves.
        #expect(store.live.settledRevision == 1)
        #expect(proposal.state == .open)
        #expect(await api.chatBodyData.count == 1)
        #expect(await Self.json(api.chatBodyData[0])["memoryDecision"] == nil)

        await store.answerProposal(for: entity, accept: true)
        let bodies = await api.chatBodyData.map(Self.json)
        #expect(bodies.count == 2)
        let decision = try #require(bodies[1]["memoryDecision"] as? [String: Any])
        #expect(decision["messageId"] as? String == "m1")
        #expect(decision["proposalId"] as? String == "p1")
        #expect(decision["accept"] as? Bool == true)
        #expect(bodies[1]["message"] as? String == String(localized: "coach.proposal.memory.accept"))
        #expect(store.live.proposals[entity]?.state == .answered(accept: true))
        // The decision rides on that one turn only.
        await store.send("Und sonst?")
        #expect(await Self.json(api.chatBodyData[2])["memoryDecision"] == nil)
    }

    @Test("server with planProposal: decline sends planDecision accept false")
    func planProposalDeclined() async throws {
        let api = ReasoningStubAPI(lines: Self.tokens("Ein Vorschlag.") + [Self.planFrame, Self.doneFrame])
        let store = Self.makeStore(api: api)
        await store.send("Ich will besser schlafen.")
        let entity = try #require(store.chat.last?.id)
        guard case let .plan(plan)? = store.live.proposals[entity]?.kind else {
            Issue.record("no plan proposal")
            return
        }
        #expect(plan.reviewInDays == 14)
        await store.answerProposal(for: entity, accept: false)
        let decision = try #require(await Self.json(api.chatBodyData[1])["planDecision"] as? [String: Any])
        #expect(decision["planId"] as? String == "pl1")
        #expect(decision["accept"] as? Bool == false)
    }

    @Test("a fact the Coach already saved shows as saved and offers no buttons")
    func savedMemoryNote() async throws {
        let saved = #"data: {"type":"memoryNote","note":{"proposal":false,"factId":"f1","category":"preference","fact":"Trinkt keinen Kaffee"}}"#
        let api = ReasoningStubAPI(lines: Self.tokens("Gut.") + [saved, Self.doneFrame])
        let store = Self.makeStore(api: api)
        await store.send("Ich trinke keinen Kaffee.")
        let entity = try #require(store.chat.last?.id)
        #expect(store.live.proposals[entity]?.state == .saved)
        await store.answerProposal(for: entity, accept: true)
        #expect(await api.chatBodyData.count == 1)
    }

    @Test("a proposal whose wording the filter refuses is not offered")
    func refusedProposalNotOffered() async {
        let frame = #"data: {"type":"planProposal","proposal":{"planId":"pl1","metric":"bp","reviewInDays":7,"ifCue":"der Druck steigt","thenAction":"Ich empfehle dir, die Dosis zu erhöhen."}}"#
        let store = Self.makeStore(api: ReasoningStubAPI(lines: Self.tokens("Gut.") + [frame, Self.doneFrame]))
        await store.send("Hallo")
        #expect(store.live.proposals.isEmpty)
    }

    @Test("plan copy fills every line from the catalog")
    func proposalCopy() {
        let plan = CoachServerService.CoachPlanProposal(planId: "p", reviewInDays: 14, ifCue: "A", thenAction: "B", target: "C")
        let lines = CoachProposalCopy.lines(.plan(plan))
        #expect(lines.count == 3)
        #expect(lines.allSatisfy { !$0.contains("coach.proposal") })
        #expect(!CoachProposalCopy.heading(.plan(plan)).contains("coach.proposal"))
    }

    // MARK: - 4. trail: loaded only on the tap

    @Test("the trail is fetched only when asked for, and once")
    func trailOnlyAfterTap() async throws {
        let api = ReasoningStubAPI(lines: Self.activityFrames + Self.tokens("Gut.") + [Self.doneFrame])
        await api.setTrail(#"{"trail":{"entries":[{"id":"a1","title":"Schlaf ansehen"},{"id":"a2"}],"recalled":[]},"ai":{}}"#)
        let store = Self.makeStore(api: api)
        await store.send("Hallo")
        #expect(await api.sentPaths.isEmpty)
        let entity = try #require(store.chat.last?.id)
        await store.loadTrail(for: entity)
        #expect(await api.sentPaths == ["/api/insights/chat/c1/messages/m1/trail"])
        guard case let .loaded(rows)? = store.live.trails[entity] else {
            Issue.record("trail not loaded")
            return
        }
        #expect(rows.map(\.label) == ["Denkt nach…", "Holt Schlaf, 7 Tage…"])
    }

    @Test("trail null reads as empty; a failed read offers a retry state")
    func trailEmptyAndFailed() async throws {
        let api = ReasoningStubAPI(lines: Self.activityFrames + Self.tokens("Gut.") + [Self.doneFrame])
        await api.setTrail(#"{"trail":null,"ai":{}}"#)
        let store = Self.makeStore(api: api)
        await store.send("Hallo")
        let entity = try #require(store.chat.last?.id)
        await store.loadTrail(for: entity)
        #expect(store.live.trails[entity] == .empty)
        await api.setTrail(nil)
        await store.loadTrail(for: entity)
        #expect(store.live.trails[entity] == .failed)
    }

    // MARK: - Stream ends badly: no hanging spinner

    @Test("network lost mid-stream: no spinner, no status line, no half answer, an error to act on")
    func networkLostMidStream() async {
        let api = ReasoningStubAPI(
            lines: Self.activityFrames + Self.tokens("Du schläfst"),
            failure: URLError(.networkConnectionLost)
        )
        let store = Self.makeStore(api: api)
        await store.send("Wie schlafe ich?")
        #expect(store.isResponding == false)
        #expect(store.live.statusLine == nil)
        #expect(store.lastError != nil)
        #if canImport(SpeziChat)
            #expect(store.chat.last?.role == .user)
        #endif
        #expect(store.live.proposals.isEmpty)
    }

    @Test("stream closes after activity frames without any answer: empty-reply error, status line gone")
    func streamEndsWithoutAnswer() async {
        let store = Self.makeStore(api: ReasoningStubAPI(lines: Self.activityFrames))
        await store.send("Hallo")
        #expect(store.isResponding == false)
        #expect(store.live.statusLine == nil)
        #expect(store.lastError != nil)
    }

    @Test("dismissing mid-stream (cancel) ends the turn without a status line or a stored answer")
    func cancelledMidStream() async {
        let api = ReasoningStubAPI(lines: Self.activityFrames, hangsAfterLines: true)
        let store = Self.makeStore(api: api)
        let turn = Task { await store.send("Hallo") }
        while store.live.statusLine == nil {
            await Task.yield()
        }
        store.cancelInFlightTurn()
        await turn.value
        #expect(store.isResponding == false)
        #expect(store.live.statusLine == nil)
        #expect(store.lastError == nil)
    }

    // MARK: - 1. thinking depth

    @Test("server with coachReasoning decodes; without it the setting stays hidden")
    func reasoningDecode() throws {
        let with = #"{"coachReasoning":{"level":"medium","preference":"high","maxLevel":"medium","available":true,"offIsReal":false,"source":"admin_cap"}}"#
        let state = try #require(try JSONDecoder.hlDefault.decode(AuthMeCoachReasoning.self, from: Data(with.utf8)).coachReasoning)
        #expect(state.preference == .high)
        #expect(state.canChoose(.medium))
        #expect(!state.canChoose(.high))
        #expect(state.isCapped)
        #expect(try JSONDecoder.hlDefault.decode(AuthMeCoachReasoning.self, from: Data("{}".utf8)).coachReasoning == nil)
        let unknown = #"{"coachReasoning":{"level":"ultra","preference":"high","maxLevel":"high","available":true,"offIsReal":true}}"#
        #expect(try JSONDecoder.hlDefault.decode(AuthMeCoachReasoning.self, from: Data(unknown.utf8)).coachReasoning == nil)
    }

    @Test("maxLevel off locks every option; offIsReal false names the lowest one Minimal")
    func reasoningLockAndMinimal() {
        let locked = CoachReasoningState(
            level: .off,
            preference: .medium,
            maxLevel: .off,
            available: false,
            offIsReal: true,
            source: "admin_off"
        )
        #expect(CoachReasoningLevel.allCases.allSatisfy { !locked.canChoose($0) })
        #expect(CoachReasoningPresentation.notes(for: locked) == [String(localized: "settings.ai.reasoning.locked")])
        #expect(CoachReasoningPresentation.label(.off, offIsReal: false) == String(localized: "settings.ai.reasoning.level.minimal"))
        #expect(CoachReasoningPresentation.label(.off, offIsReal: true) == String(localized: "settings.ai.reasoning.level.off"))
        #expect(String(localized: "settings.ai.reasoning.level.minimal") != "settings.ai.reasoning.level.minimal")
    }

    @Test("saving writes only coach-prefs.reasoning and keeps every sibling field")
    func reasoningSaveKeepsSiblings() async throws {
        let api = ReasoningStubAPI(lines: [])
        await api.setPrefs(#"{"tone":"warm","defaultWindow":"last30days","updatedAt":"2026-11-01T10:00:00.000Z"}"#)
        await api
            .setMe(
                #"{"coachReasoning":{"level":"low","preference":"low","maxLevel":"high","available":true,"offIsReal":true,"source":"user"}}"#
            )
        let model = CoachReasoningSettingsModel(repo: AICoachSettingsRepository(api: api))
        await model.load()
        #expect(model.state?.preference == .low)
        await api
            .setMe(
                #"{"coachReasoning":{"level":"high","preference":"high","maxLevel":"high","available":true,"offIsReal":true,"source":"user"}}"#
            )
        await model.choose(.high)
        let rawPut: Data? = await api.lastPutData
        let putData = try #require(rawPut)
        let put = Self.json(putData)
        #expect(put["reasoning"] as? String == "high")
        #expect(put["tone"] as? String == "warm")
        #expect(put["defaultWindow"] as? String == "last30days")
        #expect(put["baseUpdatedAt"] as? String == "2026-11-01T10:00:00.000Z")
        #expect(model.state?.preference == .high)
        #expect(model.failed == false)
    }

    @Test("a level above the ceiling is never sent")
    func reasoningAboveCeilingNotSent() async {
        let api = ReasoningStubAPI(lines: [])
        await api
            .setMe(
                #"{"coachReasoning":{"level":"low","preference":"low","maxLevel":"low","available":true,"offIsReal":true,"source":"user"}}"#
            )
        let model = CoachReasoningSettingsModel(repo: AICoachSettingsRepository(api: api))
        await model.load()
        await model.choose(.high)
        let rawPut: Data? = await api.lastPutData
        #expect(rawPut == nil)
    }

    static func json(_ data: Data?) -> [String: Any] {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
}

/// Scripted Coach transport: the SSE lines, delivered one `next()` at a time
/// so a probe sees the store between two lines, plus JSON answers for the
/// trail, `/api/auth/me` and `coach-prefs`.
actor ReasoningStubAPI: APIClientProtocol {
    private let lines: [String]
    private let failure: Error?
    private let hangsAfterLines: Bool
    private var probe: (@MainActor @Sendable () -> Void)?
    private var trailJSON: String?
    private var meJSON = "{}"
    private var prefsJSON = "{}"
    private(set) var chatBodyData: [Data] = []
    private(set) var sentPaths: [String] = []
    private(set) var lastPutData: Data?

    init(lines: [String], failure: Error? = nil, hangsAfterLines: Bool = false) {
        self.lines = lines
        self.failure = failure
        self.hangsAfterLines = hangsAfterLines
    }

    func setProbe(_ probe: @escaping @MainActor @Sendable () -> Void) {
        self.probe = probe
    }

    func setTrail(_ json: String?) {
        trailJSON = json
    }

    func setMe(_ json: String) {
        meJSON = json
    }

    func setPrefs(_ json: String) {
        prefsJSON = json
    }

    private func record(_ body: Data?) {
        chatBodyData.append(body ?? Data())
    }

    nonisolated func streamLines(_ request: APIRequest<Data>) async throws -> AsyncThrowingStream<String, Error> {
        await record(request.body)
        let lines = lines
        let failure = failure
        let hangs = hangsAfterLines
        let probe = await probe
        let cursor = LineCursor()
        return AsyncThrowingStream(unfolding: {
            await probe?()
            if let line = cursor.next(in: lines) {
                return line
            }
            if let failure { throw failure }
            if hangs {
                // A stalled stream: wait until the turn is cancelled.
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                throw CancellationError()
            }
            return nil
        })
    }

    func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
        let json: String
        switch (request.method, request.path) {
        case (.get, "/api/auth/me"): json = meJSON
        case (.get, "/api/auth/me/coach-prefs"): json = prefsJSON
        case (.put, "/api/auth/me/coach-prefs"):
            lastPutData = request.body
            json = prefsJSON
        default:
            sentPaths.append(request.path)
            guard let trailJSON else { throw HLError.unknown("trail unavailable") }
            json = trailJSON
        }
        return try JSONDecoder.hlDefault.decode(T.self, from: Data(json.utf8))
    }

    func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.unknown("download not stubbed")
    }
}

/// Hands out the scripted lines one by one across `next()` calls.
private final class LineCursor: @unchecked Sendable {
    private var index = 0
    private let lock = NSLock()

    func next(in lines: [String]) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard index < lines.count else { return nil }
        defer { index += 1 }
        return lines[index]
    }
}
