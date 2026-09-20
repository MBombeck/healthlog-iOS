import Foundation
@testable import HealthLog
import Testing

/// MDR-disclaimer copy locked-test for the drug-level chart.
///
/// **Regulatory weight:** the caption under the curve is the disclaimer that
/// survives, and the y-axis must stay unit-less. D-12-05-A removed the opt-in
/// that used to guard the curve — the acknowledgment dialog, its
/// `RESEARCH_MODE_DISCLAIMER_VERSION` stamp and the three cases that asserted
/// the gate's copy went with it, exactly as the server dropped its own dialog
/// and kept `medications.researchMode.chart.estimateNote`. What is left here is
/// the part with regulatory weight, and it is now unconditional.
///
/// **1.0.3 (audit row 27):** these cases used to pass German literals to
/// `String(localized:)` that are not catalog keys at all. The lookup returned
/// the key back unchanged, so `contains("EMA")` was asserting against the test's
/// own argument and the shipped **English** caption was locked by nothing. The
/// assertions now go through the compiled `de.lproj` / `en.lproj` tables with
/// the real catalog keys — the English source strings
/// `MDRGatedDrugLevelSection` actually renders — so both locales are covered.
@Suite("MDR disclaimer copy")
struct MDRDisclaimerCopyTests {
    /// The catalog key = the English source string rendered at
    /// `MDRGatedDrugLevelSection.swift:116`.
    private static let captionKey =
        "Educational estimate from EMA-published population pharmacokinetics. Not a measurement."
    /// Rendered as the y-axis caption and the chart's audio-graph axis title.
    private static let yAxisKey = "Estimated level (relative)"

    @Test("Chart caption names EMA and denies measurement in both locales")
    func chartCaptionLocked() throws {
        for language in ["en", "de"] {
            let bundle = try Self.lprojBundle(language: language)
            let caption = bundle.localizedString(forKey: Self.captionKey, value: "MISSING", table: nil)
            #expect(caption != "MISSING", "\(language): caption key missing from the catalog")
            #expect(caption.contains("EMA"), "\(language): EMA citation must be present")
            let denial = language == "en" ? "Not a measurement" : "Keine Messung"
            #expect(caption.contains(denial), "\(language): non-measurement disclaimer required")
        }
    }

    @Test("Y-axis caption stays unit-less in both locales")
    func yAxisCaptionIsUnitless() throws {
        // Negative assertions: the caption MUST NOT mention any unit. Drift
        // here would breach the MDR boundary by inviting users to read off
        // a numeric concentration.
        let forbiddenUnits = ["ng/mL", "ng/ml", "µg/L", "ug/L", "mol/L", "mg/L"]
        for language in ["en", "de"] {
            let bundle = try Self.lprojBundle(language: language)
            let caption = bundle.localizedString(forKey: Self.yAxisKey, value: "MISSING", table: nil)
            #expect(caption != "MISSING", "\(language): y-axis key missing from the catalog")
            let relative = language == "en" ? "relative" : "relativ"
            #expect(caption.localizedCaseInsensitiveContains(relative))
            for unit in forbiddenUnits {
                #expect(!caption.contains(unit), "\(language): y-axis caption must stay unit-less; contains \(unit)")
            }
        }
    }

    // MARK: - Helpers

    /// Resolves the bundle that ships compiled `Localizable.strings` for a
    /// language code. The test target's `BUNDLE_LOADER` makes `Bundle.main` the
    /// host app, which ships `de.lproj/` + `en.lproj/`.
    private static func lprojBundle(language: String) throws -> Bundle {
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else
        {
            throw MDRCopyTestError.missingLproj(language: language)
        }
        return bundle
    }

    private enum MDRCopyTestError: Error, CustomStringConvertible {
        case missingLproj(language: String)

        var description: String {
            switch self {
            case let .missingLproj(language):
                "Missing \(language).lproj in host-app bundle — catalog compile broke?"
            }
        }
    }
}
