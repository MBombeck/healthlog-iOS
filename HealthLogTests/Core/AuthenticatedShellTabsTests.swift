@testable import HealthLog
import SnapshotTesting
import SwiftUI
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

    // MARK: - Sidebar sections

    private static let allOpen = Set(SidebarDestination.allCases)

    /// Regular width, every gate open: the sidebar with Dashboard,
    /// Medications and Insights (Log is the "+" of their pages), then
    /// "Tagebuch" with six rows (the timeline first) and "Befunde" with four,
    /// each titled like its More row, and More at the foot.
    @Test("Regular width: the sidebar with both sections and all ten rows")
    func regularContractSnapshot() {
        let layout = ShellLayout(sizeClass: .regular, enabledSections: Self.allOpen)
        assertSnapshot(of: AuthenticatedShell.tabContract(for: layout), as: .dump)
    }

    /// Compact width: the five-tab bar alone, no section.
    @Test("Compact width: the five bar tabs and no sidebar section")
    func compactContractSnapshot() {
        let layout = ShellLayout(sizeClass: .compact, enabledSections: Self.allOpen)
        assertSnapshot(of: AuthenticatedShell.tabContract(for: layout), as: .dump)
        #expect(AuthenticatedShell.sidebarGroups(for: layout).isEmpty)
        #expect(AuthenticatedShell.sidebarGroups(for: .initial).isEmpty)
    }

    @Test("Bar and sidebar tabs name base symbols; the system picks the variant")
    func baseSymbols() {
        let layout = ShellLayout(sizeClass: .regular, enabledSections: Self.allOpen)
        let symbols = AuthenticatedShell.tabDescriptors.map(\.systemImage)
            + AuthenticatedShell.sidebarGroups(for: layout).flatMap(\.items).map(\.systemImage)
        #expect(symbols.allSatisfy { !$0.hasSuffix(".fill") })
        #expect(AuthenticatedShell.baseSymbol("drop.fill") == "drop")
        #expect(AuthenticatedShell.baseSymbol("figure.run") == "figure.run")
    }

    @Test("Keyboard: Cmd-1, 2, 4, 5 pick the destination tabs; the Log slot is Cmd-N only")
    func keyboardSlots() {
        let slots = ShellKeyCommands.tabSlots
        #expect(slots.map(\.tab.id) == [.home, .meds, .insights, .more])
        #expect(slots.map(\.digit) == ["1", "2", "4", "5"])
    }

    @Test("A closed gate removes exactly its sidebar tab")
    func closedGateRemovesTab() {
        let layout = ShellLayout(sizeClass: .regular, enabledSections: Self.allOpen.subtracting([.labs, .cycle]))
        let ids = AuthenticatedShell.sidebarGroups(for: layout).flatMap(\.items).map(\.destination)
        #expect(ids == [
            .timeline, .measurements, .illness, .seizures, .mentalWellbeing, .workouts, .documents, .checkups, .medicalSources
        ])
    }

    @Test("Section headings and tab titles are catalog keys in every shipped language")
    func titlesAreLocalized() throws {
        let layout = ShellLayout(sizeClass: .regular, enabledSections: Self.allOpen)
        let groups = AuthenticatedShell.sidebarGroups(for: layout)
        let keys = groups.map(\.titleKey) + groups.flatMap(\.items).map(\.titleKey)
        #expect(keys.count == 13)
        for language in ["de", "en", "nl"] {
            let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: "\u{0}", table: nil)
                #expect(value != "\u{0}", "\(key) has no \(language) text")
            }
        }
    }

    @Test(
        "More lists a row unless it is a sidebar tab: regular hides it only with the gate open",
        arguments: SidebarDestination.allCases
    )
    func moreListsRowsWithoutSidebarTab(destination: SidebarDestination) {
        let open = Self.allOpen
        let closed = Self.allOpen.subtracting([destination])
        // Regular, gate open: the sidebar tab carries it, More does not.
        #expect(!MoreScreen.listsRow(for: destination, in: ShellLayout(sizeClass: .regular, enabledSections: open)))
        // Regular, gate closed: no sidebar tab; the row's own gate decides in More.
        #expect(MoreScreen.listsRow(for: destination, in: ShellLayout(sizeClass: .regular, enabledSections: closed)))
        // Compact, gate open or closed: every row as today.
        #expect(MoreScreen.listsRow(for: destination, in: ShellLayout(sizeClass: .compact, enabledSections: open)))
        #expect(MoreScreen.listsRow(for: destination, in: ShellLayout(sizeClass: .compact, enabledSections: closed)))
        #expect(MoreScreen.listsRow(for: destination, in: .initial))
    }
}
