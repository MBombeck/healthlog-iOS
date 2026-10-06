import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping file_length

/// Shared transport for the capability surface suites.
@MainActor
enum AISurfaceHarness {
    final class StubReach: ReachabilityProviding, @unchecked Sendable {
        var isOnlineStream: AsyncStream<Bool> {
            get async { AsyncStream { c in c.yield(true)
                c.finish()
            } }
        }

        func isCurrentlyOnline() async -> Bool {
            true
        }
    }

    static func makeAPI() -> APIClient {
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    nonisolated static func ok(_ request: URLRequest, _ body: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }
}

/// #114 / #115 · 0.2 — every AI surface the app has follows the server's
/// capability, and every mixed read renders a `null` model text calmly.
///
/// Surfaces and the capability they follow (the list posted on #114):
/// Coach launchers + sheet (`coach`), daily briefing (`briefing`), dashboard
/// snapshot briefing (`briefing`), digest lead / top signal (`briefing`) and
/// the Coach check-in card (`coach`), period narrative (`periodNarrative`),
/// per-metric status notes (`statusText`), document assist / summary / chat
/// (`documentAi`), and the on-device services (their own suites).
@Suite("AI capability — Coach entry point + copy (v1.39)", .serialized, .mockURLSession)
@MainActor
struct AICapabilitySurfaceGatingTests {
    // MARK: - Coach: entry point + copy

    @Test(
        "The Coach sheet closes only on a decision, never on a missing provider or consent",
        arguments: [
            (AICaps.available, false),
            (AICaps.noProvider, false),
            (AICaps.consentRequired, false),
            (AICaps.operatorDisabled, true),
            (AICaps.notPermitted, true),
            (AICaps.moduleDisabled, true),
            (AICaps.userDisabled, true),
            (AICaps.checkFailed, true)
        ]
    )
    func coachSheetClosure(state: AICapabilityState, closed: Bool) {
        let gate = AICapabilityGate(account: AICaps.block([.coach: state]))
        #expect((AskCoachSheet.coachEntryRefusal(gate) != nil) == closed)
    }

    @Test("A server older than v1.39 never closes the Coach sheet here")
    func coachSheetLegacyOpen() {
        #expect(AskCoachSheet.coachEntryRefusal(AICapabilityGate()) == nil)
    }

    @Test("Ask-Coach copy: one distinct sentence per reason; operator-off no longer asks for consent")
    func coachCopyPerReason() {
        let reasons: [AICapabilityState] = [
            AICaps.operatorDisabled, AICaps.notPermitted, AICaps.moduleDisabled,
            AICaps.userDisabled, AICaps.noProvider, AICaps.consentRequired, AICaps.checkFailed
        ]
        let copies = reasons.map { AskCoachSheet.coachRefusalCopy(AIRefusal.implied(by: $0, for: .coach)) }
        #expect(Set(copies).count == reasons.count)
        let consent = AskCoachSheet.coachRefusalCopy(AIRefusal.implied(by: AICaps.consentRequired, for: .coach))
        let operatorOff = AskCoachSheet.coachRefusalCopy(
            AIRefusal(errorCode: "assistant.disabled.coach", capability: .coach, reason: .operatorDisabled)
        )
        #expect(operatorOff != consent)
        // A v1.39 refusal without `meta.reason` still words by its code family.
        let codeOnly = AskCoachSheet.coachRefusalCopy(AIRefusal(errorCode: "ai.record.notPermitted"))
        #expect(codeOnly == copies[1])
    }

