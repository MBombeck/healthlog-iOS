@testable import HealthLog
import SnapshotTesting
import Testing

/// Schuetzt die Tab-Bar-Konfiguration vor unbeabsichtigten Änderungen.
///
/// Image-Snapshots des nativen iOS-18-`TabView` sind über Simulator-/SDK-Versionen
/// hinweg fragil (Antialiasing, System-Fonts). Wir snapshotten stattdessen den
/// strukturellen Tab-Kontrakt (Reihenfolge, Identifier, Titel-Key, SF-Symbol,
/// Action-Flag) — das ist 1:1 das was sich aendert wenn jemand die TabBar refaktoriert.
@MainActor
@Suite("AuthenticatedShell tab descriptors")
struct AuthenticatedShellTabsTests {
    @Test("TabBar-Reihenfolge + Symbole sind stabil")
    func tabDescriptorsSnapshot() {
        let descriptors = AuthenticatedShell.tabDescriptors.map { descriptor in
            [
                "id": descriptor.id.rawValue,
                "title": descriptor.titleKey,
                "symbol": descriptor.systemImage,
                "action": descriptor.isAction ? "yes" : "no"
            ]
        }

        assertSnapshot(of: descriptors, as: .dump)
    }

    @Test("Genau 5 Tab-Slots — 4 Ziele + 1 Action")
    func tabSlotCount() {
        let total = AuthenticatedShell.tabDescriptors.count
        let actions = AuthenticatedShell.tabDescriptors.filter(\.isAction).count
        #expect(total == 5)
        #expect(actions == 1)
        #expect(total - actions == 4)
    }

    @Test("Action-Slot ist 'measure'")
    func measureIsTheOnlyAction() {
        let actions = AuthenticatedShell.tabDescriptors.filter(\.isAction)
        #expect(actions.map(\.id) == [.measure])
    }

    /// v0.5.2-A8 (2026-05-17): operator override — Erfassen sits at the
    /// centre slot of a five-tab bar (index 2 of 0…4). The previous A4
    /// configuration left the action slot at index 1 which violated the
    /// "reachable-thumb sacred middle" intent. This guard prevents a
    /// future refactor from silently shifting the action slot off centre.
    @Test("Erfassen sits at the centre slot (index 2 of 5)")
    func measureIsAtCentreSlot() {
        let descriptors = AuthenticatedShell.tabDescriptors
        let measureIndex = descriptors.firstIndex { $0.id == .measure }
        #expect(measureIndex == 2, "Erfassen must sit at the middle slot — got index \(measureIndex ?? -1)")
        #expect(descriptors.count == 5, "centre-slot invariant assumes a 5-slot bar")
    }
}
