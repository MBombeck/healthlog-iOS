import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping

/// **CU-34 (Brief C6) — `enabledHeroItemKinds` on the widgets PUT.**
///
/// Two things are pinned here, both on the **actually sent request body** rather
/// than on a helper's return value:
///
/// 1. **Omitted ≠ empty.** The server's merge disposition for this field is
///    `"preserve"` (`dashboard-layout.ts:626`): a PUT that omits the key keeps
///    whatever is stored, while a PUT that sends `[]` switches every hero item
///    off. Those are opposite instructions, and a synthesized Swift `Encodable`
///    collapses them into the same `null`. So the tests below read the JSON
///    object the transport really produced and assert on key PRESENCE, not just
///    on the decoded value — `json["enabledHeroItemKinds"] == nil` alone would
///    also hold for an explicit null.
/// 2. **The write is token-guarded (CU-20).** The same route grew
///    `baseUpdatedAt` in CU-20, and a `null` token there is a hard `422`. The
///    hero-item write must therefore ride the existing guarded path: token
///    absent before the first GET, present afterwards, and a `409` re-reads and
///    retries with the fresh token while still carrying the hero-item field.
///
/// `.serialized` because `MockURLProtocol.handler` is global state.
@Suite("CU-34 — enabledHeroItemKinds auf PUT /api/dashboard/widgets", .serialized)
struct DashboardHeroItemKindsPutTests {
    // MARK: - Helpers

    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private func sampleLayout() -> DashboardWidgetLayout {
        DashboardWidgetLayout(widgets: [
            DashboardWidgetConfig(id: DashboardWidgetId.weight, visible: true, tileVisible: true, order: 0),
            DashboardWidgetConfig(id: DashboardWidgetId.bp, visible: true, tileVisible: true, order: 1)
        ])
    }

    /// Server echo for a PUT/GET. `token` rides as `updatedAt` (the CU-20 read
    /// side of the contract).
    private static func layoutEcho(token: String?, kinds: [String]? = nil) -> Data {
        var fields = ["\"version\":1", "\"widgets\":[]"]
        if let token { fields.append("\"updatedAt\":\"\(token)\"") }
        if let kinds {
            let list = kinds.map { "\"\($0)\"" }.joined(separator: ",")
            fields.append("\"enabledHeroItemKinds\":[\(list)]")
        }
        return Data("{\(fields.joined(separator: ","))}".utf8)
    }

    // MARK: - Closed set

