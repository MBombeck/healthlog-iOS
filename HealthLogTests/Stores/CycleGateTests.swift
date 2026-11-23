import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// App-target tests for the `@Observable CycleGate` — it layers
/// `SettingsStore` (profile gender + explicit opt-in) + an injected
/// (no-prompt) biological-sex provider on top of the pure `CycleGateResolver`
/// (tested platform-free in the Core suite).
///
/// Drives `SettingsStore.load()` through `MockURLProtocol` so the profile
/// gender is real.
@MainActor
@Suite("CycleGate", .serialized, .mockURLSession)
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

    private func installProfileRouter(gender: String?, cycleEnabled: Bool? = nil) {
        let g = gender.map { "\"\($0)\"" } ?? "null"
        let profileJSON = """
        {"data":{"username":"u","displayName":"U","email":"u@example.com",\
        "avatarUrl":null,"dateOfBirth":null,"gender":\(g),"heightCm":170,\
        "locale":"de","timezone":"Europe/Berlin","moodReminderEnabled":false},"error":null}
        """
        // The /me projection carries the server-resolved
        // cycleTrackingEnabled when provided; absent = old-server (tolerant) path.
        let cycleField = cycleEnabled.map { #","cycleTrackingEnabled":\#($0)"# } ?? ""
        let meJSON = #"{"data":{"id":"u1","username":"u","email":"u@example.com","avatarUrl":null\#(cycleField)},"error":null}"#
        let hkJSON = #"{"data":{"entries":[],"lastSyncedAt":null},"error":null}"#
        MockURLProtocol.install { req in
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

    @Test("Female profile → available")
    func femaleAvailable() async {
        installProfileRouter(gender: "female")
        let settings = makeSettings()
        await settings.load()
        let gate = CycleGate(settings: settings)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == true)
    }

    // MARK: - Gender resolution

    @Test("Male profile → not available")
    func maleNotAvailable() async {
        installProfileRouter(gender: "male")
        let settings = makeSettings()
        await settings.load()
        let gate = CycleGate(settings: settings)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == false)
    }

    @Test("Other gender without opt-in → not available")
    func otherNoOptIn() async {
        installProfileRouter(gender: "other")
        let settings = makeSettings()
        await settings.load()
        let gate = CycleGate(settings: settings)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == false)
    }

    @Test("Other gender WITH explicit opt-in → available")
    func otherWithOptIn() async {
        installProfileRouter(gender: "other")
        let settings = makeSettings()
        await settings.load()
        settings.cycleTrackingOptIn = true
        let gate = CycleGate(settings: settings)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == true)
    }

    @Test("Nil gender + no HK signal → not available")
    func nilGenderNoSignal() async {
        installProfileRouter(gender: nil)
        let settings = makeSettings()
        await settings.load()
        let gate = CycleGate(settings: settings)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == false)
    }

    @Test("Nil gender + HK female (granted) → available via fallback")
    func hkFemaleFallback() async {
        installProfileRouter(gender: nil)
        let settings = makeSettings()
        await settings.load()
        let gate = CycleGate(
            settings: settings,
            biologicalSexProvider: { .female }
        )
        await gate.refreshAsync()
        #expect(gate.isCycleTrackingAvailable == true)
    }

    @Test("Nil gender + HK unknown (not granted) → not available")
    func hkUnknownNoFallback() async {
        installProfileRouter(gender: nil)
        let settings = makeSettings()
        await settings.load()
        let gate = CycleGate(
            settings: settings,
            biologicalSexProvider: { .unknown }
        )
        await gate.refreshAsync()
        #expect(gate.isCycleTrackingAvailable == false)
    }

    @Test("Nil gender + HK male (granted) → not available (never for men)")
    func hkMaleNoFallback() async {
        installProfileRouter(gender: nil)
        let settings = makeSettings()
        await settings.load()
        let gate = CycleGate(
            settings: settings,
            biologicalSexProvider: { .male }
        )
        await gate.refreshAsync()
        #expect(gate.isCycleTrackingAvailable == false)
    }

    @Test("Nil gender + HK notSet → not available")
    func hkNotSetNoFallback() async {
        installProfileRouter(gender: nil)
        let settings = makeSettings()
        await settings.load()
        let gate = CycleGate(
            settings: settings,
            biologicalSexProvider: { .notSet }
        )
        await gate.refreshAsync()
        #expect(gate.isCycleTrackingAvailable == false)
    }

    // MARK: - #30 module-gate integration

    @Test("Server module cycle=false WINS over a female profile")
    func serverModuleFalseOverridesFemale() async {
        installProfileRouter(gender: "female")
        let settings = makeSettings()
        await settings.load()
        let moduleGate = ModuleGate(modules: ["cycle": false])
        let gate = CycleGate(settings: settings, moduleGate: moduleGate)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == false)
    }

    @Test("Server module cycle=true keeps a female profile available")
    func serverModuleTrueKeepsAvailable() async {
        installProfileRouter(gender: "female")
        let settings = makeSettings()
        await settings.load()
        let moduleGate = ModuleGate(modules: ["cycle": true])
        let gate = CycleGate(settings: settings, moduleGate: moduleGate)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == true)
    }

    @Test("Absent module map → falls back to local gender resolution")
    func absentMapFallsBackToGender() async {
        installProfileRouter(gender: "female")
        let settings = makeSettings()
        await settings.load()
        // Map present but WITHOUT a cycle key → fall back to gender (female → on).
        let moduleGate = ModuleGate(modules: ["mood": false])
        let gate = CycleGate(settings: settings, moduleGate: moduleGate)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == true)
    }

    // MARK: - Server × local matrix (gate truth-table unchanged)

    /// Server `cycleTrackingEnabled:true` is adopted into the opt-in cache, so the
    /// gate is on even for a male profile (resolver rule 1 — explicit opt-in).
    @Test("Build 9 — server true → gate ON (adopted opt-in), even for a male profile")
    func serverTrueGateOn() async {
        installProfileRouter(gender: "male", cycleEnabled: true)
        let settings = makeSettings()
        await settings.load()
        #expect(settings.cycleTrackingOptIn == true) // adopted
        let gate = CycleGate(settings: settings)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == true)
    }

    /// Server `false` is adopted (opt-in cache false); the gate then follows the
    /// gender rule — a male profile stays OFF.
    @Test("Build 9 — server false + male → gate follows gender (OFF)")
    func serverFalseMaleGateOff() async {
        installProfileRouter(gender: "male", cycleEnabled: false)
        let settings = makeSettings()
        await settings.load()
        #expect(settings.cycleTrackingOptIn == false)
        let gate = CycleGate(settings: settings)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == false)
    }

    /// Documented §6.3 divergence: with NO ModuleGate map, a female profile keeps
    /// the gate ON via the gender rule even when the server-adopted opt-in is
    /// false (the gate truth-table is deliberately unchanged; only storage moved).
    @Test("Build 9 — server false + female (no module map) → gender rule keeps gate ON (§6.3)")
    func serverFalseFemaleGenderRuleOn() async {
        installProfileRouter(gender: "female", cycleEnabled: false)
        let settings = makeSettings()
        await settings.load()
        #expect(settings.cycleTrackingOptIn == false)
        let gate = CycleGate(settings: settings)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == true)
    }

    /// Old server (field absent): today's behaviour — a local opt-in true keeps
    /// the gate ON for a male profile (no server value to adopt).
    @Test("Build 9 — server nil (old server) + local opt-in true + male → gate ON")
    func serverNilLocalTrueGateOn() async {
        installProfileRouter(gender: "male") // no cycleEnabled → server nil
        let settings = makeSettings()
        await settings.load()
        settings.cycleTrackingOptIn = true // local override survives (no adoption)
        let gate = CycleGate(settings: settings)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == true)
    }

    /// Old server + local opt-in false + male → gate OFF (unchanged).
    @Test("Build 9 — server nil + local false + male → gate OFF")
    func serverNilLocalFalseGateOff() async {
        installProfileRouter(gender: "male")
        let settings = makeSettings()
        await settings.load()
        let gate = CycleGate(settings: settings)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == false)
    }

    /// Regression: the ModuleGate map still WINS over the adopted opt-in — a
    /// server map `cycle:true` keeps the gate ON even though the adopted
    /// cycleTrackingEnabled was false (CycleGate.swift:90-93 precedence unchanged).
    @Test("Build 9 — ModuleGate cycle:true wins over an adopted server-false opt-in")
    func moduleGateWinsOverAdoptedOptIn() async {
        installProfileRouter(gender: "male", cycleEnabled: false)
        let settings = makeSettings()
        await settings.load()
        #expect(settings.cycleTrackingOptIn == false)
        let moduleGate = ModuleGate(modules: ["cycle": true])
        let gate = CycleGate(settings: settings, moduleGate: moduleGate)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == true)
    }
}
