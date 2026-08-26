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

    @Test("Nur die drei Vertragswerte existieren — ein vierter wäre ein 422")
    func wireVocabularyIsClosed() {
        #expect(SyncTrigger.allCases.map(\.rawValue).sorted() == ["background", "foreground", "push"])
    }
}
