import Foundation

// swiftlint:disable force_unwrapping
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// **GH #83 — Settings → Health Score, the store behind the surface.**
///
/// The one behaviour worth defending here is the difference between a *failure*
/// and a *refusal*. The server answers a too-narrow selection with a `422` and a
/// reason; presenting that as "something went wrong" would be a lie about what
/// happened and would leave the person with nothing to act on. So the store
/// keeps the two outcomes apart by type, and it keeps the person's ticks after a
/// refusal rather than snapping them back to what the server still holds.
///
/// Equally deliberate is what is **not** here: no test asserts that the store
/// predicts a refusal, because it must not. The lower bound counts fields of
/// health, not pillars, and the pillar→field mapping rides no wire.
@Suite("GH #83 — health-score config store", .serialized)
@MainActor
struct HealthScoreConfigStoreTests {
    /// The suite is `@MainActor` (the store is), but the mock handler runs off
    /// it — so the fixtures the handler reaches for are `nonisolated`.
    private nonisolated static let path = "/api/auth/me/health-score-config"

    private func makeStore() -> HealthScoreConfigStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        return HealthScoreConfigStore(repo: HealthScoreConfigRepository(api: api))
    }

    private nonisolated static func ok(_ req: URLRequest, _ json: String) -> (HTTPURLResponse, Data?) {
        (
            HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            Data("{\"data\":\(json)}".utf8)
        )
    }

    private nonisolated static let loaded = """
    {"pillars":["BLOOD_PRESSURE","GLYCAEMIA","ACTIVITY","SLEEP"],"excludedPillars":["WELLBEING"],\
    "hasSelection":true,"version":2,"updatedAt":"T0"}
    """

    @Test("load seeds the ticks from the server's resolved composition")
    func loadSeedsSelection() async {
        MockURLProtocol.handler = { req in Self.ok(req, Self.loaded) }
        let store = makeStore()
        await store.load()
        #expect(store.selection == [.bloodPressure, .glycaemia, .activity, .sleep])
        #expect(!store.hasChanges)
        #expect(store.isOn(.sleep))
        #expect(!store.isOn(.wellbeing))
    }

    @Test("the offered catalogue keeps a pillar this build does not know")
    func offersUnknownPillar() async {
        MockURLProtocol.handler = { req in
            Self.ok(req, """
            {"pillars":["SLEEP","VO2MAX_NEXT"],"excludedPillars":["ACTIVITY"],"hasSelection":true,\
            "version":1,"updatedAt":"T0"}
            """)
        }
        let store = makeStore()
        await store.load()
        // Dropping it from the list would drop it from the next save's body,
        // silently deselecting something the person never touched.
        #expect(store.offeredPillars.contains(.unknown("VO2MAX_NEXT")))
        #expect(store.isOn(.unknown("VO2MAX_NEXT")))
    }

    @Test("save sends the ticked set in registry order and adopts the echo")
    func saveSendsRegistryOrder() async {
        nonisolated(unsafe) var sent: [String]?
        MockURLProtocol.handler = { req in
            guard req.targets(Self.path, method: "PATCH") else { return Self.ok(req, Self.loaded) }
            let raw = req.bodyOrStream().flatMap { try? JSONSerialization.jsonObject(with: $0) }
            sent = (raw as? [String: Any])?["pillars"] as? [String]
            return Self.ok(req, """
            {"pillars":["BLOOD_PRESSURE","SLEEP"],"excludedPillars":["GLYCAEMIA","ACTIVITY","WELLBEING"],\
            "hasSelection":true,"version":3,"updatedAt":"T1"}
            """)
        }
        let store = makeStore()
        await store.load()
        // Untick in a deliberately unhelpful order — the body must still read
        // the way the server's own catalogue does.
        store.toggle(.activity, isOn: false)
        store.toggle(.glycaemia, isOn: false)
        #expect(store.hasChanges)
        await store.save()

        #expect(sent == ["BLOOD_PRESSURE", "SLEEP"])
        #expect(store.outcome == .saved)
        #expect(!store.hasChanges)
    }

    @Test("save is not offered when nothing moved — an unchanged write would bump the recipe version")
    func noChangesNoSave() async {
        MockURLProtocol.handler = { req in Self.ok(req, Self.loaded) }
        let store = makeStore()
        await store.load()
        #expect(!store.hasChanges)
        store.toggle(.sleep, isOn: false)
        #expect(store.hasChanges)
        store.toggle(.sleep, isOn: true)
        #expect(!store.hasChanges)
    }

    @Test(
        "a refusal is an explanation, not a failure — and the ticks survive it",
        arguments: ["three_domains_required", "measured_physiological_domain_required"]
    )
    func refusalIsNotFailure(rawReason: String) async {
        MockURLProtocol.handler = { req in
            guard req.targets(Self.path, method: "PATCH") else { return Self.ok(req, Self.loaded) }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!,
                Data("""
                {"data":null,"error":"server prose written for the web client",\
                "meta":{"errorCode":"health_score_config.too_narrow","reason":"\(rawReason)"}}
                """.utf8)
            )
        }
        let store = makeStore()
        await store.load()
        store.toggle(.bloodPressure, isOn: false)
        store.toggle(.glycaemia, isOn: false)
        store.toggle(.activity, isOn: false)
        await store.save()

        #expect(store.outcome == .refused(HealthScoreBreadthReason(rawValue: rawReason)))
        // The selection the person built is still on screen, so the next
        // attempt starts from what they meant rather than from the server's
        // last accepted state.
        #expect(store.selection == [.sleep])
        #expect(store.hasChanges)
    }

    @Test("the refusal explanation is our own sentence, never the server's prose")
    func refusalTextIsOurs() async {
        let serverProse = "server prose written for the web client"
        MockURLProtocol.handler = { req in
            guard req.targets(Self.path, method: "PATCH") else { return Self.ok(req, Self.loaded) }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!,
                Data("""
                {"data":null,"error":"\(serverProse)",\
                "meta":{"errorCode":"health_score_config.too_narrow","reason":"three_domains_required"}}
                """.utf8)
            )
        }
        let store = makeStore()
        await store.load()
        store.toggle(.sleep, isOn: false)
        await store.save()

        guard case let .refused(reason) = store.outcome else {
            Issue.record("expected a refusal, got \(store.outcome)")
            return
        }
        let shown = HealthScorePresentation.explanation(for: reason)
        #expect(!shown.contains(serverProse))
        #expect(!shown.isEmpty)
    }

    @Test("changing a tick clears a stale refusal — an explanation must not outlive what it explained")
    func toggleClearsRefusal() async {
        MockURLProtocol.handler = { req in
            guard req.targets(Self.path, method: "PATCH") else { return Self.ok(req, Self.loaded) }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!,
                Data("""
                {"data":null,"error":"x","meta":{"errorCode":"health_score_config.too_narrow",\
                "reason":"three_domains_required"}}
                """.utf8)
            )
        }
        let store = makeStore()
        await store.load()
        store.toggle(.sleep, isOn: false)
        await store.save()
        #expect(store.outcome != .idle)
        store.toggle(.wellbeing, isOn: true)
        #expect(store.outcome == .idle)
    }

    @Test("a transport failure is a failure, not a refusal")
    func transportFailureStaysFailure() async {
        MockURLProtocol.handler = { req in
            guard req.targets(Self.path, method: "PATCH") else { return Self.ok(req, Self.loaded) }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null,"error":"boom"}"#.utf8)
            )
        }
        let store = makeStore()
        await store.load()
        store.toggle(.sleep, isOn: false)
        await store.save()
        guard case .failed = store.outcome else {
            Issue.record("expected a failure, got \(store.outcome)")
            return
        }
    }

    @Test("a first load that never lands offers a retry instead of an empty card")
    func loadFailure() async {
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null,"error":"boom"}"#.utf8)
            )
        }
        let store = makeStore()
        await store.load()
        #expect(store.loadFailed)
        #expect(store.config == nil)
    }
}

private extension URLRequest {
    func bodyOrStream() -> Data? {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// swiftlint:enable force_unwrapping
