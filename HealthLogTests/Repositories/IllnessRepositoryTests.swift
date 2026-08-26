import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Locks the v1.18.1 illness DATA layer against the server contract: DTO decode
/// (episode incl. optional resolvedAt/note, day-log, the `Derived<T>`
/// correlation in both `ok` + `insufficient`, insights), envelope unwrapping,
/// the episode CRUD + resolve (incl. 422 chronic), the day-log upsert (200/201),
/// and the `403 illness.disabled` discriminator. Real `APIClient` + stub
/// `URLProtocol` (no mock server) per PROJECT_GUIDE.md.
@Suite("Illness data layer (v1.18.1 W-B)", .serialized)
struct IllnessRepositoryTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.10",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
    }

    private func makeRepo() throws -> IllnessRepository {
        try IllnessRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
    }

    // MARK: - DTO decode

    @Test("Episode decodes incl. optional resolvedAt/note + unknown enum fallback")
    func decodeEpisode() throws {
        let json = Data(#"""
        {"id":"e1","label":"Flu","type":"INFECTION","lifecycle":"ACUTE",
         "onsetAt":"2026-06-01T08:00:00.000Z","resolvedAt":null,
         "parentConditionId":null,"note":"bedrest","createdAt":"2026-06-01T08:00:00.000Z",
         "updatedAt":"2026-06-01T08:00:00.000Z"}
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(IllnessEpisodeDTO.self, from: json)
        #expect(dto.id == "e1")
        #expect(dto.type == .infection)
        #expect(dto.lifecycle == .acute)
        #expect(dto.resolvedAt == nil)
        #expect(dto.isActive)
        #expect(dto.note == "bedrest")
    }

    @Test("Unknown type/lifecycle fall back to OTHER/ACUTE (tolerant)")
    func decodeUnknownEnums() throws {
        let json = Data(#"""
        {"id":"e2","label":"Mystery","type":"NEW_SERVER_TYPE","lifecycle":"NEW_CYCLE",
         "onsetAt":"2026-06-01T08:00:00.000Z","resolvedAt":"2026-06-09T08:00:00.000Z",
         "parentConditionId":null,"note":null,"createdAt":"2026-06-01T08:00:00.000Z",
         "updatedAt":"2026-06-09T08:00:00.000Z"}
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(IllnessEpisodeDTO.self, from: json)
        #expect(dto.type == .other)
        #expect(dto.lifecycle == .acute)
        #expect(!dto.isActive) // resolvedAt set
    }

    @Test("Day-log decodes with graded + presence-only symptoms")
    func decodeDayLog() throws {
        let json = Data(#"""
        {"id":"d1","episodeId":"e1","date":"2026-06-02","functionalImpact":2,
         "feverC":38.4,"symptoms":[{"key":"cough","severity":2},{"key":"fatigue","severity":null}],
         "note":"rough day","updatedAt":"2026-06-02T20:00:00.000Z"}
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(IllnessDayLogDTO.self, from: json)
        #expect(dto.functionalImpact == 2)
        #expect(dto.feverC == 38.4)
        #expect(dto.symptoms.count == 2)
        #expect(dto.symptoms.first { $0.key == "cough" }?.severity == 2)
        #expect(dto.symptoms.first { $0.key == "fatigue" }?.severity == nil)
    }

    @Test("Correlation decodes status=ok with value findings")
    func decodeCorrelationOK() throws {
        let json = Data(#"""
        {"episodeId":"e1","status":"ok",
         "value":{"episodeId":"e1",
           "preOnset":[{"type":"RESTING_HEART_RATE","day":"2026-05-31","value":62,
             "baselineCenter":54,"deviationSd":2.1,"direction":"above","adverse":true}],
           "nadir":[],"returns":[{"type":"RESTING_HEART_RATE","returnedDay":"2026-06-08","gapDays":3}],
           "recoveryGapDays":3.0,"feltBetterDay":"2026-06-05",
           "redFlags":[{"type":"SPO2","reason":"sustained_low_spo2","worstValue":91,"days":2}]},
         "coverage":{"requiredInputs":4,"presentInputs":4,"historyDays":90,"missing":[]},
         "confidence":{"score":0.8,"band":"high"},
         "provenance":{"inputs":["RESTING_HEART_RATE"],"source":"server","windowDays":90,
           "computedAt":"2026-06-10T00:00:00.000Z"},
         "reason":null}
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(IllnessCorrelationDTO.self, from: json)
        #expect(dto.status == .ok)
        #expect(dto.value?.recoveryGapDays == 3.0)
        #expect(dto.value?.preOnset.first?.direction == .above)
        #expect(dto.value?.preOnset.first?.adverse == true)
        #expect(dto.value?.redFlags.first?.reason == "sustained_low_spo2")
        #expect(dto.coverage.requiredInputs == 4)
        // New v1.21.0 fields absent on this older fixture → tolerant nil.
        #expect(dto.value?.gapDriverType == nil)
        #expect(dto.value?.sleepContext == nil)
    }

    @Test("Correlation decodes status=insufficient with null value + reason")
    func decodeCorrelationInsufficient() throws {
        let json = Data(#"""
        {"episodeId":"e1","status":"insufficient","value":null,
         "coverage":{"requiredInputs":4,"presentInputs":1,"historyDays":12,"missing":["HRV","SPO2"]},
         "confidence":null,
         "provenance":{"inputs":[],"source":"server","windowDays":90,"computedAt":"2026-06-10T00:00:00.000Z"},
         "reason":"not enough history"}
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(IllnessCorrelationDTO.self, from: json)
        #expect(dto.status == .insufficient)
        #expect(dto.value == nil)
        #expect(dto.reason == "not enough history")
        #expect(dto.coverage.missing.contains("HRV"))
    }

    @Test("Insights decodes incl. withheld (null) typical gap")
    func decodeInsights() throws {
        let json = Data(#"""
        {"windowDays":365,"episodeCount":5,"resolvedCount":4,"typicalRecoveryGapDays":null,
         "gapSampleSize":1,"byMonth":{"2026-06":2,"2026-01":1},"byType":{"INFECTION":4,"INJURY":1}}
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(IllnessInsightsDTO.self, from: json)
        #expect(dto.episodeCount == 5)
        #expect(dto.typicalRecoveryGapDays == nil)
        #expect(dto.byType["INFECTION"] == 4)
        #expect(dto.byMonth["2026-06"] == 2)
        // gapDriverType absent on this fixture → tolerant nil.
        #expect(dto.gapDriverType == nil)
    }

    @Test("Insights sends includeRecoveryGap=false by default")
    func insightsDefaultsToCheapQuery() async throws {
        MockURLProtocol.handler = { req in
            let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems
            #expect(items?.first(where: { $0.name == "includeRecoveryGap" })?.value == "false")
            let body = Data(
                #"{"data":{"windowDays":365,"episodeCount":0,"resolvedCount":0,"typicalRecoveryGapDays":null,"gapSampleSize":0,"byMonth":{},"byType":{}},"error":null}"#
                    .utf8
            )
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        _ = try await makeRepo().insights()
    }

    @Test("Insights sends includeRecoveryGap=true only when explicitly requested")
    func insightsIncludesRecoveryGapOnDemand() async throws {
        MockURLProtocol.handler = { req in
            let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems
            #expect(items?.first(where: { $0.name == "includeRecoveryGap" })?.value == "true")
            #expect(items?.first(where: { $0.name == "windowDays" })?.value == "90")
            let body = Data(
                #"{"data":{"windowDays":90,"episodeCount":0,"resolvedCount":0,"typicalRecoveryGapDays":null,"gapSampleSize":0,"byMonth":{},"byType":{}},"error":null}"#
                    .utf8
            )
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        _ = try await makeRepo().insights(windowDays: 90, includeRecoveryGap: true)
    }

    // MARK: - List envelope unwrap

    @Test("GET /api/illness/episodes unwraps the data array + builds the query")
    func listEpisodesEnvelope() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/illness/episodes")
            #expect(req.url?.query?.contains("includeResolved=false") == true)
            let body = Data(#"""
            {"data":[
              {"id":"e1","label":"Flu","type":"INFECTION","lifecycle":"ACUTE",
               "onsetAt":"2026-06-01T08:00:00.000Z","resolvedAt":null,"parentConditionId":null,
               "note":null,"createdAt":"2026-06-01T08:00:00.000Z","updatedAt":"2026-06-01T08:00:00.000Z"}
             ],"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = try makeRepo()
        let episodes = try await repo.episodes(includeResolved: false)
        #expect(episodes.count == 1)
        #expect(episodes.first?.label == "Flu")
    }

    @Test("GET day-logs (no date) decodes the v1.18.3 LIST envelope + meta")
    func dayLogListEnvelope() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/illness/episodes/e1/day-logs")
            // No `date` param → list mode; default query carries limit/offset.
            #expect(req.url?.query?.contains("date=") != true)
            #expect(req.url?.query?.contains("limit=200") == true)
            #expect(req.url?.query?.contains("offset=0") == true)
            let body = Data(#"""
            {"data":{"dayLogs":[
              {"id":"d2","episodeId":"e1","date":"2026-06-03","functionalImpact":1,
               "feverC":null,"symptoms":[{"key":"cough","severity":2}],"note":null,
               "updatedAt":"2026-06-03T20:00:00.000Z"},
              {"id":"d1","episodeId":"e1","date":"2026-06-02","functionalImpact":2,
               "feverC":38.1,"symptoms":[],"note":"x","updatedAt":"2026-06-02T20:00:00.000Z"}
             ],"meta":{"total":2,"limit":200,"offset":0}},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = try makeRepo()
        let list = try await repo.dayLogs(episodeId: "e1")
        #expect(list.dayLogs.count == 2)
        #expect(list.dayLogs.first?.date == "2026-06-03") // newest-first
        #expect(list.meta.total == 2)
        #expect(list.meta.limit == 200)
        #expect(list.meta.offset == 0)
    }

    @Test("dayLogs passes sortDir through the query when supplied")
    func dayLogListSortDir() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.query?.contains("sortDir=asc") == true)
            let body = Data(#"{"data":{"dayLogs":[],"meta":{"total":0,"limit":50,"offset":0}},"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = try makeRepo()
        let list = try await repo.dayLogs(episodeId: "e1", limit: 50, sortDir: "asc")
        #expect(list.dayLogs.isEmpty)
        #expect(list.meta.limit == 50)
    }

    @Test("GET day-logs decodes null (nothing logged that day)")
    func dayLogNull() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/illness/episodes/e1/day-logs")
            let body = Data(#"{"data":null,"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = try makeRepo()
        let log = try await repo.dayLog(episodeId: "e1", date: "2026-06-02")
        #expect(log == nil)
    }

    @Test("GET day-logs decodes a present row (data not null)")
    func dayLogPresent() async throws {
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{"id":"d1","episodeId":"e1","date":"2026-06-02","functionalImpact":2,
             "feverC":38.1,"symptoms":[{"key":"cough","severity":1}],"note":"x",
             "updatedAt":"2026-06-02T20:00:00.000Z"},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = try makeRepo()
        let log = try await repo.dayLog(episodeId: "e1", date: "2026-06-02")
        #expect(log?.id == "d1")
        #expect(log?.functionalImpact == 2)
        #expect(log?.symptoms.first?.key == "cough")
    }

    // MARK: - Writes

    @Test("POST episode posts the create body + returns the row")
    func createEpisode() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/illness/episodes")
            #expect(req.httpMethod == "POST")
            let body = Data(#"""
            {"data":{"id":"e9","label":"Cold","type":"INFECTION","lifecycle":"ACUTE",
             "onsetAt":"2026-06-10T08:00:00.000Z","resolvedAt":null,"parentConditionId":null,
             "note":null,"createdAt":"2026-06-10T08:00:00.000Z","updatedAt":"2026-06-10T08:00:00.000Z"}
            ,"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = try makeRepo()
        let created = try await repo.createEpisode(IllnessEpisodeCreate(label: "Cold", type: .infection))
        #expect(created.id == "e9")
    }

    @Test("Upsert day-log returns the stored row on 201 (insert) and 200 (update)")
    func upsertDayLog() async throws {
        let dayLogBody = Data(#"""
        {"data":{"id":"d1","episodeId":"e1","date":"2026-06-02","functionalImpact":1,
         "feverC":null,"symptoms":[],"note":null,"updatedAt":"2026-06-02T20:00:00.000Z"},"error":null}
        """#.utf8)
        let repo = try makeRepo()
        // 201 insert.
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/illness/episodes/e1/day-logs")
            return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, dayLogBody)
        }
        let inserted = try await repo.upsertDayLog(episodeId: "e1", IllnessDayLogUpsert(date: "2026-06-02", functionalImpact: 1))
        #expect(inserted.id == "d1")
        // 200 update.
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, dayLogBody)
        }
        let updated = try await repo.upsertDayLog(episodeId: "e1", IllnessDayLogUpsert(date: "2026-06-02", functionalImpact: 1))
        #expect(updated.id == "d1")
    }

    @Test("DELETE decodes the v1.18.3 {deleted:true} body (200, not 204)")
    func deleteReturnsDeletedTrue() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/illness/episodes/e1")
            #expect(req.httpMethod == "DELETE")
            let body = Data(#"{"data":{"deleted":true},"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = try makeRepo()
        let deleted = try await repo.deleteEpisode(id: "e1")
        #expect(deleted == true)
    }

    @Test("DELETE tolerates an empty/204-style body (deleted defaults false)")
    func deleteToleratesEmptyBody() async throws {
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":{},"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = try makeRepo()
        let deleted = try await repo.deleteEpisode(id: "e1")
        #expect(deleted == false) // tolerant: no `deleted` key → false, no crash
    }

    @Test("POST restore re-surfaces the SAME episode id + day-logs (lossless)")
    func restoreReturnsSameEpisode() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/illness/episodes/e1/restore")
            #expect(req.httpMethod == "POST")
            let body = Data(#"""
            {"data":{"id":"e1","label":"Flu","type":"INFECTION","lifecycle":"ACUTE",
             "onsetAt":"2026-06-01T08:00:00.000Z","resolvedAt":null,"parentConditionId":null,
             "note":"bedrest","createdAt":"2026-06-01T08:00:00.000Z","updatedAt":"2026-06-12T08:00:00.000Z"},
            "error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = try makeRepo()
        let restored = try await repo.restore(id: "e1")
        #expect(restored.id == "e1") // same id, not a fresh re-create
        #expect(restored.note == "bedrest") // encrypted note re-surfaced intact
    }

    @Test("Symptom severity clamps to 1–3; 0 / out-of-range become a plain link or bound")
    func severityClamps() throws {
        let json = Data(#"""
        {"key":"cough","severity":0}
        """#.utf8)
        let zero = try JSONDecoder.hlDefault.decode(IllnessSymptom.self, from: json)
        #expect(zero.severity == nil) // 0 is not a distinct state → plain link

        let high = try JSONDecoder.hlDefault.decode(IllnessSymptom.self, from: Data(#"{"key":"cough","severity":7}"#.utf8))
        #expect(high.severity == 3) // clamped to the upper bound

        let valid = try JSONDecoder.hlDefault.decode(IllnessSymptom.self, from: Data(#"{"key":"cough","severity":2}"#.utf8))
        #expect(valid.severity == 2) // in-range value preserved

        let absent = try JSONDecoder.hlDefault.decode(IllnessSymptom.self, from: Data(#"{"key":"cough","severity":null}"#.utf8))
        #expect(absent.severity == nil) // null → plain presence link

        // The init clamps too (so a UI-built symptom can't carry a bogus grade).
        #expect(IllnessSymptom(key: "x", severity: 0).severity == nil)
        #expect(IllnessSymptom(key: "x", severity: 9).severity == 3)
        #expect(IllnessSymptom.severityRange == 1 ... 3)
    }

    @Test("resolve 422 chronic-no-resolve is recognised")
    func resolveChronic() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/illness/episodes/e1/resolve")
            let body = Data(#"""
            {"data":null,"error":"Ongoing condition cannot be resolved",
             "errorCode":"illness.episode.chronic-no-resolve"}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = try makeRepo()
        do {
            _ = try await repo.resolveEpisode(id: "e1")
            Issue.record("expected a 422")
        } catch {
            #expect(IllnessRepository.isChronicNoResolve(error))
            #expect(!IllnessRepository.isIllnessDisabled(error))
        }
    }

    // MARK: - 403 illness.disabled

    @Test("403 illness.disabled is recognised by isIllnessDisabled")
    func illnessDisabled() async throws {
        MockURLProtocol.handler = { req in
            // Server stamps meta.errorCode: illness.disabled (NOT module.disabled),
            // so APIClient surfaces a generic 403 — the repo classifier handles it.
            let body = Data(#"""
            {"data":null,"error":"Illness journal is not enabled",
             "meta":{"errorCode":"illness.disabled","module":"illness"}}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = try makeRepo()
        do {
            _ = try await repo.episodes()
            Issue.record("expected a thrown error")
        } catch {
            #expect(IllnessRepository.isIllnessDisabled(error))
        }
    }

    @Test("A 404 on the correlation endpoint is tolerated as not-found")
    func correlationNotFound() async throws {
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":null,"error":"Not found"}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = try makeRepo()
        do {
            _ = try await repo.correlation(episodeId: "missing")
            Issue.record("expected a 404")
        } catch {
            #expect(IllnessRepository.isNotFound(error))
            #expect(!IllnessRepository.isIllnessDisabled(error))
        }
    }
}

/// v1.21.0 additive decode coverage for the gap-driver + sleep-context fields.
/// Kept in its own extension so the main suite stays under the type-body limit.
extension IllnessRepositoryTests {
    @Test("Correlation decodes v1.21.0 gapDriverType + sleepContext")
    func decodeCorrelationGapDriverAndSleep() throws {
        let json = Data(#"""
        {"episodeId":"e2","status":"ok",
         "value":{"episodeId":"e2","preOnset":[],"nadir":[],
           "returns":[{"type":"RESTING_HEART_RATE","returnedDay":"2026-06-08","gapDays":3}],
           "recoveryGapDays":3.0,"feltBetterDay":"2026-06-05",
           "gapDriverType":"RESTING_HEART_RATE","redFlags":[],
           "sleepContext":{"baselineMeanMinutes":420,"episodeMeanMinutes":510,
             "deltaMinutes":90,"nightsCounted":3}},
         "coverage":{"requiredInputs":4,"presentInputs":4,"historyDays":90,"missing":[]},
         "confidence":{"score":0.8,"band":"high"},
         "provenance":{"inputs":["RESTING_HEART_RATE"],"source":"server","windowDays":90,
           "computedAt":"2026-06-10T00:00:00.000Z"},
         "reason":null}
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(IllnessCorrelationDTO.self, from: json)
        #expect(dto.value?.gapDriverType == "RESTING_HEART_RATE")
        #expect(dto.value?.sleepContext?.baselineMeanMinutes == 420)
        #expect(dto.value?.sleepContext?.episodeMeanMinutes == 510)
        #expect(dto.value?.sleepContext?.deltaMinutes == 90)
        #expect(dto.value?.sleepContext?.nightsCounted == 3)
    }

    @Test("Insights decodes v1.21.0 gapDriverType when present")
    func decodeInsightsGapDriver() throws {
        let json = Data(#"""
        {"windowDays":365,"episodeCount":5,"resolvedCount":4,"typicalRecoveryGapDays":2.5,
         "gapSampleSize":4,"byMonth":{"2026-06":2},"byType":{"INFECTION":4},
         "gapDriverType":"HEART_RATE_VARIABILITY"}
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(IllnessInsightsDTO.self, from: json)
        #expect(dto.typicalRecoveryGapDays == 2.5)
        #expect(dto.gapDriverType == "HEART_RATE_VARIABILITY")
    }
}

// swiftlint:enable force_unwrapping
