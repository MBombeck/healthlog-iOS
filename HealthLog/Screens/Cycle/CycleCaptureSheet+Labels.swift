import SwiftUI

/// Pure label/catalogue mappings for ``CycleCaptureSheet`` — split out of the
/// view file to keep the view body within `type_body_length` (PROJECT_GUIDE.md
/// file-length discipline). Every value is a `LocalizedStringKey` resolved from
/// `Localizable.xcstrings` (`cycle.*`); no hardcoded UI strings.
extension CycleCaptureSheet {
    // MARK: - Labels

    static func flowLabel(_ level: CycleFlowLevel) -> LocalizedStringKey {
        switch level {
        case .none: "cycle.flow.none"
        case .spotting: "cycle.flow.spotting"
        case .light: "cycle.flow.light"
        case .medium: "cycle.flow.medium"
        case .heavy: "cycle.flow.heavy"
        }
    }

    static func ovulationLabel(_ test: CycleOvulationTest) -> LocalizedStringKey {
        switch test {
        case .negative: "cycle.ovulation.negative"
        case .positiveLHSurge: "cycle.ovulation.positive"
        case .estrogenSurge: "cycle.ovulation.estrogen"
        case .indeterminate: "cycle.ovulation.indeterminate"
        }
    }

    static func mucusLabel(_ mucus: CycleCervicalMucus) -> LocalizedStringKey {
        switch mucus {
        case .dry: "cycle.mucus.dry"
        case .sticky: "cycle.mucus.sticky"
        case .creamy: "cycle.mucus.creamy"
        case .watery: "cycle.mucus.watery"
        case .eggWhite: "cycle.mucus.eggWhite"
        }
    }

    static func cervixPositionLabel(_ value: CycleCervixPosition) -> LocalizedStringKey {
        switch value {
        case .low: "cycle.cervix.position.low"
        case .high: "cycle.cervix.position.high"
        }
    }

    static func cervixFirmnessLabel(_ value: CycleCervixFirmness) -> LocalizedStringKey {
        switch value {
        case .firm: "cycle.cervix.firmness.firm"
        case .soft: "cycle.cervix.firmness.soft"
        }
    }

    static func cervixOpeningLabel(_ value: CycleCervixOpening) -> LocalizedStringKey {
        switch value {
        case .closed: "cycle.cervix.opening.closed"
        case .open: "cycle.cervix.opening.open"
        }
    }

    static func testResultLabel(_ value: CycleTestResult) -> LocalizedStringKey {
        switch value {
        case .negative: "cycle.capture.test.negative"
        case .positive: "cycle.capture.test.positive"
        case .indeterminate: "cycle.capture.test.indeterminate"
        }
    }

    static func contraceptiveLabel(_ value: CycleContraceptiveKind) -> LocalizedStringKey {
        switch value {
        case .none: "cycle.capture.contraceptive.none"
        case .unspecified: "cycle.capture.contraceptive.unspecified"
        case .implant: "cycle.capture.contraceptive.implant"
        case .injection: "cycle.capture.contraceptive.injection"
        case .iud: "cycle.capture.contraceptive.iud"
        case .intravaginalRing: "cycle.capture.contraceptive.ring"
        case .oral: "cycle.capture.contraceptive.oral"
        case .patch: "cycle.capture.contraceptive.patch"
        case .emergency: "cycle.capture.contraceptive.emergency"
        }
    }

    static func bbtFormatted(_ value: Double) -> String {
        String(format: String(localized: "cycle.capture.bbt.value"), value)
    }
}
