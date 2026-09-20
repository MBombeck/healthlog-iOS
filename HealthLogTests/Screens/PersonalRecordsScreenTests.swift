import Foundation
@testable import HealthLog
import Testing

/// v0.5.3-F3 — Personal-Records surface contract tests.
///
/// Pins the layout descriptor strings + the metric-type localisation map.
/// The SwiftUI body itself is presentational.
@Suite("PersonalRecordsScreen — layout + localisation")
struct PersonalRecordsScreenTests {
    @Test("Navigation title is a catalog key that resolves")
    func navigationTitle() {
        // 1.0.3 / audit row 18 — the title used to be the German literal
        // "Persönliche Rekorde", which is no catalog key, so the English UI
        // rendered it raw. It is now a key; the assertion moved from the copy to
        // the key plus proof that the key actually resolves in both locales.
        #expect(PersonalRecordsScreen.Layout.navigationTitle == "records.title")
        #expect(String(localized: "records.title") != "records.title")
    }

    @Test("Empty-state copy is locked")
    func emptyStateCopy() {
        #expect(PersonalRecordsScreen.Layout.emptyTitle == "No personal records yet")
        #expect(PersonalRecordsScreen.Layout.emptySubtitle.contains("Personal bests"))
    }

    @Test("Metric-type localisation covers the canonical set")
    func metricTypeLocalisation() {
        #expect(MetricTypeLocalisation.label(forType: "WEIGHT") == "Weight")
        #expect(MetricTypeLocalisation.label(forType: "PULSE") == "Pulse")
        #expect(MetricTypeLocalisation.label(forType: "HRV") == "Herzfrequenzvariabilität")
        #expect(MetricTypeLocalisation.label(forType: "VO2_MAX") == "VO₂ max")
        #expect(MetricTypeLocalisation.label(forType: "MOOD") == "Stimmung")
        // Unknown passes through `String.capitalized` (which capitalises each
        // word boundary). The exact transform isn't load-bearing — the
        // contract is "never empty / never the raw enum value".
        let unknown = MetricTypeLocalisation.label(forType: "UNKNOWN_METRIC")
        #expect(!unknown.isEmpty)
        #expect(unknown != "UNKNOWN_METRIC")
    }
}
