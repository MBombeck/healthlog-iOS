import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Locks the SAFETY contract of the v1.25 mental-health screener store: the
/// item-9 crisis card fires strictly on the flag, renders from the SERVER set when
/// present, from the bundled FALLBACK when the server omits it (deploy skew) AND
/// when the upload fails (offline), and never on item-9 == 0. Also pins that the
/// store conforms to `LogoutClearable` and never leaks the raw item answers into
/// the user-visible error string. Real `APIClient` + stub `URLProtocol`.
@MainActor
@Suite("Mental-health store safety (v1.25)", .serialized)
struct MentalHealthStoreTests {
    private func makeStore(locale: String, outbox: OutboxQueue) -> MentalHealthStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.25.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        let api = APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
        let repo = MentalHealthRepository(api: api, outbox: outbox)
        return MentalHealthStore(repository: repo, presentedLocale: locale)
    }

    /// Answer all items 0 except item-9 (index 8) set to `item9` for PHQ-9.
    private func phq9Answers(item9: Int) -> [Int] {
        var items = Array(repeating: 0, count: 9)
        items[8] = item9
        return items
    }

    private func successEnvelope(item9Flagged: Bool, crisisJSON: String) -> Data {
        Data("""
        {"data":{"assessment":{"id":"mhX","instrument":"PHQ9","locale":"en","version":"standard",
          "totalScore":\(item9Flagged ? 2 : 4),"severityBand":"minimal","item9Flagged":\(item9Flagged),
          "crisisShownAt":\(item9Flagged ? "\"2026-06-28T08:00:00.000Z\"" : "null"),
          "takenAt":"2026-06-28T08:00:00.000Z","createdAt":"2026-06-28T08:00:00.000Z"},
         "actionThreshold":10,"crisis":\(crisisJSON)},"error":null}
        """.utf8)
    }

    // MARK: - Crisis from SERVER data

    @Test("item-9 flagged → crisis card renders from the SERVER-supplied set")
    func crisisFromServerData() async throws {
        let serverCrisis = """
        {"emergencyNumber":"911","resources":[
          {"id":"lifeline988","contacts":["988"]},
          {"id":"crisisTextLine","contacts":["Text HOME to 741741"]}]}
        """
        MockURLProtocol.handler = { [env = successEnvelope(item9Flagged: true, crisisJSON: serverCrisis)] req in
            (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, env)
        }
        // Store locale "en" would FALL BACK to International (112); proving the
        // rendered set is the SERVER's (911/988) shows server data drives it.
        let store = try makeStore(locale: "en", outbox: OutboxQueue(inMemory: true))
        store.begin(.phq9)
        for i in 0 ..< 9 {
            store.setAnswer(phq9Answers(item9: 2)[i], at: i)
        }

        await store.submit()

        #expect(store.phase == .result)
        let result = try #require(store.result)
        #expect(result.item9Flagged)
        #expect(result.serverDerived)
        let crisis = try #require(result.crisis)
        #expect(crisis.emergencyNumber == "911") // server set, NOT the "en" fallback (112)
        #expect(crisis.resources.contains { $0.id == "lifeline988" })
    }

    // MARK: - Crisis from FALLBACK (deploy skew: flagged but server omits set)

    @Test("item-9 flagged but server omits crisis → bundled FALLBACK resolves (deploy skew)")
    func crisisFromFallbackOnDeploySkew() async throws {
        MockURLProtocol.handler = { [env = successEnvelope(item9Flagged: true, crisisJSON: "null")] req in
            (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, env)
        }
        let store = try makeStore(locale: "de", outbox: OutboxQueue(inMemory: true))
        store.begin(.phq9)
        for i in 0 ..< 9 {
            store.setAnswer(phq9Answers(item9: 1)[i], at: i)
        }

        await store.submit()

        let result = try #require(store.result)
        #expect(result.item9Flagged)
        let crisis = try #require(result.crisis) // fallback, despite crisis:null
        #expect(crisis.emergencyNumber == "112")
        #expect(crisis.resources.contains { $0.id == "telefonSeelsorge" }) // DE fallback
    }

    // MARK: - Crisis on UPLOAD FAILURE (offline)

    @Test("item-9 flagged + 503 upload failure → crisis STILL shows from the bundled fallback")
    func crisisOnUploadFailure() async throws {
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
        let outbox = try OutboxQueue(inMemory: true)
        let store = makeStore(locale: "de", outbox: outbox)
        store.begin(.phq9)
        for i in 0 ..< 9 {
            store.setAnswer(phq9Answers(item9: 3)[i], at: i)
        }

        await store.submit()

        // Even though the upload failed (queued), a positive item-9 IS signposted.
        #expect(store.phase == .result)
        let result = try #require(store.result)
        #expect(result.item9Flagged)
        #expect(result.serverDerived == false) // provisional offline result
        let crisis = try #require(result.crisis)
        #expect(crisis.resources.contains { $0.id == "telefonSeelsorge" })
        // The PHI submit is durably queued for replay.
        #expect(await outbox.snapshot.first?.kind == .createMentalHealthAssessment)
    }

    // MARK: - No crisis when item-9 == 0

    @Test("item-9 == 0 → NO crisis card, even with a high total")
    func noCrisisWhenItem9Zero() async throws {
        // High total, item-9 zero.
        let highTotalNoFlag = Data("""
        {"data":{"assessment":{"id":"mhY","instrument":"PHQ9","locale":"en","version":"standard",
          "totalScore":15,"severityBand":"modSevere","item9Flagged":false,"crisisShownAt":null,
          "takenAt":"2026-06-28T08:00:00.000Z","createdAt":"2026-06-28T08:00:00.000Z"},
         "actionThreshold":10,"crisis":null},"error":null}
        """.utf8)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, highTotalNoFlag)
        }
        let store = try makeStore(locale: "de", outbox: OutboxQueue(inMemory: true))
        store.begin(.phq9)
        for i in 0 ..< 9 {
            store.setAnswer([3, 3, 3, 3, 3, 0, 0, 0, 0][i], at: i)
        }

        await store.submit()

        let result = try #require(store.result)
        #expect(result.item9Flagged == false)
        #expect(result.crisis == nil)
        #expect(result.showConsiderProfessional) // total 15 >= 10
    }

    // MARK: - PHI: no item leakage / logout wipe

    @Test("a failed submit never leaks the raw item answers into the error string")
    func noItemLeakInError() async throws {
        // Non-retriable 422 + NON-flagged item-9 → applyError path, stays on the
        // form. The server message must not (and does not) contain the item
        // answers; assert the sanitized lastError is free of the distinctive
        // answer sequence. (item-9 == 0 keeps this off the C1 crisis path so the
        // .form assertion is meaningful — the flagged path is covered below.)
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!,
                Data(#"{"error":"validation failed","data":null}"#.utf8)
            )
        }
        let store = try makeStore(locale: "en", outbox: OutboxQueue(inMemory: true))
        store.begin(.phq9)
        for i in 0 ..< 9 {
            store.setAnswer([3, 2, 3, 2, 3, 2, 3, 2, 0][i], at: i)
        }

        await store.submit()

        // Stayed on the form (non-retriable, not queued, item-9 == 0); error surfaced.
        #expect(store.phase == .form)
        let err = store.lastError ?? ""
        #expect(!err.contains("3, 2, 3")) // no item array
        #expect(!err.contains("[3,2,3")) // no compact item array
    }

    // MARK: - C1: crisis card on EVERY positive item-9 NON-retriable failure

    /// SAFETY (C1) regression suite. Before the fix, a positive item-9 whose submit
    /// ended in a NON-retriable error (`.decoding` from a 201 shape-drift, `.server`
    /// 4xx, `.canceled`, `.unknown`) fell into the generic `catch` → `phase == .form`,
    /// `result == nil`, and NO crisis card — someone in crisis got no resources. The
    /// crisis card MUST now surface on EVERY one of these, from the bundled fallback,
    /// WITHOUT enqueuing a duplicate (the no-double-write contract).
    private func phq9FlaggedAnswers() -> [Int] {
        // item-9 (index 8) positive → flagged; distinctive sequence elsewhere.
        [1, 2, 1, 2, 1, 2, 1, 2, 3]
    }

    private func assertCrisisShownAfterFailure(
        _ store: MentalHealthStore,
        outbox: OutboxQueue
    ) async throws {
        store.begin(.phq9)
        let answers = phq9FlaggedAnswers()
        for i in 0 ..< 9 {
            store.setAnswer(answers[i], at: i)
        }

        await store.submit()

        // Crisis card surfaces (provisional offline result + bundled fallback).
        #expect(store.phase == .result)
        let result = try #require(store.result)
        #expect(result.item9Flagged)
        #expect(result.serverDerived == false) // provisional
        let crisis = try #require(result.crisis)
        #expect(crisis.resources.contains { $0.id == "telefonSeelsorge" }) // DE fallback
        // No double-write: the non-retriable branch does NOT enqueue.
        #expect(await outbox.snapshot.isEmpty)
        // PHI never leaks into the soft error string.
        let err = store.lastError ?? ""
        #expect(!err.contains("1, 2, 1"))
    }

    @Test("C1: positive item-9 + .decoding (201 shape-drift) → crisis card STILL shows, no enqueue")
    func crisisOnDecodingFailure() async throws {
        // 201 (server persisted) but the envelope shape drifts → `.decoding`.
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{"unexpected":"shape"},"error":null}"#.utf8)
            )
        }
        let outbox = try OutboxQueue(inMemory: true)
        let store = makeStore(locale: "de", outbox: outbox)
        try await assertCrisisShownAfterFailure(store, outbox: outbox)
    }

    @Test("C1: positive item-9 + .server 4xx (422) → crisis card STILL shows, no enqueue")
    func crisisOnServer4xxFailure() async throws {
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!,
                Data(#"{"error":"validation failed","data":null}"#.utf8)
            )
        }
        let outbox = try OutboxQueue(inMemory: true)
        let store = makeStore(locale: "de", outbox: outbox)
        try await assertCrisisShownAfterFailure(store, outbox: outbox)
    }

    @Test("C1: positive item-9 + .canceled → crisis card STILL shows, no enqueue")
    func crisisOnCanceledFailure() async throws {
        MockURLProtocol.handler = { _ in
            throw URLError(.cancelled)
        }
        let outbox = try OutboxQueue(inMemory: true)
        let store = makeStore(locale: "de", outbox: outbox)
        try await assertCrisisShownAfterFailure(store, outbox: outbox)
    }

    @Test("C1: positive item-9 + .unknown/unexpected error → crisis card STILL shows, no enqueue")
    func crisisOnUnknownFailure() async throws {
        // A non-URLError, non-HLError thrown by the transport surfaces through the
        // store's generic `catch` (the `.unknown` class).
        struct OpaqueFailure: Error {}
        MockURLProtocol.handler = { _ in
            throw OpaqueFailure()
        }
        let outbox = try OutboxQueue(inMemory: true)
        let store = makeStore(locale: "de", outbox: outbox)
        try await assertCrisisShownAfterFailure(store, outbox: outbox)
    }

    @Test("clearOnLogout wipes history + in-flight answers + result")
    func clearOnLogout() throws {
        let store = try makeStore(locale: "en", outbox: OutboxQueue(inMemory: true))
        store.begin(.phq9)
        store.setAnswer(2, at: 8)
        store.applyOfflineResultForTesting(instrument: .phq9, items: phq9Answers(item9: 2))
        store.seedForTesting(history: [
            MentalHealthAssessmentDTO(
                id: "h1", instrument: .phq9, locale: "en", version: "standard",
                totalScore: 2, severityBand: "minimal", item9Flagged: true,
                crisisShownAt: nil, takenAt: "", createdAt: ""
            )
        ])
        store.beginDetail(.phq9)
        #expect(store.result != nil)
        #expect(!store.history.isEmpty)

        store.clearOnLogout()

        #expect(store.history.isEmpty)
        #expect(store.answers.isEmpty)
        #expect(store.result == nil)
        #expect(store.detailHistory.isEmpty)
        #expect(store.detailInstrument == nil)
        #expect(store.phase == .choose)
    }

    // MARK: - Registry-driven flow and detail history

    @Test("SCI begins with eight slots, accepts 0–4, and builds the offline 16 band without crisis")
    func sciOfflineContract() throws {
        let store = try makeStore(locale: "de", outbox: OutboxQueue(inMemory: true))
        store.begin(.sci)

        #expect(store.answers == Array(repeating: -1, count: 8))
        store.setAnswer(5, at: 0)
        #expect(store.answers[0] == -1)
        for index in store.answers.indices {
            store.setAnswer(2, at: index)
        }
        #expect(store.isComplete)

        store.applyOfflineResultForTesting(instrument: .sci, items: Array(repeating: 2, count: 8))
        let result = try #require(store.result)
        #expect(result.totalScore == 16)
        #expect(result.severityBand == "belowThreshold")
        #expect(result.showConsiderProfessional)
        #expect(result.crisis == nil)
    }

    @Test("Functional follow-up is optional, clearable, and only PHQ-9 exposes it")
    func optionalFunctionalFollowUp() throws {
        let store = try makeStore(locale: "en", outbox: OutboxQueue(inMemory: true))
        store.begin(.phq9)
        for index in store.answers.indices {
            store.setAnswer(0, at: index)
        }
        #expect(store.isComplete)
        #expect(store.activeInstrument.showsFunctionalFollowUp)

        store.setFunctionalDifficulty(2)
        #expect(store.functionalDifficulty == 2)
        store.setFunctionalDifficulty(nil)
        #expect(store.functionalDifficulty == nil)

        store.begin(.gad7)
        #expect(!store.activeInstrument.showsFunctionalFollowUp)
        for index in store.answers.indices {
            store.setAnswer(0, at: index)
        }
        #expect(store.isComplete)
        store.setFunctionalDifficulty(2)
        #expect(store.functionalDifficulty == nil)
    }

    @Test("Opening detail seeds the matching cached history before filtered refresh")
    func detailSeedsOfflineHistory() throws {
        let store = try makeStore(locale: "en", outbox: OutboxQueue(inMemory: true))
        store.seedForTesting(history: [
            MentalHealthAssessmentDTO(
                id: "sci-new", instrument: .sci, locale: "en", version: "standard",
                totalScore: 22, severityBand: "aboveThreshold", item9Flagged: false,
                crisisShownAt: nil, takenAt: "2026-07-20T09:00:00Z", createdAt: "2026-07-20T09:00:00Z"
            ),
            MentalHealthAssessmentDTO(
                id: "phq", instrument: .phq9, locale: "en", version: "standard",
                totalScore: 4, severityBand: "minimal", item9Flagged: false,
                crisisShownAt: nil, takenAt: "2026-07-19T09:00:00Z", createdAt: "2026-07-19T09:00:00Z"
            ),
            MentalHealthAssessmentDTO(
                id: "sci-old", instrument: .sci, locale: "en", version: "standard",
                totalScore: 16, severityBand: "belowThreshold", item9Flagged: false,
                crisisShownAt: nil, takenAt: "2026-07-18T09:00:00Z", createdAt: "2026-07-18T09:00:00Z"
            )
        ])

        store.beginDetail(.sci)

        #expect(store.detailInstrument == .sci)
        #expect(store.detailHistory.map(\.id) == ["sci-new", "sci-old"])
        #expect(!store.isDetailLoading)
        #expect(store.detailError == nil)
    }

    @Test("Detail refresh uses the instrument filter and replaces its seeded rows")
    func detailFilteredRefresh() async throws {
        MockURLProtocol.handler = { req in
            let instrument = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "instrument" })?.value
            #expect(instrument == "SCI")
            let body = Data(#"""
            {"data":{"assessments":[
              {"id":"remote","instrument":"SCI","locale":"en","version":"standard",
               "totalScore":24,"severityBand":"aboveThreshold","item9Flagged":false,
               "crisisShownAt":null,"takenAt":"2026-07-21T09:00:00.000Z",
               "createdAt":"2026-07-21T09:00:00.000Z"}]},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let store = try makeStore(locale: "en", outbox: OutboxQueue(inMemory: true))
        store.beginDetail(.sci)

        await store.loadDetail(.sci)

        #expect(store.detailHistory.map(\.id) == ["remote"])
        #expect(store.detailError == nil)
        #expect(!store.isDetailLoading)
    }
}