    @Test("Re-engage (consent) is offered exactly when the server says the Coach waits on consent")
    func reengageFollowsCapability() {
        func offered(_ state: AICapabilityState?) -> Bool {
            InsightsScreen.isCoachReengageAvailable(
                aiMode: .none,
                coachCapability: state,
                hasServer: true,
                resolvedProvider: .anthropic,
                hasConsentForProvider: false
            )
        }
        #expect(offered(AICaps.consentRequired))
        #expect(!offered(AICaps.operatorDisabled))
        #expect(!offered(AICaps.userDisabled))
        #expect(!offered(AICaps.available))
        // Legacy (no block): the 1.0.3 provider/consent rule still decides.
        #expect(offered(nil))
    }
}

@Suite("AI capability — Coach arms (v1.39)", .serialized, .mockURLSession)
@MainActor
struct AICapabilityCoachArmTests {
    // MARK: - Coach: the conversation arms

    @Test("Server arm: coach closed by the operator → no turn, the refusal is surfaced")
    func serverArmRefusedWhenOperatorOff() async {
        let store = CoachConversationStoreTests.makeServerArmStore(.answer("Hallo."))
        store.aiCapabilities = AICaps.reader([.coach: AICaps.operatorDisabled])
        await store.send("Frage")
        #expect(store.chat.count == 1, "only the user turn")
        guard case let .serverFailed(error) = store.lastError,
              case let HLError.aiUnavailable(refusal) = error else
        {
            Issue.record("expected an aiUnavailable refusal, got \(String(describing: store.lastError))")
            return
        }
        #expect(refusal.reason == .operatorDisabled)
    }

    @Test("Server arm: coach available → the turn runs")
    func serverArmRunsWhenAvailable() async {
        let store = CoachConversationStoreTests.makeServerArmStore(.answer("Hallo."))
        store.aiCapabilities = AICaps.reader()
        await store.send("Frage")
        #expect(store.chat.count == 2)
        #expect(store.lastError == nil)
    }

    @Test("On-device arm: onDeviceAllowed=false stops the on-device Coach before the model")
    func onDeviceArmRefused() async {
        let store = CoachConversationStore(service: LocalLLMService())
        store.aiCapabilities = AICaps.reader([.coach: AICaps.userDisabled])
        await store.send("Frage")
        guard case let .serverFailed(error) = store.lastError,
              case let HLError.aiUnavailable(refusal) = error else
        {
            Issue.record("expected the capability refusal, got \(String(describing: store.lastError))")
            return
        }
        #expect(refusal.reason == .userDisabled)
    }

    @Test("Own-key arm: a missing server provider does not block it; the operator does")
    func byoArmFollowsOnDeviceAllowed() async throws {
        let keychain = InMemoryKeychain()
        let keyStore = BYOKeyStore(keychain: keychain)
        try keyStore.setKey("sk-stored", for: .openAI)
        let calls = RequestPathLog()
        MockURLProtocol.install { request in
            calls.append(request.url?.path ?? "")
            return AISurfaceHarness.ok(request, #"{"choices":[{"message":{"content":"Okay."}}]}"#)
        }
        func makeStore(_ state: AICapabilityState) -> CoachConversationStore {
            let store = CoachConversationStore(service: LocalLLMService())
            store.byoService = BYOLLMService(
                keyStore: keyStore,
                session: URLSession(configuration: .mock()),
                consentGate: { _ in true }
            )
            store.byoProviderResolver = { .openAI }
            store.aiCapabilities = AICaps.reader([.coach: state])
            return store
        }

        let open = makeStore(AICaps.noProvider)
        await open.send("Frage")
        #expect(open.chat.count == 2)

        let before = calls.all.count
        let closed = makeStore(AICaps.operatorDisabled)
        await closed.send("Frage")
        #expect(closed.chat.count == 1)
        #expect(calls.all.count == before, "no request to the provider")
    }
}

@Suite("AI capability — briefing, snapshot, digest (v1.39)", .serialized, .mockURLSession)
@MainActor
struct AICapabilityBriefingGatingTests {
    // MARK: - Daily briefing (`briefing`) + comprehensive (no consent)

