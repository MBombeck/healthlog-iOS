import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// **CU-21 (1)** — der `syncTrigger`-Kontext selbst. Reine Zustandslogik, kein
/// Netz: die Wire-Seite pinnt `SyncTriggerBatchBodyTests`.
@Suite("SyncTriggerContext — Auslöser-Fenster")
struct SyncTriggerContextTests {
    @Test("Ohne offenes Fenster ist der Auslöser `foreground` (die Restmenge, keine Annahme)")
    func defaultIsForeground() {
        let context = SyncTriggerContext()
        #expect(context.current == .foreground)
    }

    @Test("Ein offenes Fenster gewinnt; nach dem Schließen fällt es auf `foreground` zurück")
    func scopeWinsAndUnwinds() {
        let context = SyncTriggerContext()
        context.begin(.background)
        #expect(context.current == .background)
        context.end(.background)
        #expect(context.current == .foreground)
        #expect(context.openScopeCount == 0)
    }

    @Test("Verschachtelung: der innerste (spezifischere) Auslöser gewinnt")
    func innermostScopeWins() {
        let context = SyncTriggerContext()
        context.begin(.background)
        context.begin(.push)
        #expect(context.current == .push)
        context.end(.push)
        // Das äußere BGTask-Fenster steht weiter — ein Push-Wake darf es nicht
        // mit abräumen.
        #expect(context.current == .background)
        context.end(.background)
        #expect(context.current == .foreground)
    }

    @Test("`end` räumt gezielt das eigene Fenster ab, nicht blind das letzte")
    func endRemovesOwnScope() {
        let context = SyncTriggerContext()
        context.begin(.background)
        context.begin(.push)
        context.end(.background)
        #expect(context.current == .push)
        #expect(context.openScopeCount == 1)
    }

    @Test("`withTrigger` schließt das Fenster auch, wenn der Body wirft")
    func withTriggerClosesOnThrow() async {
        struct Boom: Error {}
        let context = SyncTriggerContext()
        await #expect(throws: Boom.self) {
            try await context.withTrigger(.background) {
                #expect(context.current == .background)
                throw Boom()
            }
        }
        #expect(context.current == .foreground)
        #expect(context.openScopeCount == 0)
    }

    /// V1 (1.2) — `manual` kam mit Server v1.42.0 (#123). Der Vertrag bleibt
    /// geschlossen: genau die vier Wörter, die die Batch-Route kennt.
    @Test("Genau die vier Vertragswerte existieren (manual seit Server v1.42)")
    func wireVocabularyIsClosed() {
        #expect(SyncTrigger.allCases.map(\.rawValue).sorted() == ["background", "foreground", "manual", "push"])
    }

    @Test("V1: `manual` geht nur an einen Server ≥ 1.42 auf den Draht, sonst als `foreground`")
    func manualWireValueFollowsTheServer() async {
        let context = SyncTriggerContext()
        await context.withTrigger(.manual) {
            #expect(context.current == .manual)
            #expect(context.wireValue == .foreground)
            context.noteServerVersion(ServerVersionInfo(version: "1.42.0"))
            #expect(context.wireValue == .manual)
            context.noteServerVersion(ServerVersionInfo(version: "1.41.9"))
            #expect(context.wireValue == .foreground)
            context.noteServerVersion(ServerVersionInfo(version: "1.42.1"))
            context.forgetServer()
            #expect(context.wireValue == .foreground)
        }
    }

    @Test("V1: die Server-Fähigkeit überlebt einen Neustart über die Defaults")
    func serverCapabilityPersists() throws {
        let defaults = try #require(UserDefaults(suiteName: "test.v1.trigger.\(UUID().uuidString)"))
        SyncTriggerContext(defaults: defaults).noteServerVersion(ServerVersionInfo(version: "1.42.0"))
        let relaunched = SyncTriggerContext(defaults: defaults)
        relaunched.begin(.manual)
        #expect(relaunched.wireValue == .manual)
        relaunched.end(.manual)
    }

    /// INT-N (1.2) — V1 (`manual`) und V4 (RMSSD) lesen dieselbe letzte
    /// Server-Version. Die App schreibt sie an genau einer Stelle
    /// (`HealthKitServerTypeGate.record`) und vergisst sie an genau einer.
    @Test("INT-N: `manual` folgt der einen gemerkten Server-Version, die auch RMSSD freigibt")
    func manualFollowsTheSharedServerVersion() throws {
        let defaults = try #require(UserDefaults(suiteName: "test.intn.trigger.\(UUID().uuidString)"))
        let context = SyncTriggerContext(defaults: defaults)
        context.begin(.manual)
        defer { context.end(.manual) }
        #expect(context.wireValue == .foreground)

        HealthKitServerTypeGate.record(ServerVersionInfo(version: "1.42.0"), defaults: defaults)
        #expect(context.wireValue == .manual)
        #expect(HealthKitServerTypeGate.serverAccepts(HeartRateVariabilityRMSSD.identifier, defaults: defaults))

        HealthKitServerTypeGate.record(ServerVersionInfo(version: "1.41.2"), defaults: defaults)
        #expect(context.wireValue == .foreground)

        context.noteServerVersion(ServerVersionInfo(version: "1.42.0"))
        #expect(HealthKitServerTypeGate.serverAccepts(HeartRateVariabilityRMSSD.identifier, defaults: defaults))

        HealthKitServerTypeGate.forget(defaults: defaults)
        #expect(context.wireValue == .foreground)
        #expect(!HealthKitServerTypeGate.serverAccepts(HeartRateVariabilityRMSSD.identifier, defaults: defaults))
    }

    @Test("V1: ohne Fenster entscheidet der gemeldete App-Zustand")
    func fallbackFollowsTheApplicationState() {
        let context = SyncTriggerContext()
        #expect(context.current == .foreground)
        context.noteApplicationState(backgrounded: true)
        #expect(context.current == .background)
        context.begin(.push)
        #expect(context.current == .push)
        context.end(.push)
        context.noteApplicationState(backgrounded: false)
        #expect(context.current == .foreground)
    }

    @Test("V1: die Task-Bindung folgt der Arbeit in eine Task, auch nach dem Fenster")
    func bindingTravelsIntoSpawnedWork() async {
        let context = SyncTriggerContext()
        let late = await context.withTrigger(.background) {
            Task { () -> SyncTrigger in
                await Task.yield()
                return context.current
            }
        }
        // Das Fenster ist zu; ohne Bindung wäre die Antwort `foreground`.
        #expect(context.openScopeCount == 0)
        #expect(await late.value == .background)
        #expect(context.current == .foreground)
    }

    @Test("V1: eine Bindung färbt keine gleichzeitige, fremde Arbeit ein")
    func bindingDoesNotLeakIntoOtherTasks() async {
        let context = SyncTriggerContext()
        let gate = AsyncStream<Void>.makeStream()
        let bound = Task {
            await context.bind(.background) {
                for await _ in gate.stream {
                    break
                }
                return context.current
            }
        }
        await Task.yield()
        #expect(context.current == .foreground)
        gate.continuation.yield()
        #expect(await bound.value == .background)
    }

    @Test("V1: zwei Kontexte teilen keine Bindung")
    func bindingsArePerContext() async {
        let first = SyncTriggerContext()
        let second = SyncTriggerContext()
        await first.bind(.push) {
            #expect(first.current == .push)
            #expect(second.current == .foreground)
        }
    }
}
