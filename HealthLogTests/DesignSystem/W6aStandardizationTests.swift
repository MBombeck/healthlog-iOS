@testable import HealthLog
import SwiftUI
import Testing

/// W6a standardization-sweep invariants (STANDARDS §3, §4, §8).
///
/// These lock the decisions the standardization wave made so a later edit
/// can't silently re-fragment the card radius, drop the `cardInset` token, or
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
        // HLCard + HLSettingsCard both route through HLRadius.card now (W6-2).
        #expect(HLRadius.card == 20)
        // The semantic alias is what cards must use — not the raw `lg` (18) or
        // `sm` (10) the cards used to hard-code.
        #expect(HLRadius.lg == 18)
        #expect(HLRadius.sm == 10)
        #expect(HLRadius.card != HLRadius.lg)
        #expect(HLRadius.card != HLRadius.sm)
    }

    // MARK: - §4 ONE spacing grid (cardInset is a named HLSpace token)

    @Test("HLSpace.cardInset replaces the retired HLSpacePB namespace at 14pt")
    func cardInsetTokenPresent() {
        // W6-4: the Settings-card 14pt inset now lives on the global grid as a
        // named sub-grid token (like `chip`), not a private HLSpacePB enum.
        #expect(HLSpace.cardInset == 14)
        // Sits between md (12) and lg (16), as documented.
        #expect(HLSpace.md < HLSpace.cardInset)
        #expect(HLSpace.cardInset < HLSpace.lg)
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
        // The non-localized segments are literal single letters in both stores.
        #expect(ChartDetailStore.Range.day.label == "T")
        #expect(ChartDetailStore.Range.week.label == "W")
        #expect(ChartDetailStore.Range.month.label == "M")
        #expect(ChartDetailStore.Range.sixMonths.label == "6M")
        #expect(TrendsOverlayStore.Range.week.label == "W")
        #expect(TrendsOverlayStore.Range.month.label == "M")
        #expect(TrendsOverlayStore.Range.sixMonths.label == "6M")
    }

    // MARK: - Mood documented deviation (§8 allows it)

    @Test("Mood period keeps its wider spelled-out vocabulary (documented EN)")
    func moodDeviationIntact() throws {
        // Mood deliberately keeps the spelled-out 30d/90d/1y set — 90d has no
        // single-letter Apple-Health equivalent (W6-5 documented deviation).
        // Asserted in EN so the spelled-out source labels are deterministic.
        let en = try Self.lprojBundle(language: "en")
        #expect(en.localizedString(forKey: "30d", value: "MISSING", table: nil) == "30d")
        #expect(en.localizedString(forKey: "90d", value: "MISSING", table: nil) == "90d")
        #expect(en.localizedString(forKey: "1y", value: "MISSING", table: nil) == "1y")
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
