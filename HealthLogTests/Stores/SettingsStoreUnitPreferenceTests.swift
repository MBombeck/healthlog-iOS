import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **Build 9 (Server-Prefs) / C2 — `unitPreference` server-backed.**
///
/// Exercises `SettingsStore` over the **real** `APIClient` + `MockURLProtocol`
/// (never a mock server, PROJECT_GUIDE.md). The router is stateful: a PATCH to
/// `/api/auth/me/unit-preference` updates the value that the subsequent
/// `/api/auth/me` projection reports, so a second load sees the migrated state —
/// exactly the production round-trip. Pins the plan's mandatory matrix:
/// migration-writes-exactly-once (with a restart simulation via a second store
/// over the same `UserDefaults`), no-ping-pong, no-upload-for-defaults,
/// tolerant-decode, the `weightUnit` derivation, and logout hygiene.
@MainActor
@Suite("SettingsStore unitPreference (Build 9)", .serialized)
struct SettingsStoreUnitPreferenceTests {
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

    private func makeStore(defaults: UserDefaults) -> SettingsStore {
        // No SWR coordinator → the `loadDirect` path (profile + hk-config +
        // hydrateAuthMeExtras).
        SettingsStore(repo: SettingsRepository(api: makeClient()), defaults: defaults)
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SettingsStoreUnitPreferenceTests.\(UUID().uuidString)")!
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

    /// State shared with the `@Sendable` handler. A class box so the handler can
    /// mutate the server's stored unit + the PATCH counter/body across loads.
    private final class RouterState: @unchecked Sendable {
        var serverUnit: String
        var includeUnitField: Bool
        var patchCount = 0
        var lastPatchBody: [String: Any]?
        var failPatchStatus: Int?
        init(serverUnit: String, includeUnitField: Bool = true, failPatchStatus: Int? = nil) {
            self.serverUnit = serverUnit
            self.includeUnitField = includeUnitField
            self.failPatchStatus = failPatchStatus
        }
    }

    private func installRouter(_ state: RouterState) {
        let profileJSON = """
        {"data":{"username":"anna","displayName":"Anna","email":"anna@example.com",\
        "avatarUrl":null,"dateOfBirth":null,"gender":null,"heightCm":175,\
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
                let unit = state.includeUnitField ? #","unitPreference":"\#(state.serverUnit)""# : ""
                return ok(#"{"data":{"id":"u1","username":"anna","avatarUrl":null\#(unit)},"error":null}"#)
            case "/api/auth/me/unit-preference":
                if req.httpMethod == "PATCH" {
                    state.patchCount += 1
                    let body = req.httpBody ?? req.httpBodyStream.flatMap(Self.consumeStream(_:))
                    state.lastPatchBody = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    if let status = state.failPatchStatus {
                        let http = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                        return (http, Data(#"{"data":null,"error":"nope"}"#.utf8))
                    }
                    if let sent = state.lastPatchBody?["unitPreference"] as? String {
                        state.serverUnit = sent
                    }
                }
                return ok(#"{"data":{"unitPreference":"\#(state.serverUnit)"},"error":null}"#)
            default:
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
            }
        }
    }

    // MARK: - 1. Migration writes exactly once (survives restart)

    @Test("Migration PATCHes exactly once: local .lb + server metric → imperial, and a restart never re-writes")
    func migrationWritesExactlyOnce() async {
        let defaults = makeDefaults()
        // Existing user with an explicit .lb weight override, never migrated.
        defaults.set(WeightUnit.lb.rawValue, forKey: "hl.settings.weightUnit")
        let state = RouterState(serverUnit: "metric")
        installRouter(state)

        let store1 = makeStore(defaults: defaults)
        await store1.load()

        #expect(state.patchCount == 1)
        #expect(state.lastPatchBody?["unitPreference"] as? String == "imperial")
        #expect(store1.unitPreference == .imperial)
        // Override untouched — an explicit lb pick stays lb.
        #expect(store1.weightUnit == .lb)
        #expect(defaults.bool(forKey: "hl.settings.unitPref.migrated.v1"))

        // Restart simulation: a fresh store over the SAME defaults must not re-PATCH.
        let store2 = makeStore(defaults: defaults)
        await store2.load()
        #expect(state.patchCount == 1)
        #expect(store2.unitPreference == .imperial)
    }

    // MARK: - 2. No ping-pong

    @Test("No ping-pong: a web-side unit change is adopted, never written back")
    func noPingPong() async {
        let defaults = makeDefaults()
        // Already migrated; no explicit override.
        defaults.set(true, forKey: "hl.settings.unitPref.migrated.v1")
        let state = RouterState(serverUnit: "imperial") // web flipped it to imperial
        installRouter(state)

        let store = makeStore(defaults: defaults)
        await store.load()

        #expect(store.unitPreference == .imperial)
        #expect(store.weightUnit == .lb) // derived, no override
        #expect(state.patchCount == 0)
    }

    // MARK: - 3. Server default + local defaults → no upload

    @Test("Server metric + fresh local defaults → zero PATCHes, flag set")
    func noUploadForDefaults() async {
        let defaults = makeDefaults()
        let state = RouterState(serverUnit: "metric")
        installRouter(state)

        let store = makeStore(defaults: defaults)
        await store.load()

        #expect(state.patchCount == 0)
        #expect(store.unitPreference == .metric)
        #expect(store.weightUnit == .kg)
        #expect(defaults.bool(forKey: "hl.settings.unitPref.migrated.v1"))
    }

    // MARK: - 4. Tolerant-decode

    @Test("Old server without unitPreference → mirror holds, no crash, no write")
    func tolerantDecode() async {
        let defaults = makeDefaults()
        // A pre-seeded mirror (e.g. an earlier build).
        defaults.set(HLUnitPreference.imperial.rawValue, forKey: HLUnitPreference.defaultsKey)
        let state = RouterState(serverUnit: "metric", includeUnitField: false)
        installRouter(state)

        let store = makeStore(defaults: defaults)
        await store.load()

        #expect(store.unitPreference == .imperial) // held from the mirror
        #expect(defaults.string(forKey: HLUnitPreference.defaultsKey) == "imperial")
        #expect(state.patchCount == 0)
    }

    // MARK: - 5. weightUnit derivation

    @Test("Without an override weightUnit follows the server flip; an explicit pick is preserved")
    func weightUnitDerivation() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "hl.settings.unitPref.migrated.v1") // isolate from migration
        let state = RouterState(serverUnit: "metric")
        installRouter(state)

        let store = makeStore(defaults: defaults)
        await store.load()
        #expect(store.weightUnit == .kg) // metric → kg, no override

        // Web flips the binary → a second load adopts it and weightUnit follows.
        state.serverUnit = "imperial"
        await store.load()
        #expect(store.unitPreference == .imperial)
        #expect(store.weightUnit == .lb)

        // An explicit weight pick becomes an override that survives the flip.
        store.weightUnit = .kg
        #expect(store.weightUnit == .kg)
        #expect(defaults.string(forKey: "hl.settings.weightUnit") == "kg")

        // A fresh store over the same defaults reads the persisted override.
        let store2 = makeStore(defaults: defaults)
        #expect(store2.weightUnit == .kg)
    }

    // MARK: - Explicit user toggle

    @Test("setUnitPreference optimistically PATCHes and hard-sets the echoed value")
    func explicitTogglePersists() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "hl.settings.unitPref.migrated.v1")
        let state = RouterState(serverUnit: "metric")
        installRouter(state)

        let store = makeStore(defaults: defaults)
        await store.load()
        #expect(store.unitPreference == .metric)

        let ok = await store.setUnitPreference(.imperial)
        #expect(ok)
        #expect(state.patchCount == 1)
        #expect(store.unitPreference == .imperial)
        #expect(defaults.string(forKey: HLUnitPreference.defaultsKey) == "imperial")
    }

    @Test("setUnitPreference reverts to the prior value on a server rejection")
    func explicitToggleRevertsOnError() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "hl.settings.unitPref.migrated.v1")
        let state = RouterState(serverUnit: "metric", failPatchStatus: 422)
        installRouter(state)

        let store = makeStore(defaults: defaults)
        await store.load()
        #expect(store.unitPreference == .metric)

        let ok = await store.setUnitPreference(.imperial)
        #expect(ok == false)
        #expect(store.unitPreference == .metric) // reverted
        #expect(store.error != nil)
    }

    @Test("A deterministic 4xx during migration sets the flag to prevent a retry loop")
    func migration4xxSetsFlag() async {
        let defaults = makeDefaults()
        defaults.set(WeightUnit.lb.rawValue, forKey: "hl.settings.weightUnit")
        let state = RouterState(serverUnit: "metric", failPatchStatus: 422)
        installRouter(state)

        let store = makeStore(defaults: defaults)
        await store.load()

        #expect(state.patchCount == 1)
        #expect(defaults.bool(forKey: "hl.settings.unitPref.migrated.v1"))
        // The write failed → the value was NOT adopted.
        #expect(store.unitPreference == .metric)
    }

    // MARK: - 6. Logout hygiene

    @Test("clearOnLogout removes the mirror + flag and resets the property to metric")
    func logoutClears() async {
        let defaults = makeDefaults()
        let state = RouterState(serverUnit: "imperial")
        defaults.set(true, forKey: "hl.settings.unitPref.migrated.v1")
        installRouter(state)

        let store = makeStore(defaults: defaults)
        await store.load()
        #expect(store.unitPreference == .imperial)
        #expect(defaults.string(forKey: HLUnitPreference.defaultsKey) == "imperial")

        store.clearOnLogout()
        #expect(store.unitPreference == .metric)
        #expect(defaults.object(forKey: HLUnitPreference.defaultsKey) == nil)
        #expect(defaults.object(forKey: "hl.settings.unitPref.migrated.v1") == nil)
    }
}

// swiftlint:enable force_unwrapping
