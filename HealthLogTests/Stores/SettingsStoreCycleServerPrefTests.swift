import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **Build 9 (Server-Prefs) / C6 — cycleTrackingOptIn server-backed.**
///
/// Real `APIClient` + `MockURLProtocol` + a real `CycleRepository` (in-memory
/// outbox) + a paired `BackendAvailability`. The router is stateful: a
/// `cycle-prefs` PATCH updates the value the `/me` projection then reports, so a
/// restart sees the migrated state. Pins migration-writes-exactly-once (with a
/// restart sim), no-ping-pong, no-write-for-default, tolerant-decode, the
/// explicit toggle, and logout hygiene. The full CycleGate server×local matrix
/// lives in `CycleGateTests`.
@MainActor
@Suite("SettingsStore cycle server-pref (Build 9)", .serialized)
struct SettingsStoreCycleServerPrefTests {
    private func makeClient() -> APIClient {
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

    private func makeStore(defaults: UserDefaults) throws -> SettingsStore {
        let api = makeClient()
        let cycleRepo = try CycleRepository(api: api, outbox: OutboxQueue(inMemory: true))
        // syncMode nil → `.paired` → hasServer == true.
        let backend = BackendAvailability(syncMode: nil, authStore: nil)
        return SettingsStore(
            repo: SettingsRepository(api: api),
            defaults: defaults,
            cycleRepo: cycleRepo,
            backend: backend
        )
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SettingsStoreCycleServerPrefTests.\(UUID().uuidString)")!
    }

    nonisolated static func consumeStream(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var buf = Data()
        var raw = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&raw, maxLength: 4096)
            guard read > 0 else { break }
            buf.append(raw, count: read)
        }
        return buf.isEmpty ? nil : buf
    }

    private final class RouterState: @unchecked Sendable {
        var serverCycleEnabled: Bool
        var includeField: Bool
        var patchCount = 0
        var lastPatchBody: [String: Any]?
        init(serverCycleEnabled: Bool, includeField: Bool = true) {
            self.serverCycleEnabled = serverCycleEnabled
            self.includeField = includeField
        }
    }

    private func installRouter(_ state: RouterState, gender: String = "female") {
        let g = "\"\(gender)\""
        let profileJSON = """
        {"data":{"username":"u","displayName":"U","email":"u@example.com",\
        "avatarUrl":null,"dateOfBirth":null,"gender":\(g),"heightCm":170,\
        "locale":"de","timezone":"Europe/Berlin","moodReminderEnabled":false},"error":null}
        """
        let hkJSON = #"{"data":{"entries":[],"lastSyncedAt":null},"error":null}"#
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            func ok(_ body: String) -> (HTTPURLResponse, Data?) {
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
            switch path {
            case "/api/user/profile":
                return ok(profileJSON)
            case "/api/integrations/healthkit":
                return ok(hkJSON)
            case "/api/auth/me":
                let field = state.includeField ? #","cycleTrackingEnabled":\#(state.serverCycleEnabled)"# : ""
                return ok(#"{"data":{"id":"u1","username":"u","avatarUrl":null\#(field)},"error":null}"#)
            case "/api/auth/me/cycle-prefs":
                if req.httpMethod == "PATCH" {
                    state.patchCount += 1
                    let body = req.httpBody ?? req.httpBodyStream.flatMap(Self.consumeStream(_:))
                    state.lastPatchBody = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    if let enabled = state.lastPatchBody?["enabled"] as? Bool {
                        state.serverCycleEnabled = enabled
                    }
                }
                return ok(#"{"data":{"cycleTrackingEnabled":\#(state.serverCycleEnabled)},"error":null}"#)
            default:
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
            }
        }
    }

    private static let optInKey = "hl.settings.cycleTracking.optIn"
    private static let serverEnabledKey = "hl.settings.cycleTracking.serverEnabled"
    private static let migratedKey = "hl.settings.cycleTracking.migrated.v1"

    // MARK: - 1. Migration writes exactly once (survives restart)

    @Test("Migration PATCHes {enabled:true} exactly once: local true + server false; restart never re-writes")
    func migrationWritesExactlyOnce() async throws {
        let defaults = makeDefaults()
        defaults.set(true, forKey: Self.optInKey) // local opt-in true, never migrated
        let state = RouterState(serverCycleEnabled: false)
        installRouter(state)

        let store1 = try makeStore(defaults: defaults)
        await store1.load()

        #expect(state.patchCount == 1)
        #expect(state.lastPatchBody?["enabled"] as? Bool == true)
        #expect(state.lastPatchBody?.count == 1) // deep-merge: only `enabled`
        #expect(store1.cycleTrackingOptIn == true) // adopted migrated-up
        #expect(defaults.bool(forKey: Self.migratedKey))

        let store2 = try makeStore(defaults: defaults) // restart
        await store2.load()
        #expect(state.patchCount == 1)
        #expect(store2.cycleTrackingOptIn == true)
    }

    // MARK: - 2. No write for the local default

    @Test("Local opt-in false → zero PATCHes, flag set")
    func noWriteForDefault() async throws {
        let defaults = makeDefaults()
        let state = RouterState(serverCycleEnabled: false)
        installRouter(state)

        let store = try makeStore(defaults: defaults)
        await store.load()

        #expect(state.patchCount == 0)
        #expect(store.cycleTrackingOptIn == false)
        #expect(defaults.bool(forKey: Self.migratedKey))
    }

    // MARK: - 3. No ping-pong

    @Test("A web opt-out (server false) is adopted, never written back")
    func noPingPong() async throws {
        let defaults = makeDefaults()
        defaults.set(true, forKey: Self.optInKey) // stale local true
        defaults.set(true, forKey: Self.migratedKey) // already migrated
        let state = RouterState(serverCycleEnabled: false)
        installRouter(state)

        let store = try makeStore(defaults: defaults)
        await store.load()

        #expect(store.cycleTrackingOptIn == false) // adopted server false
        #expect(store.cycleTrackingServerEnabled == false)
        #expect(state.patchCount == 0)
    }

    // MARK: - 4. Tolerant-decode

    @Test("Old server without the field → mirror nil, opt-in cache untouched")
    func tolerantDecode() async throws {
        let defaults = makeDefaults()
        defaults.set(true, forKey: Self.optInKey)
        let state = RouterState(serverCycleEnabled: false, includeField: false)
        installRouter(state)

        let store = try makeStore(defaults: defaults)
        await store.load()

        #expect(store.cycleTrackingServerEnabled == nil)
        #expect(store.cycleTrackingOptIn == true) // untouched
        #expect(state.patchCount == 0)
    }

    // MARK: - Explicit toggle

    @Test("setCycleTrackingOptIn PATCHes {enabled:true} in server mode and sticks")
    func explicitToggle() async throws {
        let defaults = makeDefaults()
        defaults.set(true, forKey: Self.migratedKey) // isolate from load migration
        let state = RouterState(serverCycleEnabled: false)
        installRouter(state)

        let store = try makeStore(defaults: defaults)
        await store.load()
        #expect(store.cycleTrackingOptIn == false)

        let ok = await store.setCycleTrackingOptIn(true)
        #expect(ok)
        #expect(state.patchCount == 1)
        #expect(state.lastPatchBody?["enabled"] as? Bool == true)
        #expect(store.cycleTrackingOptIn == true)
        #expect(store.cycleTrackingServerEnabled == true)
    }

    @Test("setCycleTrackingOptIn reverts the local cache on a server rejection")
    func explicitToggleRevertsOnError() async throws {
        let defaults = makeDefaults()
        defaults.set(true, forKey: Self.migratedKey)
        let state = RouterState(serverCycleEnabled: false)
        installRouter(state)
        let store = try makeStore(defaults: defaults)
        await store.load()

        // Reinstall a router whose cycle-prefs PATCH 422s.
        MockURLProtocol.handler = { req in
            if req.url?.path == "/api/auth/me/cycle-prefs" {
                let http = HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!
                return (http, Data(#"{"data":null,"error":"nope"}"#.utf8))
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
        let ok = await store.setCycleTrackingOptIn(true)
        #expect(ok == false)
        #expect(store.cycleTrackingOptIn == false) // reverted
        #expect(store.error != nil)
    }

    // MARK: - Logout

    @Test("clearOnLogout resets the opt-in + removes the mirror + flag")
    func logoutClears() async throws {
        let defaults = makeDefaults()
        defaults.set(true, forKey: Self.migratedKey)
        let state = RouterState(serverCycleEnabled: true)
        installRouter(state)

        let store = try makeStore(defaults: defaults)
        await store.load()
        #expect(store.cycleTrackingOptIn == true)
        #expect(defaults.object(forKey: Self.serverEnabledKey) as? Bool == true)

        store.clearOnLogout()
        #expect(store.cycleTrackingOptIn == false)
        #expect(store.cycleTrackingServerEnabled == nil)
        #expect(defaults.object(forKey: Self.optInKey) == nil)
        #expect(defaults.object(forKey: Self.serverEnabledKey) == nil)
        #expect(defaults.object(forKey: Self.migratedKey) == nil)
    }
}

// swiftlint:enable force_unwrapping
