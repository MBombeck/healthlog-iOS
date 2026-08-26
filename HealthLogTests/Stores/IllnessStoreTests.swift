import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Stateless JSON builders for the stub handler (a plain `enum` so the
/// `@Sendable` handler can call them from outside the `@MainActor` test type).
private enum IllnessTestJSON {
    static func episode(id: String, resolvedAt: String? = nil, lifecycle: String = "ACUTE") -> String {
        let resolved = resolvedAt.map { "\"\($0)\"" } ?? "null"
        return """
        {"id":"\(id)","label":"Ep \(id)","type":"INFECTION","lifecycle":"\(lifecycle)",
         "onsetAt":"2026-06-01T08:00:00.000Z","resolvedAt":\(resolved),"parentConditionId":null,
         "note":null,"createdAt":"2026-06-01T08:00:00.000Z","updatedAt":"2026-06-01T08:00:00.000Z"}
        """
    }

    static func episodes(_ rows: [String]) -> Data {
        Data("""
        {"data":[\(rows.joined(separator: ","))],"error":null}
        """.utf8)
    }
}

/// Locks the ``IllnessStore`` behaviour: load + active/resolved split,
/// optimistic delete + rollback, resolve chronic-error branch, correlation
/// status branch + defensive 404 tolerance, the rest-mode `hasActiveEpisode`
/// flag, and the `403 illness.disabled` → `isDisabled` branch. Real `APIClient`
/// + stub `URLProtocol`.
@MainActor
@Suite("IllnessStore (v1.18.1 W-B)", .serialized)
struct IllnessStoreTests {
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

    private func makeStore(undo: UndoCoordinator? = nil) throws -> IllnessStore {
        let repo = try IllnessRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
        return IllnessStore(repository: repo, undo: undo)
    }

    @Test("load splits active vs resolved + drives hasActiveEpisode")
    func loadSplit() async throws {
        let rows = [
            IllnessTestJSON.episode(id: "a"),
            IllnessTestJSON.episode(id: "b", resolvedAt: "2026-06-09T08:00:00.000Z")
        ]
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, IllnessTestJSON.episodes(rows))
        }
        let store = try makeStore()
        await store.load()
        #expect(store.episodes.count == 2)
        #expect(store.activeEpisodes.map(\.id) == ["a"])
        #expect(store.resolvedEpisodes.map(\.id) == ["b"])
        #expect(store.hasActiveEpisode)
    }

    @Test("no active episode → hasActiveEpisode false (rest-mode off)")
    func restModeOff() async throws {
        let rows = [IllnessTestJSON.episode(id: "b", resolvedAt: "2026-06-09T08:00:00.000Z")]
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, IllnessTestJSON.episodes(rows))
        }
        let store = try makeStore()
        await store.load()
        #expect(!store.hasActiveEpisode)
    }

    @Test("optimistic delete removes the row + enqueues an undo action")
    func optimisticDelete() async throws {
        let rows = [IllnessTestJSON.episode(id: "a")]
        MockURLProtocol.handler = { req in
            let body: Data = req.httpMethod == "DELETE"
                ? Data(#"{"data":{"deleted":true},"error":null}"#.utf8)
                : IllnessTestJSON.episodes(rows)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let undo = UndoCoordinator()
        let store = try makeStore(undo: undo)
        await store.load()
        #expect(store.episodes.count == 1)
        let episode = store.episodes[0]
        await store.deleteEpisode(episode, undoMessage: "removed")
        #expect(store.episodes.isEmpty)
        #expect(undo.current?.message == "removed")
    }

    @Test("delete rolls back the optimistic removal on a write failure")
    func deleteRollback() async throws {
        let rows = [IllnessTestJSON.episode(id: "a")]
        nonisolated(unsafe) var firstLoadDone = false
        MockURLProtocol.handler = { req in
            if req.httpMethod == "DELETE" {
                // Server rejects the delete (500 → no outbox path yet → rollback).
                let body = Data(#"{"data":null,"error":"boom"}"#.utf8)
                return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, body)
            }
            firstLoadDone = true
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, IllnessTestJSON.episodes(rows))
        }
        let undo = UndoCoordinator()
        let store = try makeStore(undo: undo)
        await store.load()
        #expect(firstLoadDone)
        let episode = store.episodes[0]
        await store.deleteEpisode(episode, undoMessage: "removed")
        // 500 is retriable but there's no outbox path → the optimistic removal
        // is rolled back so the row reappears.
        #expect(store.episodes.contains { $0.id == "a" })
        #expect(store.lastError != nil)
    }

    @Test("select loads the full day-log list (v1.18.3) into dayLogsByDate")
    func selectLoadsDayLogList() async throws {
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/day-logs"), req.httpMethod == "GET" {
                let body = Data(#"""
                {"data":{"dayLogs":[
                  {"id":"d2","episodeId":"a","date":"2026-06-03","functionalImpact":1,
                   "feverC":null,"symptoms":[],"note":null,"updatedAt":"2026-06-03T20:00:00.000Z"},
                  {"id":"d1","episodeId":"a","date":"2026-06-02","functionalImpact":2,
                   "feverC":38.0,"symptoms":[],"note":null,"updatedAt":"2026-06-02T20:00:00.000Z"}
                 ],"meta":{"total":2,"limit":200,"offset":0}},"error":null}
                """#.utf8)
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            }
            if path.hasSuffix("/correlation") {
                let body = Data(#"{"data":null,"error":"Not found"}"#.utf8)
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, body)
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                IllnessTestJSON.episodes([IllnessTestJSON.episode(id: "a")])
            )
        }
        let store = try makeStore()
        await store.load()
        await store.select(store.episodes[0])
        #expect(store.dayLogsByDate.count == 2)
        #expect(store.dayLogsByDate["2026-06-02"]?.functionalImpact == 2)
        #expect(store.dayLogsByDate["2026-06-03"]?.id == "d2")
    }

    @Test("Day-log list failure remains an error instead of becoming empty")
    func dayLogFailureHasDistinctTimelineState() async throws {
        MockURLProtocol.handler = { req in
            if req.url?.path.hasSuffix("/day-logs") == true {
                let body = Data(#"{"data":null,"error":"temporarily unavailable"}"#.utf8)
                return (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, body)
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null,"error":"Not found"}"#.utf8)
            )
        }
        let store = try makeStore()
        await store.loadDayLogs(episodeId: "a")
        #expect(store.dayLogTimelineState == .error)
        #expect(store.dayLogsByDate.isEmpty)
    }

    @Test("select clears the previous episode's day-logs (cross-episode isolation)")
    func selectClearsAcrossEpisodes() async throws {
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/day-logs"), req.httpMethod == "GET" {
                // Episode "a" has one day-log; episode "b" has none (keyed off the
                // URL so no external mutable state crosses the @Sendable boundary).
                let rows = path.contains("/episodes/a/")
                    ? #"[{"id":"d1","episodeId":"a","date":"2026-06-02","functionalImpact":1,"feverC":null,"symptoms":[],"note":null,"updatedAt":"2026-06-02T20:00:00.000Z"}]"#
                    : "[]"
                let body = Data("{\"data\":{\"dayLogs\":\(rows),\"meta\":{\"total\":0,\"limit\":200,\"offset\":0}},\"error\":null}".utf8)
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            }
            if path.hasSuffix("/correlation") {
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null,"error":"x"}"#.utf8)
                )
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                IllnessTestJSON.episodes([IllnessTestJSON.episode(id: "a"), IllnessTestJSON.episode(id: "b")])
            )
        }
        let store = try makeStore()
        await store.load()
        await store.select(store.episodes[0]) // a → 1 day-log
        #expect(store.dayLogsByDate.count == 1)
        await store.select(store.episodes[1]) // b → empty; previous rows gone
        #expect(store.dayLogsByDate.isEmpty)
    }

    @Test("undo of a deleted episode restores it (lossless, v1.18.3)")
    func undoRestores() async throws {
        nonisolated(unsafe) var restoreHit = false
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/restore"), req.httpMethod == "POST" {
                restoreHit = true
                let body = Data("{\"data\":\(IllnessTestJSON.episode(id: "a")),\"error\":null}".utf8)
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            }
            if req.httpMethod == "DELETE" {
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":{"deleted":true},"error":null}"#.utf8)
                )
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                IllnessTestJSON.episodes([IllnessTestJSON.episode(id: "a")])
            )
        }
        let undo = UndoCoordinator()
        let store = try makeStore(undo: undo)
        await store.load()
        await store.deleteEpisode(store.episodes[0], undoMessage: "removed")
        #expect(store.episodes.isEmpty)
        // Fire the enqueued undo action (the restore POST).
        await undo.performUndo()
        #expect(restoreHit)
        #expect(store.episodes.contains { $0.id == "a" }) // re-surfaced via reload
    }

    @Test("resolve chronic 422 surfaces lastErrorWasChronicNoResolve")
    func resolveChronic() async throws {
        let rows = [IllnessTestJSON.episode(id: "a", lifecycle: "CHRONIC_ONGOING")]
        MockURLProtocol.handler = { req in
            if req.url?.path.hasSuffix("/resolve") == true {
                let body = Data(#"""
                {"data":null,"error":"Ongoing condition cannot be resolved",
                 "errorCode":"illness.episode.chronic-no-resolve"}
                """#.utf8)
                return (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, body)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, IllnessTestJSON.episodes(rows))
        }
        let store = try makeStore()
        await store.load()
        let ok = await store.resolveEpisode(id: "a")
        #expect(!ok)
        #expect(store.lastErrorWasChronicNoResolve)
    }

    @Test("correlation status=ok is rendered by the store")
    func correlationOK() async throws {
        MockURLProtocol.handler = { req in
            if req.url?.path.hasSuffix("/correlation") == true {
                let body = Data(#"""
                {"data":{"episodeId":"a","status":"ok",
                 "value":{"episodeId":"a","preOnset":[],"nadir":[],"returns":[],
                   "recoveryGapDays":4,"feltBetterDay":null,"redFlags":[]},
                 "coverage":{"requiredInputs":4,"presentInputs":4,"historyDays":90,"missing":[]},
                 "confidence":null,
                 "provenance":{"inputs":[],"source":"server","windowDays":90,"computedAt":"2026-06-10T00:00:00.000Z"},
                 "reason":null},"error":null}
                """#.utf8)
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                IllnessTestJSON.episodes([IllnessTestJSON.episode(id: "a")])
            )
        }
        let store = try makeStore()
        await store.load()
        await store.loadCorrelation(episodeId: "a")
        #expect(store.correlation?.status == .ok)
        #expect(store.correlation?.value?.recoveryGapDays == 4)
        #expect(!store.isDisabled)
    }

    @Test("correlation 404 degrades to nil, not an error (defensive)")
    func correlationNotFoundDegrades() async throws {
        MockURLProtocol.handler = { req in
            if req.url?.path.hasSuffix("/correlation") == true {
                let body = Data(#"{"data":null,"error":"Not found"}"#.utf8)
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, body)
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                IllnessTestJSON.episodes([IllnessTestJSON.episode(id: "a")])
            )
        }
        let store = try makeStore()
        await store.load()
        await store.loadCorrelation(episodeId: "a")
        #expect(store.correlation == nil)
        #expect(!store.isDisabled)
        #expect(store.lastError == nil)
    }

    @Test("403 illness.disabled flips isDisabled + clears data")
    func illnessDisabled() async throws {
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":null,"error":"Illness journal is not enabled",
             "meta":{"errorCode":"illness.disabled","module":"illness"}}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, body)
        }
        let store = try makeStore()
        await store.load()
        #expect(store.isDisabled)
        #expect(store.episodes.isEmpty)
        #expect(store.lastError == nil)
    }
}

// swiftlint:enable force_unwrapping
