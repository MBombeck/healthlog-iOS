import Foundation
@testable import HealthLog
import Testing

/// v0.14 b146 — pins the `insights.metric.<rawvalue>.description` keys added
/// so the previously-blank metric pages (the IC additive kinds + bodyFat / steps
/// / vo2Max / walking-steadiness) render real copy. `InsightsMetricScreen`
/// self-suppresses the description slot when the key resolves back to itself
/// (the echo test), so a dropped key silently regresses the page to blank.
/// This suite is the regression anchor: every key MUST carry a non-empty value
/// in BOTH `en` and `de`, and the DE value MUST differ from the EN source.
///
/// **W-CLEANUP-MISC (v0.15):** `insights.metric.sixMinuteWalkTestDistance.description`
/// was dropped from this list and the catalog. `.sixMinuteWalk` carries a full
/// `insights.subPage.explainer.sixMinuteWalk{Title,Body}` pair, so
/// `descriptionText` resolves the explainer copy and returns before ever reaching
/// the legacy `insights.metric.<rawvalue>.description` fallback — the key was
/// unreachable (proven dead). The remaining keys stay pinned.
@Suite("v0.14 b146 — insights description keys present + EN/DE parity")
struct B146InsightsDescriptionKeysTests {
    static let keys: [String] = [
        "insights.metric.bodyFat.description",
        "insights.metric.steps.description",
        "insights.metric.vo2Max.description",
        "insights.metric.appleWalkingSteadiness.description",
        "insights.metric.fallCount.description",
        "insights.metric.stairAscentSpeed.description",
        "insights.metric.stairDescentSpeed.description",
        "insights.metric.breathingDisturbances.description",
        "insights.metric.cardioRecovery.description",
        "insights.metric.wristTemperature.description"
    ]

    @Test("Every key resolves to a non-empty EN + DE value that differs (no German leak, no echo)")
    func keysPresentAndTranslated() throws {
        let en = try Self.lprojBundle(language: "en")
        let de = try Self.lprojBundle(language: "de")
        for key in Self.keys {
            let enValue = en.localizedString(forKey: key, value: "MISSING", table: nil)
            let deValue = de.localizedString(forKey: key, value: "MISSING", table: nil)
            #expect(enValue != "MISSING", "Missing EN entry for key: \(key)")
            #expect(deValue != "MISSING", "Missing DE entry for key: \(key)")
            #expect(!enValue.isEmpty, "Empty EN value for key: \(key)")
            #expect(!deValue.isEmpty, "Empty DE value for key: \(key)")
            // Echo test the screen uses: a present key must NOT resolve to itself.
            #expect(enValue != key, "EN value echoes the key (slot would suppress): \(key)")
            #expect(deValue != key, "DE value echoes the key (slot would suppress): \(key)")
            #expect(enValue != deValue, "EN equals DE — German translation missing: \(key)")
        }
    }

    private static func lprojBundle(language: String) throws -> Bundle {
        guard let lprojPath = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: lprojPath) else
        {
            throw Failure.missingLproj(language)
        }
        return bundle
    }

    private enum Failure: Error { case missingLproj(String) }
}
