import Foundation
@testable import HealthLog
import Testing

/// The Open-Meteo credit used to reach the screen in English whatever the
/// interface language was.
@MainActor
@Suite("Interface language: the weather credit")
struct InterfaceLanguageCopyTests {
    @Test("the canonical Open-Meteo credit reads in the interface language")
    func canonicalCreditIsLocalized() {
        #expect(
            EnvironmentAttributionView.credit(for: EnvironmentOverviewDTO.defaultAttribution)
                == String(localized: "environment.attribution.credit")
        )
    }

    @Test("a credit the server words differently is shown as served")
    func otherCreditStaysVerbatim() {
        let served = "Weather data by Open-Meteo.com and DWD"
        #expect(EnvironmentAttributionView.credit(for: served) == served)
    }
}
