import Foundation
@testable import HealthLog
import Testing

/// v0.6.1.10 Y9-D2/D3 — regression locks for the
/// `InsightsTileCatalogue` preferences layer and the persistence
/// contract that backs the `SettingsInsightsCustomizationScreen`
/// Toggle rows.
@Suite("InsightsTileCatalogue + enabled-set persistence")
struct InsightsTileCatalogueTests {
    // MARK: - Defaults

    @Test("Default-enabled set matches the seven Y3-shipped tiles in order")
    func defaultEnabledMatchesY3Set() {
        // Pinning the exact list keeps a future wave from silently
        // shrinking the Y3 default rhythm. Order is contract too — the
        // customization screen renders defaults first in this order.
        #expect(InsightsTileCatalogue.defaultEnabled == [
            "WEIGHT",
            "PULSE",
            "RESTING_HR",
            "MOOD_SCORE",
            "MOOD_STABILITY",
            "ACTIVITY_STEPS",
            "MEDICATION_COMPLIANCE"
        ])
    }

    @Test("AppStorage key never renames")
    func storageKeyStable() {
        // Renaming the key would silently wipe operator preferences on
        // upgrade. Pin it.
        #expect(InsightsTileCatalogue.enabledTilesStorageKey == "hl.insights.enabledTiles")
    }

    // MARK: - Decode

    @Test("Empty persisted string maps to the default-enabled set (fresh install)")
    func emptyStringFallsBackToDefaults() {
        let set = InsightsTileCatalogue.decodeEnabled("")
        #expect(set == Set(InsightsTileCatalogue.defaultEnabled))
    }

    @Test("Empty-set sentinel maps to an empty set (operator opted out of every tile)")
    func emptySetSentinelRespected() {
        let set = InsightsTileCatalogue.decodeEnabled("__none__")
        #expect(set.isEmpty)
    }

    @Test("Comma-joined string decodes back to the operator's pick")
    func commaJoinedRoundTrips() {
        let raw = "WEIGHT,PULSE,SLEEP_DURATION"
        let set = InsightsTileCatalogue.decodeEnabled(raw)
        #expect(set == ["WEIGHT", "PULSE", "SLEEP_DURATION"])
    }

    // MARK: - Encode

    @Test("Encoding an empty set produces the sentinel, not an empty string")
    func encodingEmptySetUsesSentinel() {
        let encoded = InsightsTileCatalogue.encodeEnabled([])
        #expect(encoded == "__none__")
        // Round-trip — sentinel decodes back to empty.
        #expect(InsightsTileCatalogue.decodeEnabled(encoded).isEmpty)
    }

    @Test("Encoding produces a stable alphabetical join across renders")
    func encodingIsStableAlphabetical() {
        let a = InsightsTileCatalogue.encodeEnabled(["PULSE", "WEIGHT", "ACTIVITY_STEPS"])
        let b = InsightsTileCatalogue.encodeEnabled(["WEIGHT", "ACTIVITY_STEPS", "PULSE"])
        #expect(a == b)
        #expect(a == "ACTIVITY_STEPS,PULSE,WEIGHT")
    }

    @Test("Round-trip preserves operator pick exactly")
    func roundTripPreservesPick() {
        let pick: Set = ["WEIGHT", "MEDICATION_COMPLIANCE", "BODY_FAT"]
        let encoded = InsightsTileCatalogue.encodeEnabled(pick)
        let decoded = InsightsTileCatalogue.decodeEnabled(encoded)
        #expect(decoded == pick)
    }
}
