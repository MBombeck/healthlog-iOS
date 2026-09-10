import Foundation
@testable import HealthLog
import Testing

// Audit A-7 (2026-09-10) — a module that is off says why.
//
// Locks the four contract surfaces the `moduleAccess` map (server v1.38.15)
// adds beside the unchanged boolean `modules` map:
//
// 1. **Decode** — all four server states, an unknown future token (tolerant,
//    the map survives whole) and an absent map (older server → `nil`).
// 2. **Invariant** — `modules[key] == (moduleAccess[key] == "enabled")`, plus
//    the disagreement arm: the boolean wins and no reason is shown.
// 3. **Reason** — `ModuleGate.offReason(_:)` per state, and `nil` where there
//    is nothing to explain (enabled / no map / key absent).
// 4. **Switchboard** — a `not_granted` row is non-interactive and carries the
//    reason; a `disabled` row keeps today's behaviour.

// MARK: - 1. Decode

@Suite("AuthMeModules — moduleAccess decode (A-7)")
struct ModuleAccessDecodeTests {
    @Test("All four server states decode onto their cases")
    func decodesEveryServerState() throws {
        let data = Data(#"""
        {"modules":{"labs":true,"illness":false,"nutrients":false,"environment":false},
         "moduleAccess":{"labs":"enabled","illness":"disabled",
                         "nutrients":"not_granted","environment":"unavailable"}}
        """#.utf8)
        let decoded = try JSONDecoder().decode(AuthMeModules.self, from: data)
        #expect(decoded.moduleAccess?["labs"] == .enabled)
        #expect(decoded.moduleAccess?["illness"] == .disabled)
        #expect(decoded.moduleAccess?["nutrients"] == .notGranted)
        #expect(decoded.moduleAccess?["environment"] == .unavailable)
    }

    @Test("An unknown future token decodes onto .unknown — the map survives whole")
    func unknownTokenKeepsTheMap() throws {
        let data = Data(#"""
        {"modules":{"labs":true,"mcp":false},
         "moduleAccess":{"labs":"enabled","mcp":"quarantined_by_operator"}}
        """#.utf8)
        let decoded = try JSONDecoder().decode(AuthMeModules.self, from: data)
        let access = try #require(decoded.moduleAccess)
        #expect(access.count == 2, "one unknown value must not drop the whole map")
        #expect(access["mcp"] == .unknown)
        #expect(access["labs"] == .enabled)
    }

    @Test("Absent moduleAccess (server < 1.38.15) → nil, modules unaffected")
    func absentMapDecodesNil() throws {
        let data = Data(#"{"modules":{"labs":false}}"#.utf8)
        let decoded = try JSONDecoder().decode(AuthMeModules.self, from: data)
        #expect(decoded.moduleAccess == nil)
        #expect(decoded.modules?["labs"] == false)
    }

    @Test("Empty moduleAccess decodes to an empty map, not nil")
    func emptyMapDecodes() throws {
        let data = Data(#"{"modules":{},"moduleAccess":{}}"#.utf8)
        let decoded = try JSONDecoder().decode(AuthMeModules.self, from: data)
        #expect(decoded.moduleAccess == [:])
    }

    @Test(".unknown is decode-only — encoding it throws")
    func unknownNeverGoesOutOnTheWire() {
        #expect(throws: (any Error).self) {
            try JSONEncoder().encode([ModuleAccessState.unknown])
        }
        #expect(ModuleAccessState.serverCases.contains(.unknown) == false)
    }
}

// MARK: - 2. Invariant

@MainActor
@Suite("ModuleGate — the modules/moduleAccess invariant (A-7)")
struct ModuleAccessInvariantTests {
    @Test("modules[key] == (moduleAccess[key] == \"enabled\") for every state")
    func invariantHolds() throws {
        let data = Data(#"""
        {"modules":{"labs":true,"illness":false,"nutrients":false,"environment":false,"mcp":false},
         "moduleAccess":{"labs":"enabled","illness":"disabled","nutrients":"not_granted",
                         "environment":"unavailable","mcp":"something_new"}}
        """#.utf8)
        let decoded = try JSONDecoder().decode(AuthMeModules.self, from: data)
        let modules = try #require(decoded.modules)
        let access = try #require(decoded.moduleAccess)
        for (key, state) in access {
            #expect(modules[key] == state.impliesEnabled, "\(key): boolean and access state must agree")
        }
        let gate = ModuleGate(modules: modules, moduleAccess: access)
        for key in ModuleKey.allCases where access[key.wireKey] != nil {
            #expect(gate.isEnabled(key) == (gate.accessState(key) == .enabled))
        }
    }

    @Test("Disagreement: the boolean wins, no reason is shown, nothing crashes")
    func disagreementFallsBackToTheBoolean() {
        // Server says the module is ON but the access map says it is off.
        let onButNotGranted = ModuleGate(modules: ["labs": true], moduleAccess: ["labs": .notGranted])
        #expect(onButNotGranted.isEnabled(.labs) == true, "the boolean is the half every gate obeys")
        #expect(onButNotGranted.offReason(.labs) == nil, "a wrong explanation is worse than none")
        // …and the mirror case: off, but the map claims enabled.
        let offButEnabled = ModuleGate(modules: ["labs": false], moduleAccess: ["labs": .enabled])
        #expect(offButEnabled.isEnabled(.labs) == false)
        #expect(offButEnabled.offReason(.labs) == nil)
    }

    @Test("isEnabled semantics are untouched by the access map")
    func isEnabledUnchanged() {
        let gate = ModuleGate(modules: nil, moduleAccess: ["labs": .unavailable])
        // No boolean map → all on, exactly as before A-7.
        for key in ModuleKey.allCases {
            #expect(gate.isEnabled(key) == true)
        }
    }
}

// MARK: - 3. Reason

@MainActor
@Suite("ModuleGate — offReason (A-7)")
struct ModuleOffReasonTests {
    @Test("No access map (older server) → no reason, exactly today's behaviour")
    func absentMapHasNoReason() {
        let gate = ModuleGate(modules: ["labs": false])
        #expect(gate.accessState(.labs) == nil)
        #expect(gate.offReason(.labs) == nil)
    }

    @Test("Key absent from the access map → no reason")
    func absentKeyHasNoReason() {
        let gate = ModuleGate(modules: ["labs": false], moduleAccess: ["mood": .enabled])
        #expect(gate.accessState(.labs) == nil)
        #expect(gate.offReason(.labs) == nil)
    }

    @Test("enabled → no reason (there is nothing to explain)")
    func enabledHasNoReason() {
        let gate = ModuleGate(modules: ["labs": true], moduleAccess: ["labs": .enabled])
        #expect(gate.offReason(.labs) == nil)
    }

    @Test("Every off-state resolves a distinct, localized sentence")
    func offStatesResolveCopy() throws {
        var seen: Set<String> = []
        for state in [ModuleAccessState.disabled, .notGranted, .unavailable, .unknown] {
            let gate = ModuleGate(modules: ["labs": false], moduleAccess: ["labs": state])
            let reason = try #require(gate.offReason(.labs), "\(state) must explain itself")
            #expect(reason.isEmpty == false)
            let key = try #require(state.offReasonKey)
            #expect(reason != key, "\(state): the catalogue lookup must resolve, not fall through to the key")
            #expect(seen.insert(reason).inserted, "\(state): each state needs its own sentence")
        }
    }

    @Test("Only the person's own switch stays offered")
    func offersSwitchPerState() {
        #expect(ModuleAccessState.enabled.offersSwitch == true)
        #expect(ModuleAccessState.disabled.offersSwitch == true)
        #expect(ModuleAccessState.notGranted.offersSwitch == false)
        #expect(ModuleAccessState.unavailable.offersSwitch == false)
        #expect(ModuleAccessState.unknown.offersSwitch == false)
    }

    @Test("clearOnLogout drops the access map with the booleans")
    func logoutClearsAccess() {
        let gate = ModuleGate(modules: ["labs": false], moduleAccess: ["labs": .unavailable])
        gate.clearOnLogout()
        #expect(gate.accessState(.labs) == nil)
        #expect(gate.offReason(.labs) == nil)
        #expect(gate.isEnabled(.labs) == true)
    }

    @Test("A 403 mirror drops the stale reason rather than inventing one")
    func mirrorDropsStaleReason() {
        let gate = ModuleGate(modules: ["labs": true], moduleAccess: ["labs": .enabled])
        gate.applyDisabled(wireKey: ModuleKey.labs.wireKey)
        #expect(gate.isEnabled(.labs) == false)
        #expect(gate.accessState(.labs) == nil, "the old 'enabled' must not survive the flip")
        #expect(gate.offReason(.labs) == nil)
    }

    @Test("A local toggle mirrors the person's own switch into the access map")
    func optimisticToggleMirrorsAccess() {
        let gate = ModuleGate(modules: ["labs": true], moduleAccess: ["labs": .enabled])
        gate.applyModuleOptimistic(wireKey: ModuleKey.labs.wireKey, enabled: false)
        #expect(gate.accessState(.labs) == .disabled)
        gate.applyModuleOptimistic(wireKey: ModuleKey.labs.wireKey, enabled: true)
        #expect(gate.accessState(.labs) == .enabled)
    }
}

// MARK: - 4. Switchboard

@Suite("SettingsModulesScreen — row presentation (A-7)")
struct SettingsModulesRowPresentationTests {
    @Test("A not_granted row is non-interactive and carries the reason")
    func notGrantedRowIsLocked() throws {
        let row = SettingsModulesScreen.rowPresentation(for: .notGranted)
        #expect(row.isSwitchOffered == false)
        #expect(row.reasonKey == ModuleAccessState.notGranted.offReasonKey)
        #expect(try #require(row.reasonKey).isEmpty == false)
    }

    @Test("unavailable and unknown rows are locked too")
    func otherForeignStatesAreLocked() {
        for state in [ModuleAccessState.unavailable, .unknown] {
            let row = SettingsModulesScreen.rowPresentation(for: state)
            #expect(row.isSwitchOffered == false, "\(state) is not the viewer's switch")
            #expect(row.reasonKey != nil, "\(state) must say why")
        }
    }

    @Test("disabled keeps today's behaviour: interactive, no footnote")
    func disabledRowUnchanged() {
        let row = SettingsModulesScreen.rowPresentation(for: .disabled)
        #expect(row.isSwitchOffered == true)
        #expect(row.reasonKey == nil, "the module subtitle stays; the row is simply off")
    }

    @Test("enabled and an absent map both keep today's row")
    func enabledAndAbsentRowsUnchanged() {
        for state in [ModuleAccessState.enabled, nil] {
            let row = SettingsModulesScreen.rowPresentation(for: state)
            #expect(row.isSwitchOffered == true)
            #expect(row.reasonKey == nil)
        }
    }
}
