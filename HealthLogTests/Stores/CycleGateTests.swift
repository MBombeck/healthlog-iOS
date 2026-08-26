import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// App-target tests for the `@Observable CycleGate` — it layers the
/// `cycleTracking` feature flag + `SettingsStore` (profile gender + explicit
/// opt-in) + an injected (no-prompt) biological-sex provider on top of the
/// pure `CycleGateResolver` (tested platform-free in the Core suite).
///
/// Drives `SettingsStore.load()` through `MockURLProtocol` so the profile
/// gender is real, and constructs a `FeatureFlagsStore` whose `cycleTracking`
/// flag is flipped ON via the wire (default is OFF).
@MainActor
@Suite("CycleGate", .serialized)
struct CycleGateTests {
    private func makeClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.8",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private func makeSettings() -> SettingsStore {
        let repo = SettingsRepository(api: makeClient())
        let defaults = UserDefaults(suiteName: "CycleGateTests.\(UUID().uuidString)")!
        return SettingsStore(repo: repo, defaults: defaults)
    }

    /// Feature-flags store with `cycle.tracking` deployed ON (wire flips the
    /// default-OFF). Returns a store that has already refreshed.
    private func makeFlagsStoreEnabled() async -> FeatureFlagsStore {
        let repo = FeatureFlagsRepository(api: makeClient())
        let store = FeatureFlagsStore(repo: repo)
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":{"flags":{"cycle.tracking":true}},"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.refresh()
        return store
    }

    private func installProfileRouter(gender: String?, cycleEnabled: Bool? = nil) {
        let g = gender.map { "\"\($0)\"" } ?? "null"
        let profileJSON = """
        {"data":{"username":"u","displayName":"U","email":"u@example.com",\
        "avatarUrl":null,"dateOfBirth":null,"gender":\(g),"heightCm":170,\
        "locale":"de","timezone":"Europe/Berlin","moodReminderEnabled":false},"error":null}
        """
        // Build 9 (9.3) — the /me projection carries the server-resolved
        // cycleTrackingEnabled when provided; absent = old-server (tolerant) path.
        let cycleField = cycleEnabled.map { #","cycleTrackingEnabled":\#($0)"# } ?? ""
        let meJSON = #"{"data":{"id":"u1","username":"u","email":"u@example.com","avatarUrl":null\#(cycleField)},"error":null}"#
        let hkJSON = #"{"data":{"entries":[],"lastSyncedAt":null},"error":null}"#
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            let body: String
            switch path {
            case "/api/user/profile": body = profileJSON
            case "/api/auth/me": body = meJSON
            case "/api/integrations/healthkit": body = hkJSON
            default:
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
    }

    // MARK: - Feature-flag gating

    @Test("Flag OFF → never available, even for a female profile")
    func flagOffSuppresses() async {
        // Default is now ON, so test the suppression path by injecting the
        // server flag explicitly OFF (mirrors makeFlagsStoreEnabled with false).
        let repo = FeatureFlagsRepository(api: makeClient())
        let flags = FeatureFlagsStore(repo: repo)
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":{"flags":{"cycle.tracking":false}},"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await flags.refresh()
        installProfileRouter(gender: "female")
        let settings = makeSettings()
        await settings.load()
        let gate = CycleGate(settings: settings, featureFlags: flags)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == false)
    }

    @Test("Flag ON + female profile → available")
    func flagOnFemaleAvailable() async {
        let flags = await makeFlagsStoreEnabled()
        installProfileRouter(gender: "female")
        let settings = makeSettings()
        await settings.load()
        let gate = CycleGate(settings: settings, featureFlags: flags)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == true)
    }

    // MARK: - Gender resolution (flag ON throughout)

    @Test("Flag ON + male profile → not available")
    func maleNotAvailable() async {
        let flags = await makeFlagsStoreEnabled()
        installProfileRouter(gender: "male")
        let settings = makeSettings()
        await settings.load()
        let gate = CycleGate(settings: settings, featureFlags: flags)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == false)
    }

    @Test("Flag ON + other gender without opt-in → not available")
    func otherNoOptIn() async {
        let flags = await makeFlagsStoreEnabled()
        installProfileRouter(gender: "other")
        let settings = makeSettings()
        await settings.load()
        let gate = CycleGate(settings: settings, featureFlags: flags)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == false)
    }

    @Test("Flag ON + other gender WITH explicit opt-in → available")
    func otherWithOptIn() async {
        let flags = await makeFlagsStoreEnabled()
        installProfileRouter(gender: "other")
        let settings = makeSettings()
        await settings.load()
        settings.cycleTrackingOptIn = true
        let gate = CycleGate(settings: settings, featureFlags: flags)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == true)
    }

    @Test("Flag ON + nil gender + no HK signal → not available")
    func nilGenderNoSignal() async {
        let flags = await makeFlagsStoreEnabled()
        installProfileRouter(gender: nil)
        let settings = makeSettings()
        await settings.load()
        let gate = CycleGate(settings: settings, featureFlags: flags)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == false)
    }

    @Test("Flag ON + nil gender + HK female (granted) → available via fallback")
    func hkFemaleFallback() async {
        let flags = await makeFlagsStoreEnabled()
        installProfileRouter(gender: nil)
        let settings = makeSettings()
        await settings.load()
        let gate = CycleGate(
            settings: settings,
            featureFlags: flags,
            biologicalSexProvider: { .female }
        )
        await gate.refreshAsync()
        #expect(gate.isCycleTrackingAvailable == true)
    }

    @Test("Flag ON + nil gender + HK unknown (not granted) → not available")
    func hkUnknownNoFallback() async {
        let flags = await makeFlagsStoreEnabled()
        installProfileRouter(gender: nil)
        let settings = makeSettings()
        await settings.load()
        let gate = CycleGate(
            settings: settings,
            featureFlags: flags,
            biologicalSexProvider: { .unknown }
        )
        await gate.refreshAsync()
        #expect(gate.isCycleTrackingAvailable == false)
    }

    @Test("Flag ON + nil gender + HK male (granted) → not available (never for men)")
    func hkMaleNoFallback() async {
        let flags = await makeFlagsStoreEnabled()
        installProfileRouter(gender: nil)
        let settings = makeSettings()
        await settings.load()
        let gate = CycleGate(
            settings: settings,
            featureFlags: flags,
            biologicalSexProvider: { .male }
        )
        await gate.refreshAsync()
        #expect(gate.isCycleTrackingAvailable == false)
    }

    @Test("Flag ON + nil gender + HK notSet → not available")
    func hkNotSetNoFallback() async {
        let flags = await makeFlagsStoreEnabled()
        installProfileRouter(gender: nil)
        let settings = makeSettings()
        await settings.load()
        let gate = CycleGate(
            settings: settings,
            featureFlags: flags,
            biologicalSexProvider: { .notSet }
        )
        await gate.refreshAsync()
        #expect(gate.isCycleTrackingAvailable == false)
    }

    // MARK: - #30 module-gate integration

    @Test("Server module cycle=false WINS over a female profile")
    func serverModuleFalseOverridesFemale() async {
        let flags = await makeFlagsStoreEnabled()
        installProfileRouter(gender: "female")
        let settings = makeSettings()
        await settings.load()
        let moduleGate = ModuleGate(modules: ["cycle": false])
        let gate = CycleGate(settings: settings, featureFlags: flags, moduleGate: moduleGate)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == false)
    }

    @Test("Server module cycle=true keeps a female profile available")
    func serverModuleTrueKeepsAvailable() async {
        let flags = await makeFlagsStoreEnabled()
        installProfileRouter(gender: "female")
        let settings = makeSettings()
        await settings.load()
        let moduleGate = ModuleGate(modules: ["cycle": true])
        let gate = CycleGate(settings: settings, featureFlags: flags, moduleGate: moduleGate)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == true)
    }

    @Test("Absent module map → falls back to local gender resolution")
    func absentMapFallsBackToGender() async {
        let flags = await makeFlagsStoreEnabled()
        installProfileRouter(gender: "female")
        let settings = makeSettings()
        await settings.load()
        // Map present but WITHOUT a cycle key → fall back to gender (female → on).
        let moduleGate = ModuleGate(modules: ["mood": false])
        let gate = CycleGate(settings: settings, featureFlags: flags, moduleGate: moduleGate)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == true)
    }

    // MARK: - Build 9 (9.3) — server × local matrix (gate truth-table unchanged)

    /// Server `cycleTrackingEnabled:true` is adopted into the opt-in cache, so the
    /// gate is on even for a male profile (resolver rule 1 — explicit opt-in).
    @Test("Build 9 — server true → gate ON (adopted opt-in), even for a male profile")
    func serverTrueGateOn() async {
        let flags = await makeFlagsStoreEnabled()
        installProfileRouter(gender: "male", cycleEnabled: true)
        let settings = makeSettings()
        await settings.load()
        #expect(settings.cycleTrackingOptIn == true) // adopted
        let gate = CycleGate(settings: settings, featureFlags: flags)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == true)
    }

    /// Server `false` is adopted (opt-in cache false); the gate then follows the
    /// gender rule — a male profile stays OFF.
    @Test("Build 9 — server false + male → gate follows gender (OFF)")
    func serverFalseMaleGateOff() async {
        let flags = await makeFlagsStoreEnabled()
        installProfileRouter(gender: "male", cycleEnabled: false)
        let settings = makeSettings()
        await settings.load()
        #expect(settings.cycleTrackingOptIn == false)
        let gate = CycleGate(settings: settings, featureFlags: flags)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == false)
    }

    /// Documented §6.3 divergence: with NO ModuleGate map, a female profile keeps
    /// the gate ON via the gender rule even when the server-adopted opt-in is
    /// false (the gate truth-table is deliberately unchanged; only storage moved).
    @Test("Build 9 — server false + female (no module map) → gender rule keeps gate ON (§6.3)")
    func serverFalseFemaleGenderRuleOn() async {
        let flags = await makeFlagsStoreEnabled()
        installProfileRouter(gender: "female", cycleEnabled: false)
        let settings = makeSettings()
        await settings.load()
        #expect(settings.cycleTrackingOptIn == false)
        let gate = CycleGate(settings: settings, featureFlags: flags)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == true)
    }

    /// Old server (field absent): today's behaviour — a local opt-in true keeps
    /// the gate ON for a male profile (no server value to adopt).
    @Test("Build 9 — server nil (old server) + local opt-in true + male → gate ON")
    func serverNilLocalTrueGateOn() async {
        let flags = await makeFlagsStoreEnabled()
        installProfileRouter(gender: "male") // no cycleEnabled → server nil
        let settings = makeSettings()
        await settings.load()
        settings.cycleTrackingOptIn = true // local override survives (no adoption)
        let gate = CycleGate(settings: settings, featureFlags: flags)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == true)
    }

    /// Old server + local opt-in false + male → gate OFF (unchanged).
    @Test("Build 9 — server nil + local false + male → gate OFF")
    func serverNilLocalFalseGateOff() async {
        let flags = await makeFlagsStoreEnabled()
        installProfileRouter(gender: "male")
        let settings = makeSettings()
        await settings.load()
        let gate = CycleGate(settings: settings, featureFlags: flags)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == false)
    }

    /// Regression: the ModuleGate map still WINS over the adopted opt-in — a
    /// server map `cycle:true` keeps the gate ON even though the adopted
    /// cycleTrackingEnabled was false (CycleGate.swift:90-93 precedence unchanged).
    @Test("Build 9 — ModuleGate cycle:true wins over an adopted server-false opt-in")
    func moduleGateWinsOverAdoptedOptIn() async {
        let flags = await makeFlagsStoreEnabled()
        installProfileRouter(gender: "male", cycleEnabled: false)
        let settings = makeSettings()
        await settings.load()
        #expect(settings.cycleTrackingOptIn == false)
        let moduleGate = ModuleGate(modules: ["cycle": true])
        let gate = CycleGate(settings: settings, featureFlags: flags, moduleGate: moduleGate)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == true)
    }
}