    @Test("Der Enum spiegelt PRIORITY_ITEM_KINDS des Servers — Werte UND Reihenfolge")
    func closedSetMatchesServer() {
        // Verbatim from `src/lib/daily/priority-item.ts:29-38`. The order is
        // load-bearing: `coerceEnabledHeroItemKinds` re-filters any stored array
        // back into exactly this sequence, so a client that keeps it paints what
        // the next GET will echo. Sending a token outside this set is a 422
        // (the PUT schema is `z.array(z.enum(PRIORITY_ITEM_KINDS))`).
        #expect(HeroItemKind.allCases.map(\.rawValue) == [
            "coach_checkin",
            "dose_window",
            "preventive_care",
            "sync_issue",
            "milestone",
            "ecg_new_recording",
            "tension_window",
            "same_time_baseline"
        ])
        #expect(HeroItemKind.maxSelected == 8)
        // Every kind the Today rail can RENDER must also be configurable here —
        // otherwise a user could see an item type they have no way to switch off.
        for kind in HeroItemKind.allCases {
            let renderKind = DailyPriorityItem.Kind(rawValue: kind.rawValue)
            if let renderKind {
                #expect(renderKind.rawValue == kind.rawValue)
            }
        }
    }

    // MARK: - Resolution (nil vs [] vs values)

    @Test("nil (alter Server) heißt ALLE Kinds, nicht keine")
    func nilResolvesToEveryKind() {
        let layout = sampleLayout()
        #expect(layout.enabledHeroItemKinds == nil)
        #expect(layout.hasExplicitHeroItemKindSelection == false)
        // A server too old to know the field filters nothing — resolving to the
        // empty set would paint an empty picker for a fully-on rail.
        #expect(layout.resolvedEnabledHeroItemKinds == HeroItemKind.allCases)
    }

    @Test("Explizites [] heißt ALLE aus und bleibt leer")
    func emptyStaysEmpty() {
        let layout = sampleLayout().settingEnabledHeroItemKinds([])
        #expect(layout.enabledHeroItemKinds == [])
        #expect(layout.hasExplicitHeroItemKindSelection)
        #expect(layout.resolvedEnabledHeroItemKinds.isEmpty)
    }

    @Test("Auswahl wird dedupliziert und in die Server-Reihenfolge gebracht")
    func selectionIsDedupedAndCanonicallyOrdered() {
        let layout = sampleLayout().settingEnabledHeroItemKinds(
            [.milestone, .coachCheckin, .milestone, .sameTimeBaseline]
        )
        #expect(layout.enabledHeroItemKinds == ["coach_checkin", "milestone", "same_time_baseline"])
        #expect(layout.resolvedEnabledHeroItemKinds == [.coachCheckin, .milestone, .sameTimeBaseline])
    }

    @Test("Unbekannte Tokens vom Server werden beim Lesen verworfen, nicht geworfen")
    func unknownTokensAreDropped() {
        let layout = DashboardWidgetLayout(
            widgets: sampleLayout().widgets,
            enabledHeroItemKinds: ["future_item", "milestone", "dose_window"]
        )
        #expect(layout.resolvedEnabledHeroItemKinds == [.doseWindow, .milestone])
    }

    // MARK: - The wire body: omitted vs []

    @Test("wire: eine Kachel-Umsortierung LÄSST enabledHeroItemKinds WEG (Server behält)")
    func wireUnrelatedSaveOmitsTheKey() async throws {
        let recorder = try await capture(
            sampleLayout().reordering([DashboardWidgetId.bp, DashboardWidgetId.weight])
        )
        let json = try #require(recorder.json(at: 0))
        // Key ABSENCE, not just a nil value: an explicit `null` would decode to
        // NSNull and reset the stored choice on a stricter server.
        #expect(json.index(forKey: "enabledHeroItemKinds") == nil)
        let raw = try #require(recorder.rawBodies.first)
        #expect(!raw.contains("enabledHeroItemKinds"))
    }

    @Test("wire: auch eine Ring-Änderung lässt enabledHeroItemKinds weg")
    func wireRingChangeOmitsTheKey() async throws {
        let recorder = try await capture(sampleLayout().settingSelectedScoreRings([.readiness]))
        let json = try #require(recorder.json(at: 0))
        #expect(json["selectedScoreRings"] as? [String] == ["READINESS"])
        #expect(json.index(forKey: "enabledHeroItemKinds") == nil)
    }

    @Test("wire: leere Auswahl SENDET [] — das ist 'alle aus', nicht 'unverändert'")
    func wireEmptySelectionSendsAnEmptyArray() async throws {
        let recorder = try await capture(sampleLayout().settingEnabledHeroItemKinds([]))
        let json = try #require(recorder.json(at: 0))
        // Present …
        #expect(json.index(forKey: "enabledHeroItemKinds") != nil)
        // … and an empty ARRAY, not a null.
        #expect(json["enabledHeroItemKinds"] is NSNull == false)
        #expect(json["enabledHeroItemKinds"] as? [String] == [])
        let raw = try #require(recorder.rawBodies.first)
        #expect(raw.contains("\"enabledHeroItemKinds\":[]"))
        #expect(!raw.contains("null"))
    }

    @Test("wire: eine Teilauswahl sendet genau diese Kinds in Server-Reihenfolge")
    func wireSubsetSelectionSendsExactlyThoseKinds() async throws {
        let recorder = try await capture(
            sampleLayout().settingEnabledHeroItemKinds([.sameTimeBaseline, .doseWindow, .milestone])
        )
        let json = try #require(recorder.json(at: 0))
        #expect(json["enabledHeroItemKinds"] as? [String] == ["dose_window", "milestone", "same_time_baseline"])
    }

    // MARK: - CU-20: the write carries baseUpdatedAt

    @Test("wire: ohne Token wird baseUpdatedAt WEGGELASSEN (null wäre 422)")
    func wireWithoutTokenOmitsBaseUpdatedAt() async throws {
        let recorder = try await capture(sampleLayout().settingEnabledHeroItemKinds([.milestone]))
        let json = try #require(recorder.json(at: 0))
        #expect(json.index(forKey: "baseUpdatedAt") == nil)
        let raw = try #require(recorder.rawBodies.first)
        #expect(!raw.contains("baseUpdatedAt"))
    }

    @Test("wire: nach einem GET trägt der Hero-Item-Write das Token vom Server")
    func wireCarriesTokenFromPrecedingRead() async throws {
        let repo = DashboardRepository(api: makeAPI())
        let recorder = Recorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Self.layoutEcho(token: "2026-07-30T10:00:00.000Z"))
        }
        _ = try await repo.widgetLayout()
        let held = await repo.currentWidgetLayoutToken()
        #expect(held == "2026-07-30T10:00:00.000Z")

        _ = try await repo.setWidgetLayout(sampleLayout().settingEnabledHeroItemKinds([.syncIssue]))
        // The PUT is the second recorded request.
        let put = try #require(recorder.json(at: 1))
        #expect(put["baseUpdatedAt"] as? String == "2026-07-30T10:00:00.000Z")
        #expect(put["enabledHeroItemKinds"] as? [String] == ["sync_issue"])
    }

    @Test("wire: 409 → Re-GET → Retry mit frischem Token, Hero-Item-Feld bleibt dabei")
    func wireConflictRereadsAndRetriesWithFreshToken() async throws {
        let repo = DashboardRepository(api: makeAPI())
        let recorder = Recorder()
        MockURLProtocol.handler = { req in
            let index = recorder.record(req)
            let url = req.url!
            switch index {
            case 0: // seed GET — hands out the stale token
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Self.layoutEcho(token: "T1")
                )
            case 1: // guarded PUT → someone else wrote in the meantime
                return (
                    HTTPURLResponse(url: url, statusCode: 409, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null,"error":"Conflict","errorCode":"dashboard_layout_conflict"}"#.utf8)
                )
            case 2: // the re-GET the retry helper performs
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Self.layoutEcho(token: "T2")
                )
            default: // the retried PUT
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Self.layoutEcho(token: "T3", kinds: ["milestone"])
                )
            }
        }

        _ = try await repo.widgetLayout()
        let saved = try await repo.setWidgetLayout(
            sampleLayout().settingEnabledHeroItemKinds([.milestone])
        )

        #expect(recorder.methods == ["GET", "PUT", "GET", "PUT"])
        let firstPut = try #require(recorder.json(at: 1))
        let retriedPut = try #require(recorder.json(at: 3))
        #expect(firstPut["baseUpdatedAt"] as? String == "T1")
        // A 409 writes NOTHING, so the retry must re-send the field — losing it
        // here would silently turn a rejected "all off" into a preserve.
        #expect(retriedPut["baseUpdatedAt"] as? String == "T2")
        #expect(retriedPut["enabledHeroItemKinds"] as? [String] == ["milestone"])
        // The echo's token is adopted for the next write.
        #expect(saved.enabledHeroItemKinds == ["milestone"])
        let held = await repo.currentWidgetLayoutToken()
        #expect(held == "T3")
    }

    // MARK: - Capture harness

    /// Sends `layout` through the real `DashboardRepository.setWidgetLayout`
    /// over `MockURLProtocol` and returns everything the transport emitted.
    private func capture(_ layout: DashboardWidgetLayout) async throws -> Recorder {
        let repo = DashboardRepository(api: makeAPI())
        let recorder = Recorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Self.layoutEcho(token: "T-echo"))
        }
        _ = try await repo.setWidgetLayout(layout)
        return recorder
    }
}

/// Thread-safe capture of every request the transport actually sent — method
/// plus the raw body bytes, so assertions can look at key presence rather than
/// at a decoded model.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMethods: [String] = []
    private var storedBodies: [String] = []

    /// Records `request` and returns its zero-based index.
    @discardableResult
    func record(_ request: URLRequest) -> Int {
        let data = request.httpBody ?? Self.drain(request.httpBodyStream)
        let body = data.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
        lock.lock()
        defer { lock.unlock() }
        storedMethods.append(request.httpMethod ?? "")
        storedBodies.append(body)
        return storedMethods.count - 1
    }

    var methods: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedMethods
    }

    var rawBodies: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedBodies
    }

    /// The body at `index` parsed back into a JSON object — `nil` for a
    /// bodyless request (the GETs) or an out-of-range index, so a missing
    /// request fails the `#require` at the call site instead of trapping.
    func json(at index: Int) -> [String: Any]? {
        let bodies = rawBodies
        guard bodies.indices.contains(index) else { return nil }
        guard let data = bodies[index].data(using: .utf8), !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// `URLProtocol` moves a PUT body onto `httpBodyStream`; drain it.
    private static func drain(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: 4096)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
