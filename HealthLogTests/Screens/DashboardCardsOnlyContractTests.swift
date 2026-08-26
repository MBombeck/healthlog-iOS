import Foundation
@testable import HealthLog
import Testing

@Suite("Dashboard ships one canonical cards presentation")
struct DashboardCardsOnlyContractTests {
    @Test("Cards is the only selectable dashboard presentation")
    func cardsIsOnlyPresentation() {
        #expect(DashboardLayout.allCases == [.cards])
        #expect(DashboardLayout(rawValue: "hero") == nil)
        #expect(DashboardLayout(rawValue: "list") == nil)
    }

    @Test("Dashboard composition has no parallel hero or list renderer")
    func compositionIsCardsOnly() throws {
        let source = try read("HealthLog/Screens/Dashboard/Sub/DashboardSlots.swift")
        #expect(!source.contains("switch settings.dashboardLayout"))
        #expect(!source.contains("HeroLayout("))
        #expect(!source.contains("ListLayout("))
        #expect(source.contains("MetricsGrid("))
        #expect(source.contains("ComplianceRingCard("))
    }

    @Test("Appearance removes the meaningless one-choice layout picker")
    func appearanceHasNoLayoutPicker() throws {
        let source = try read("HealthLog/Screens/Settings/Sub/SettingsDashboardScreen.swift")
        #expect(!source.contains("settings.dashboard.layoutPicker"))
        #expect(!source.contains("ForEach(DashboardLayout.allCases)"))
        #expect(source.contains("settings.dashboard.appearancePicker"))
    }

    @Test("Retired dashboard renderer files are absent")
    func retiredRenderersAreAbsent() {
        let root = repositoryRoot()
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("HealthLog/Screens/Dashboard/HeroLayout.swift").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("HealthLog/Screens/Dashboard/ListLayout.swift").path
        ))
    }

    private func read(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func repositoryRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent() // Screens
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // repository root
            .standardizedFileURL
    }
}