    @Test("briefing unavailable → no generate call, and a held briefing is dropped")
    func briefingStoreFollowsCapability() async {
        let api = AISurfaceHarness.makeAPI()
        let paths = RequestPathLog()
        MockURLProtocol.install { request in
            if request.targets(prefixedBy: "/api/insights") { paths.append(request.url?.path ?? "") }
            return AISurfaceHarness.ok(
                request,
                #"{"data":{"insights":{"summary":"KI-Text","recommendations":[],"citations":[],"warnings":[]},"cached":false}}"#
            )
        }
        let store = DailyBriefingStore(repo: InsightsRepository(api: api))
        let gate = AICapabilityGate()
        store.briefingAvailable = { gate.isAvailable(.briefing) }

        await store.load()
        #expect(store.response != nil)
        let generateCalls = paths.all.count

        gate.apply(AICaps.block([.briefing: AICaps.operatorDisabled]))
        await store.load()
        await store.refresh()
        #expect(store.response == nil, "no model text while briefing is unavailable")
        #expect(paths.all.count == generateCalls, "no generate call while briefing is unavailable")
    }

    @Test("insights/comprehensive loads without any AI consent; the briefing POST stays consent-gated")
    func comprehensiveLoadsWithoutConsent() async throws {
        let api = AISurfaceHarness.makeAPI()
        let paths = RequestPathLog()
        MockURLProtocol.install { request in
            if request.targets(prefixedBy: "/api/insights") { paths.append(request.url?.path ?? "") }
            if request.targets("/api/insights/cards") { return AISurfaceHarness.ok(request, #"{"data":[]}"#) }
            return AISurfaceHarness.ok(request, #"{"data":{"summary":null,"recommendations":[],"citations":[],"warnings":[]}}"#)
        }
        let insights = InsightsStore(repo: InsightsRepository(api: api))
        let briefing = DailyBriefingStore(repo: InsightsRepository(api: api))
        let defaults = try #require(UserDefaults(suiteName: "b1.consent.\(UUID().uuidString)"))
        // The gates capture both stores weakly — hold them for the whole case.
        let consentStore = AIConsentStore(keychain: InMemoryKeychain(), defaults: defaults)
        let providerStore = AIProviderStore(repo: AIProviderRepository(api: api))
        // The production wiring, with NO consent on file and no provider config.
        _ = AppContainer.configureInsightsConsentAndPRBox(
            personalRecordsSnapshotBox: PersonalRecordsSnapshotBox(),
            personalRecordsStore: PersonalRecordsStore(repo: PersonalRecordsRepository(api: api)),
            dailyBriefingStore: briefing,
            dashboardRepo: DashboardRepository(api: api),
            consentStore: consentStore,
            providerStore: providerStore
        )

        await insights.load()
        #expect(paths.all.contains("/api/insights/comprehensive"), "deterministic data loads without consent")

        await briefing.load()
        #expect(!paths.all.contains("/api/insights/generate"), "the generating POST keeps its consent gate")
        withExtendedLifetime((consentStore, providerStore)) {}
    }

    // MARK: - Dashboard snapshot (`briefingAi`)

    @Test("Snapshot: briefingAi unavailable → no model prose, whatever the slot carries")
    func snapshotFollowsBriefingAi() {
        let text = DailyBriefing(paragraph: "Modell-Text")
        let off = DashboardSnapshotBriefing(briefing: text, briefingState: .ready, briefingAi: AICaps.operatorDisabled)
        #expect(off.renderPolicy == .hidden)
        let noProvider = DashboardSnapshotBriefing(briefing: text, briefingState: .ready, briefingAi: AICaps.noProvider)
        #expect(noProvider.renderPolicy == .deterministicFallback)
        let on = DashboardSnapshotBriefing(briefing: text, briefingState: .ready, briefingAi: AICaps.available)
        #expect(on.renderPolicy == .prose(text, asOf: nil, stale: false))
    }

    @Test("Snapshot: the v1.39 wire shape (briefing null + briefingAi) decodes and renders calmly")
    func snapshotV139Decode() throws {
        let json = #"""
        {"user":{"username":"anna"},"tiles":{},"briefing":null,"briefingMemory":null,
         "briefingState":"disabled","briefingUpdatedAt":null,"briefingStale":false,
         "briefingAi":{"available":false,"reason":"operator_disabled","onDeviceAllowed":false},
         "generatedAt":"2026-09-24T06:00:00.000Z"}
        """#
        let slot = try JSONDecoder.hlDefault.decode(DashboardSnapshotBriefing.self, from: Data(json.utf8))
        #expect(slot.briefingAi == AICaps.operatorDisabled)
        #expect(slot.renderPolicy == .hidden)
    }

    // MARK: - Digest (`ai { briefing, coach, reactionLines }`)

    private static func digestJSON(ai: String?) -> String {
        let aiField = ai.map { #","ai":\#($0)"# } ?? ""
        return #"""
        {"generatedAt":"2026-09-24T07:00:00.000Z","phase":"final","sleepPending":false,
         "score":{"value":72,"band":"green","delta":1},
         "topSignal":{"sourceMetric":"PULSE","tone":"info","headline":"Puls ruhig","nudge":"Weiter so","delta":null},
         "briefingLead":"Modell-Satz.","line":"Deterministische Zeile.",
         "worthALook":[
           {"kind":"coach_checkin","title":"Wie läuft dein Plan?","body":null,"status":"info",
            "actions":[{"labelKey":"daily.action.keep","intent":"coach.checkin.keep:p1","href":null}],"moduleKey":"coach"},
           {"kind":"dose_window","title":"Metformin","body":null,"status":"info",
            "actions":[{"labelKey":"daily.action.log","intent":"dose.log","href":null}],"moduleKey":"medications"}
         ]\#(aiField)}
        """#
    }

    @Test("Digest: ai.coach unavailable hides the Coach check-in card; the rest stays")
    func digestCoachCard() throws {
        let ai = #"""
        {"briefing":{"available":true,"reason":null,"onDeviceAllowed":true},
         "coach":{"available":false,"reason":"user_disabled","onDeviceAllowed":false},
         "reactionLines":{"available":true,"reason":null,"onDeviceAllowed":true}}
        """#
        let digest = try JSONDecoder.hlDefault.decode(DailyDigest.self, from: Data(Self.digestJSON(ai: ai).utf8))
        #expect(digest.rail.map(\.kind) == ["dose_window"])
        #expect(digest.lead == "Modell-Satz.")
    }

    @Test("Digest: ai.briefing unavailable → the deterministic line, no top signal")
    func digestBriefingMasked() throws {
        let ai = #"""
        {"briefing":{"available":false,"reason":"consent_required","onDeviceAllowed":true},
         "coach":{"available":true,"reason":null,"onDeviceAllowed":true},
         "reactionLines":{"available":true,"reason":null,"onDeviceAllowed":true}}
        """#
        let digest = try JSONDecoder.hlDefault.decode(DailyDigest.self, from: Data(Self.digestJSON(ai: ai).utf8))
        #expect(digest.lead == "Deterministische Zeile.")
        #expect(!digest.hasBriefingLead)
        #expect(digest.visibleTopSignal == nil)
        #expect(digest.rail.count == 2)
    }

    @Test("Digest without `ai` (server < v1.39) and with a malformed `ai` renders as before")
    func digestLegacyUnchanged() throws {
        for ai in [nil, #""broken""#] {
            let digest = try JSONDecoder.hlDefault.decode(DailyDigest.self, from: Data(Self.digestJSON(ai: ai).utf8))
            #expect(digest.rail.count == 2)
            #expect(digest.lead == "Modell-Satz.")
            #expect(digest.visibleTopSignal?.headline == "Puls ruhig")
        }
    }

    @Test("Digest `ai` survives the SWR cache round trip")
    func digestRoundTrip() throws {
        let ai = #"""
        {"briefing":{"available":true,"reason":null,"onDeviceAllowed":true},
         "coach":{"available":false,"reason":"operator_disabled","onDeviceAllowed":false},
         "reactionLines":{"available":true,"reason":null,"onDeviceAllowed":true}}
        """#
        let digest = try JSONDecoder.hlDefault.decode(DailyDigest.self, from: Data(Self.digestJSON(ai: ai).utf8))
        let again = try JSONDecoder.hlDefault.decode(DailyDigest.self, from: JSONEncoder.hlDefault.encode(digest))
        #expect(again == digest)
        #expect(again.rail.map(\.kind) == ["dose_window"])
    }
}

@Suite("AI capability — mixed reads (v1.39)", .serialized, .mockURLSession)
@MainActor
struct AICapabilityMixedReadTests {
    // MARK: - Period narrative (`periodNarrative`)

    @Test("periodNarrative unavailable → a cached model narrative is not painted; the server's answer is")
    func narrativeSkipsCacheWhenUnavailable() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let swr = SWRCoordinator(cache: cache, reachability: AISurfaceHarness.StubReach())
        let cachedModelText = NarrativeDTO(
            period: "week", locale: "de",
            narrative: .init(text: "Modell-Rückblick", updatedAt: nil), revalidating: false
        )
        try await cache.write(
            .insightsNarrative(period: "week", locale: "de", day: BerlinDayKey.string()),
            payload: JSONEncoder.hlDefault.encode(cachedModelText)
        )
        MockURLProtocol.install { request in
            // v1.39 NarrativeResponse while the capability is unavailable.
            AISurfaceHarness.ok(request, #"""
            {"data":{"period":"week","locale":"de","narrative":null,"revalidating":false,
             "ai":{"available":false,"reason":"operator_disabled","onDeviceAllowed":false}}}
            """#)
        }
        let store = NarrativeStore(repo: NarrativeRepository(api: AISurfaceHarness.makeAPI(), swr: swr))
        store.modelNarrativeAvailable = { false }
        await store.load(period: .week, locale: "de")
        #expect(store.narrative(for: .week) == nil, "calm empty, never the cached model prose")
        #expect(store.hasSettled(.week))
    }

    // MARK: - Status notes (`statusText`, mixed read)

    @Test("statusText unavailable → the cached model note is bypassed; a null note renders as a calm hidden card")
    func statusTextBypassesCache() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let swr = SWRCoordinator(cache: cache, reachability: AISurfaceHarness.StubReach())
        let cachedNote = MetricStatusDTO(hasProvider: true, text: "Modell-Notiz", cached: false, updatedAt: nil)
        try await cache.write(
            .insightStatus(kind: .bloodPressure, locale: "de", day: BerlinDayKey.string()),
            payload: JSONEncoder.hlDefault.encode(cachedNote)
        )
        MockURLProtocol.install { request in
            // v1.39 MetricStatusResponse: 200, model text null, sibling `ai`.
            AISurfaceHarness.ok(request, #"""
            {"data":{"hasProvider":true,"text":null,"cached":false,"updatedAt":null,"insufficient":false,"preparing":false,
             "ai":{"available":false,"reason":"operator_disabled","onDeviceAllowed":false}}}
            """#)
        }
        let closed = MetricInsightsRepository(
            api: AISurfaceHarness.makeAPI(), swr: swr, aiCapabilities: AICaps.reader([.statusText: AICaps.operatorDisabled])
        )
        let dto = try await closed.fetchAssessment(metric: .bloodPressure, locale: "de")
        #expect(dto?.text == nil)
        let state = AssessmentCard.resolveState(
            assessment: dto, isLoading: false, failed: false, consentClosed: false, hasServer: true
        )
        #expect(state == .suppressed)

        // Control: with the capability available the cached note paints first.
        let open = MetricInsightsRepository(api: AISurfaceHarness.makeAPI(), swr: swr, aiCapabilities: AICaps.reader())
        #expect(try await open.fetchAssessment(metric: .bloodPressure, locale: "de")?.text == "Modell-Notiz")
    }

    // MARK: - Workouts (`workoutInsights`, mixed read)

    @Test("workouts/{id} v1.39: a null insight + sibling ai decode without touching the data")
    func workoutDetailDecodes() throws {
        let json = #"""
        {"id":"w1","sportType":"running","startedAt":"2026-09-20T06:00:00.000Z","endedAt":"2026-09-20T06:30:00.000Z",
         "durationSec":1800,"source":"APPLE_HEALTH","insight":null,
         "ai":{"available":false,"reason":"user_disabled","onDeviceAllowed":false}}
        """#
        let workout = try JSONDecoder.hlDefault.decode(WorkoutListEntryDTO.self, from: Data(json.utf8))
        #expect(workout.id == "w1")
        #expect(workout.durationSec == 1800)
    }
}

@Suite("AI capability — document AI (v1.39)", .serialized, .mockURLSession)
@MainActor
struct AICapabilityDocumentGatingTests {
    // MARK: - Documents (`documentAi`)

    @Test(
        "Document AI refusals map per code",
        arguments: [
            ("assistant.disabled.documentAi", 403, DocumentAIRefusalKind.operatorDisabled),
            ("assistant.disabled.enabled", 403, .operatorDisabled),
            ("ai.record.notPermitted", 403, .recordNotPermitted),
            ("ai.provider.none", 422, .noProvider),
            ("ai.unavailable", 503, .unavailable)
        ]
    )
    func documentRefusalKinds(code: String, status: Int, kind: DocumentAIRefusalKind) {
        let error = HLError.aiUnavailable(AIRefusal(errorCode: code, capability: .documentAi, httpStatus: status))
        #expect(DocumentsRepository.aiRefusalKind(error) == kind)
    }

    @Test("Document assist copy: one sentence per refusal code")
    func documentAssistCopy() {
        func copy(_ code: String) -> String {
            DocumentDetailScreen.assistErrorMessage(HLError.aiUnavailable(AIRefusal(errorCode: code, capability: .documentAi)))
        }
        let operatorOff = copy("assistant.disabled.documentAi")
        let record = copy("ai.record.notPermitted")
        let provider = copy("ai.provider.none")
        #expect(Set([operatorOff, record, provider]).count == 3)
        // The pre-v1.39 provider code keeps its copy.
        let legacy = DocumentDetailScreen.assistErrorMessage(
            HLError.server(status: 422, code: "documents.inbound.providerUnsupported", message: "x")
        )
        #expect(legacy == provider)
    }

    @Test("Document chat: v1.39 refusals open as their own dead-end states, SSE codes too")
    func documentChatStates() {
        #expect(DocumentsRepository.mapStreamOpenError(
            HLError.aiUnavailable(AIRefusal(errorCode: "assistant.disabled.documentAi"))
        ) as? DocumentChatError == .operatorDisabled)
        #expect(DocumentsRepository.mapStreamOpenError(
            HLError.aiUnavailable(AIRefusal(errorCode: "ai.record.notPermitted"))
        ) as? DocumentChatError == .recordNotPermitted)
        #expect(DocumentsRepository.mapStreamOpenError(
            HLError.aiUnavailable(AIRefusal(errorCode: "ai.provider.none", httpStatus: 422))
        ) as? DocumentChatError == .noProvider)
        #expect(DocumentsRepository.mapStreamErrorCode("assistant.disabled.documentAi") == .operatorDisabled)
        #expect(DocumentsRepository.mapStreamErrorCode("ai.provider.none") == .noProvider)
        #expect(DocumentChatStore.ErrorState.operatorDisabled.isDeadEnd)
        #expect(!DocumentChatStore.ErrorState.limitReached.isDeadEnd)
    }
}

// swiftlint:enable force_unwrapping file_length
