import Foundation
@testable import HealthLog
import Testing

/// **REG (1.5) — public #18 (BernhardBuckel): Sync Diagnostics showed raw
/// type names ("HEART_RATE_VARIABILITY", "stats:…").**
///
/// Every type the server can name in a freshness row, taken from
/// `allCases` so a new case cannot slip past, is shown as a word: the metric's
/// own name where the app has one, otherwise a sentence-cased label, never the
/// wire key. The hand-picked strings stay in
/// `HKSyncDiagnosticsReadabilityTests` and `HKSyncDiagnosticsVocabularyTests`.
@Suite("REG public #18: every type in Sync Diagnostics has a name")
struct Regression_public_18 {
    @Test("every server measurement type reads as a word, not its wire key", arguments: ServerMeasurementType.allCases)
    func serverTypeIsNamed(_ type: ServerMeasurementType) {
        let label = HKSyncDiagnosticsVocabulary.freshnessType(type.rawValue)
        #expect(!label.isEmpty)
        #expect(label != type.rawValue, "\(type.rawValue) is shown raw")
        #expect(!label.contains("_"), "\(type.rawValue) is shown as \(label)")
    }

    @Test("a type the app has a metric for carries that metric's name", arguments: MetricKind.allCases)
    func metricKindKeyIsItsName(_ kind: MetricKind) {
        guard let key = kind.availabilitySummaryKey else { return }
        #expect(HKSyncDiagnosticsVocabulary.freshnessType(key) == kind.displayName)
        // The lookup ignores case and separators (`heart_rate`, `heart-rate`).
        #expect(HKSyncDiagnosticsVocabulary.freshnessType(key.lowercased()) == kind.displayName)
    }
}
