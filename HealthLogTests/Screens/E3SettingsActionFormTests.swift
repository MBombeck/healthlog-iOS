@testable import HealthLog
import Testing

/// The reset rows on the two customization pages became delete-ladder rows:
/// they ask before they act and never go by a full swipe.
@MainActor
@Suite("E3-E: Zurücksetzen fragt vorher")
struct E3SettingsActionFormTests {
    @Test("Startseite anpassen: Zurücksetzen fragt und läuft erst nach dem Ja")
    func dashboardResetAsks() async {
        var ran = false
        let action = DashboardCustomizationScreen.resetAction { ran = true }
        #expect(action.requiresConfirmation)
        #expect(!action.allowsFullSwipe)
        #expect(!ran)
        await action.run()
        #expect(ran)
    }

    @Test("Insights anpassen: Zurücksetzen fragt und läuft erst nach dem Ja")
    func insightsResetAsks() async {
        var ran = false
        let action = SettingsInsightsCustomizationScreen.resetAction { ran = true }
        #expect(action.requiresConfirmation)
        #expect(!action.allowsFullSwipe)
        #expect(!ran)
        await action.run()
        #expect(ran)
    }

    @Test("Zurücksetzen trägt sein eigenes Zeichen, nicht den Papierkorb")
    func resetKeepsItsSymbol() {
        #expect(DashboardCustomizationScreen.resetAction {}.symbol == "arrow.uturn.backward")
        #expect(SettingsInsightsCustomizationScreen.resetAction {}.symbol == "arrow.uturn.backward")
    }
}
