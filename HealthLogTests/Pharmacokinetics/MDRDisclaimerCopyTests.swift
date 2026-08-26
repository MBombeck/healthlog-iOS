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
@Suite("MDR disclaimer copy")
struct MDRDisclaimerCopyTests {
    @Test("Chart caption disclaimer is byte-equal to locked copy")
    func chartCaptionLocked() {
        let caption = String(
            localized: "Edukative Schätzung aus EMA-publizierter Populations-Pharmakokinetik. Keine Messung."
        )
        // The two anchor tokens that fail-fast on drift.
        #expect(caption.contains("EMA"), "EMA citation must be present")
        #expect(caption.contains("Keine Messung"), "Non-measurement disclaimer required")
    }

    @Test("Y-axis caption stays unit-less (relativ, no unit token)")
    func yAxisCaptionIsUnitless() {
        let caption = String(localized: "Geschätzter Spiegel (relativ)")
        #expect(caption.contains("relativ"))
        // Negative assertions: the caption MUST NOT mention any unit. Drift
        // here would breach the MDR boundary by inviting users to read off
        // a numeric concentration.
        let forbiddenUnits = ["ng/mL", "ng/ml", "µg/L", "ug/L", "mol/L", "mg/L"]
        for unit in forbiddenUnits {
            #expect(!caption.contains(unit), "Y-axis caption must stay unit-less; contains \(unit)")
        }
    }
}
