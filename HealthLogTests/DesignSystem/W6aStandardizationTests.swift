@testable import HealthLog
import SwiftUI
import Testing

/// W6a standardization-sweep invariants (STANDARDS §3, §4, §8).
///
/// These lock the decisions the standardization wave made so a later edit
/// can't silently re-fragment the card radius or
/// re-introduce a hardcoded German "J" into the EN-source range vocabulary.
///
/// The range-label assertions resolve against the explicit `en.lproj` /
/// `de.lproj` bundles (not the device locale) so they are deterministic on a
/// German-locale simulator — the catalog routing is the thing under test, and
/// the DE catalogue is *supposed* to render "J".
@Suite("W6a standardization")
struct W6aStandardizationTests {
    // MARK: - §3 ONE card radius

    @Test("Canonical card radius is 20 and the legacy tighter values are gone")
    func canonicalCardRadius() {
        // Every card routes through HLRadius.card.
        #expect(HLRadius.card == 20)
        // The semantic alias is what cards must use — not the raw `lg` (18) or
        // `sm` (10) the cards used to hard-code.
        #expect(HLRadius.lg == 18)
        #expect(HLRadius.sm == 10)
        #expect(HLRadius.card != HLRadius.lg)
        #expect(HLRadius.card != HLRadius.sm)
    }

    // MARK: - §8 ONE range vocabulary (single-letter Apple-Health set)

    @Test("range.label.year is EN \"Y\" / DE \"J\" via the catalog (W6-6)")
    func yearLabelRoutesThroughCatalog() throws {
        let en = try Self.lprojBundle(language: "en")
        let de = try Self.lprojBundle(language: "de")
        let enValue = en.localizedString(forKey: "range.label.year", value: "MISSING", table: nil)
        let deValue = de.localizedString(forKey: "range.label.year", value: "MISSING", table: nil)
        // EN source is the single-letter "Y", never the hardcoded German "J".
        #expect(enValue == "Y", "EN year label must be the Apple-Health single letter; got \(enValue)")
        // DE catalogue supplies "J" — proving the leak is now routed, not literal.
        #expect(deValue == "J", "DE year label must come from the catalogue as J; got \(deValue)")
    }

    @MainActor
    @Test("The static range segments are the single-letter T/W/M/6M set")
    func staticRangeSegmentsAreSingleLetter() {
        // The non-localized segments are literal single letters. (1.4 B4 — the
        // second store with this vocabulary, `TrendsOverlayStore`, is deleted.)
        #expect(ChartDetailStore.Range.day.label == "T")
        #expect(ChartDetailStore.Range.week.label == "W")
        #expect(ChartDetailStore.Range.month.label == "M")
        #expect(ChartDetailStore.Range.sixMonths.label == "6M")
    }

    // MARK: - Mood takes the one period set

    @Test("Mood period is the app's one period set, no wider vocabulary of its own")
    func moodUsesTheOnePeriodSet() {
        #expect(MoodPeriod.allCases == HLTimeRange.allCases)
        #expect(MoodPeriod.allCases.map(\.label) == HLTimeRange.allCases.map(\.label))
    }

    // MARK: - Helpers

    /// Resolves the compiled `<language>.lproj` bundle from the host app — the
    /// same table the running app consults. Mirrors `SourceFlipNoRawKeyTests`.
    private static func lprojBundle(language: String) throws -> Bundle {
        guard let lprojPath = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: lprojPath) else
        {
            throw W6aTestError.missingLproj(language: language)
        }
        return bundle
    }

    private enum W6aTestError: Error, CustomStringConvertible {
        case missingLproj(language: String)
        var description: String {
            switch self {
            case let .missingLproj(language): "missing \(language).lproj bundle"
            }
        }
    }
}
