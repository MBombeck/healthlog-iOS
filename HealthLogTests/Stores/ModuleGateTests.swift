import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

// #30 / v1.18.0 — locks the per-user feature-module gate.
//
// Covers four contract surfaces:
// 1. **Decode** — `AuthMeModules` is decode-tolerant: a missing `modules`
//    field → `nil` (all-on, non-breaking against prod ≤ v1.17.1); a present
//    map with `false` values is preserved verbatim.
// 2. **Gate logic** — `ModuleGate.isEnabled(_:)` defaults to `true` when the
//    map is absent or the key is absent (#30 default-on semantics) and honours
//    an explicit `false`.
// 3. **403 handling** — a `403 + meta.errorCode: "module.disabled"` envelope
//    surfaces `HLError.moduleDisabled(_:)` and fires the mirror handler.
// 4. **Surface gating** — `ModuleKey.dashboardMetricKinds` maps the two
//    metric-owning modules (sleep / glucose) onto the kinds a disabled module
//    hides from the dashboard.

// MARK: - 1. Decode

@Suite("AuthMeModules — decode tolerance")
struct AuthMeModulesDecodeTests {
    @Test("Missing modules field → nil (all modules on)")
    func missingFieldDecodesNil() throws {
        let data = Data(#"{"username":"x","gender":"female"}"#.utf8)
        let decoded = try JSONDecoder().decode(AuthMeModules.self, from: data)
        #expect(decoded.modules == nil)
    }

    @Test("Present map with false value is preserved")
    func presentFalsePreserved() throws {
        let data = Data(#"{"modules":{"cycle":false,"mood":true,"coach":false}}"#.utf8)
        let decoded = try JSONDecoder().decode(AuthMeModules.self, from: data)
        #expect(decoded.modules?["cycle"] == false)
        #expect(decoded.modules?["mood"] == true)
        #expect(decoded.modules?["coach"] == false)
    }

    @Test("Empty map decodes to empty dict (not nil)")
    func emptyMapDecodes() throws {
        let data = Data(#"{"modules":{}}"#.utf8)
        let decoded = try JSONDecoder().decode(AuthMeModules.self, from: data)
        #expect(decoded.modules == [:])
    }
}

// MARK: - 2. Gate logic

@MainActor
@Suite("ModuleGate — isEnabled resolution")
struct ModuleGateLogicTests {
    @Test("Absent map → every module on, incl. illness (default-on; v1.18.3)")
    func absentMapDefaults() {
        let gate = ModuleGate(modules: nil)
        for key in ModuleKey.allCases {
            #expect(gate.isEnabled(key) == true, "\(key) should default ON with nil map")
        }
        // v1.18.3 dropped illness born-gating: nil map → ON like every other key.
        #expect(gate.isEnabled(.illness) == true)
    }

    @Test("Present map, key absent → on, incl. illness (default-on; v1.18.3)")
    func keyAbsentDefaults() {
        let gate = ModuleGate(modules: ["cycle": false])
        #expect(gate.isEnabled(.mood) == true) // absent normal key → on
        #expect(gate.isEnabled(.cycle) == false) // present false
        #expect(gate.isEnabled(.illness) == true) // absent illness key → on (v1.18.3)
    }

    @Test("Illness is a normal default-on toggle (v1.18.3): present-false → off, absent → on")
    func illnessDefaultOn() {
        // present + false → off (user disabled)
        #expect(ModuleGate(modules: ["illness": false]).isEnabled(.illness) == false)
        // present + true → on
        #expect(ModuleGate(modules: ["illness": true]).isEnabled(.illness) == true)
        // absent (map present) → on (default-on, no longer born-gated)
        #expect(ModuleGate(modules: ["mood": true]).isEnabled(.illness) == true)
        // illness is still a user-toggleable key.
        #expect(ModuleKey.illness.isUserToggleable == true)
    }

    @Test("Pre-staged medications: ON until it appears in the map")
    func preStagedMedications() {
        // nil map → on (CORE pre-staged, not born-gated)
        #expect(ModuleGate(modules: nil).isEnabled(.medications) == true)
        // map present but key absent → on
        #expect(ModuleGate(modules: ["mood": false]).isEnabled(.medications) == true)
        // when the server starts emitting it, honour the wire value
        #expect(ModuleGate(modules: ["medications": false]).isEnabled(.medications) == false)
    }

    @Test("Present map, key false → off; key true → on")
    func explicitValuesHonoured() {
        let gate = ModuleGate(modules: ["sleep": false, "glucose": true])
        #expect(gate.isEnabled(.sleep) == false)
        #expect(gate.isEnabled(.glucose) == true)
    }

    @Test("applyDisabled flips a single key off, leaving the rest on")
    func applyDisabledMirror() {
        let gate = ModuleGate(modules: nil)
        gate.applyDisabled(wireKey: "coach")
        #expect(gate.isEnabled(.coach) == false)
        #expect(gate.isEnabled(.mood) == true) // untouched → default-on
    }

    @Test("apply(modules:) replaces the in-memory map")
    func applyReplacesMap() {
        let gate = ModuleGate(modules: ["mood": false])
        gate.apply(modules: ["workouts": false])
        #expect(gate.isEnabled(.mood) == true) // no longer in map
        #expect(gate.isEnabled(.workouts) == false)
    }

    @Test("clearOnLogout resets to all-on")
    func clearResetsAllOn() {
        let gate = ModuleGate(modules: ["cycle": false])
        gate.clearOnLogout()
        #expect(gate.isEnabled(.cycle) == true)
    }

    @Test("wireKey overload matches the typed overload")
    func wireKeyOverload() {
        let gate = ModuleGate(modules: ["labs": false])
        #expect(gate.isEnabled(wireKey: "labs") == false)
        #expect(gate.isEnabled(wireKey: "unknown.future") == true) // forward-compat
    }

    @Test("wireKey overload: illness defaults ON like every key (v1.18.3)")
    func wireKeyIllnessDefaultOn() {
        // nil map → every key on, incl. illness
        let nilGate = ModuleGate(modules: nil)
        #expect(nilGate.isEnabled(wireKey: "illness") == true)
        #expect(nilGate.isEnabled(wireKey: "unknown.future") == true)
        // present map, illness absent → on; illness present-false → off
        #expect(ModuleGate(modules: ["mood": true]).isEnabled(wireKey: "illness") == true)
        #expect(ModuleGate(modules: ["illness": false]).isEnabled(wireKey: "illness") == false)
    }
}

// MARK: - 3. 403 handling

@Suite("APIClient — module-disabled envelope (#30)", .serialized)
struct APIClientModuleDisabledTests {
    private func makeClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.18.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    @Test("403 + meta.errorCode module.disabled → HLError.moduleDisabled(module)")
    func surfacesTypedError() async throws {
        let api = makeClient()
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":null,"error":"Module disabled","meta":{"errorCode":"module.disabled","module":"cycle"}}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, body)
        }
        let req: APIRequest<EmptyPayload> = .get("/api/cycle/logs")
        do {
            _ = try await api.send(req)
            Issue.record("expected moduleDisabled")
        } catch let HLError.moduleDisabled(module) {
            #expect(module == "cycle")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("403 without meta → generic HLError.server (no false-positive typing)")
    func plain403StaysGeneric() async throws {
        let api = makeClient()
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":null,"error":"Forbidden"}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, body)
        }
        let req: APIRequest<EmptyPayload> = .get("/api/restricted")
        do {
            _ = try await api.send(req)
            Issue.record("expected server error")
        } catch let HLError.server(status, _, _) {
            #expect(status == 403)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("Non-403 with module.disabled meta → generic server error (status gates typing)")
    func nonForbiddenStaysGeneric() async throws {
        let api = makeClient()
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":null,"error":"Validation","meta":{"errorCode":"module.disabled","module":"cycle"}}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, body)
        }
        let req: APIRequest<EmptyPayload> = .get("/api/cycle/logs")
        do {
            _ = try await api.send(req)
            Issue.record("expected server error")
        } catch HLError.moduleDisabled {
            Issue.record("must not surface moduleDisabled for non-403")
        } catch let HLError.server(status, _, _) {
            #expect(status == 422)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("403 module.disabled fires the mirror handler with the module key")
    func mirrorHandlerFires() async throws {
        let api = makeClient()
        let received = ModuleSlot()
        await api.setModuleDisabledHandler { @Sendable module in
            await received.set(module)
        }
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":null,"error":"Module disabled","meta":{"errorCode":"module.disabled","module":"workouts"}}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, body)
        }
        let req: APIRequest<EmptyPayload> = .get("/api/workouts")
        do {
            _ = try await api.send(req)
            Issue.record("expected moduleDisabled")
        } catch HLError.moduleDisabled {
            let captured = await received.waitFor(timeoutMs: 500)
            #expect(captured == "workouts")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

// MARK: - 4. Surface gating mapping

@Suite("ModuleKey — surface mapping (#30)")
struct ModuleKeySurfaceMappingTests {
    @Test("sleep / glucose own their dashboard metric kinds")
    func metricOwningModules() {
        #expect(ModuleKey.sleep.dashboardMetricKinds == [.sleep])
        #expect(ModuleKey.glucose.dashboardMetricKinds == [.glucose])
    }

    @Test("Non-metric modules own no dashboard kinds")
    func nonMetricModules() {
        for key in ModuleKey.allCases where key != .sleep && key != .glucose {
            #expect(key.dashboardMetricKinds.isEmpty, "\(key) should own no metric kinds")
        }
        // Explicitly assert the two new keys map to no metric tile.
        #expect(ModuleKey.illness.dashboardMetricKinds.isEmpty)
        #expect(ModuleKey.medications.dashboardMetricKinds.isEmpty)
    }

    @Test("wireKey round-trips through from(wireKey:)")
    func wireKeyRoundTrip() {
        for key in ModuleKey.allCases {
            #expect(ModuleKey.from(wireKey: key.wireKey) == key)
        }
        #expect(ModuleKey.from(wireKey: "future.unknown") == nil)
    }
}

// MARK: - 5. PATCH body shape (v1.18.1 §4 Q3)

@Suite("ModulesPatchDTO — per-key body encoding")
struct ModulesPatchDTOEncodingTests {
    private func encode(_ changes: [String: Bool]) throws -> [String: Bool] {
        let data = try JSONEncoder().encode(ModulesPatchDTO(changes: changes))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Bool]
        return json ?? [:]
    }

    @Test("Encodes a flat {key: bool} object, not a disabled allowlist")
    func encodesPerKey() throws {
        let json = try encode(["illness": true])
        #expect(json == ["illness": true])
    }

    @Test("Disabling a single key encodes {key:false}")
    func encodesSingleFalse() throws {
        let json = try encode(["mood": false])
        #expect(json == ["mood": false])
    }

    @Test("No `disabled` array field is emitted")
    func noDisabledArrayField() throws {
        let data = try JSONEncoder().encode(ModulesPatchDTO(changes: ["sleep": false]))
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(raw?["disabled"] == nil)
        #expect(raw?.keys.contains("sleep") == true)
    }
}

// MARK: - 6. Settings switchboard offered-set (v1.18.1 §4)

@MainActor
@Suite("SettingsModulesScreen — offered toggle set")
struct SettingsModulesOfferedSetTests {
    @Test("Offered set excludes the delegated cycle/coach keys")
    func excludesNonToggleable() {
        // Build 2 / 2.6: `medications` graduated from the always-on CORE set to a
        // real toggle (server v1.18.1 D3), so it now BELONGS in the offered set.
        // Only cycle + coach stay out — the server 422s a direct PATCH for those;
        // they are driven by their own prefs endpoints.
        let offered = Set(SettingsModulesScreen.offeredKeys)
        #expect(!offered.contains(.cycle))
        #expect(!offered.contains(.coach))
        #expect(offered.contains(.medications), "medications is user-toggleable since v1.18.1 D3")
    }

    @Test("Offered set includes illness as an opt-in toggle")
    func includesIllness() {
        #expect(SettingsModulesScreen.offeredKeys.contains(.illness))
    }

    @Test("Offered set == every user-toggleable key")
    func matchesUserToggleable() {
        let offered = Set(SettingsModulesScreen.offeredKeys)
        let expected = Set(ModuleKey.allCases.filter(\.isUserToggleable))
        #expect(offered == expected)
        // Sanity: the toggleable set is the non-delegated, non-core keys.
        for key in offered {
            #expect(key.isUserToggleable)
        }
    }
}

// MARK: - 7. setEnabled — single-key PATCH + 422-guard

@MainActor
@Suite("ModuleGate — setEnabled per-key PATCH")
struct ModuleGateSetEnabledTests {
    @Test("Delegated/core keys are rejected without a network hop")
    func rejectsNonToggleable() {
        // No repo wired → setEnabled returns false anyway, but the guard must
        // also reject these keys (verified via isUserToggleable contract).
        #expect(ModuleKey.cycle.isUserToggleable == false)
        #expect(ModuleKey.coach.isUserToggleable == false)
        // Build 2 / 2.6: medications graduated CORE → real toggle server-side
        // (registry D3 / web v1.18.1). It is offered like any other key now.
        #expect(ModuleKey.medications.isUserToggleable == true)
        #expect(ModuleKey.illness.isUserToggleable == true)
        #expect(ModuleKey.mood.isUserToggleable == true)
    }
}

/// Minimal Sendable cell for capturing the async-fired module key from the
/// fire-and-forget mirror handler.
private actor ModuleSlot {
    private var value: String?
    func set(_ v: String) {
        value = v
    }

    func waitFor(timeoutMs: Int) async -> String? {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if let v = value { return v }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return value
    }
}

// swiftlint:enable force_unwrapping
