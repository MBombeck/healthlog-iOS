import Foundation
import Testing

/// audit-v0162 L10N-3 — regression lock for the user-facing count keys that
/// were converted from a flat `%lld` form to a proper `variations.plural`
/// (one/other) block so German + English read grammatically at count 1
/// ("1 Eintrag", not "1 Einträge"; "1 entry", not "1 entries").
///
/// Two invariants:
///  1. The curated set of count keys keeps a well-formed one/other plural in
///     BOTH `de` and `en` — so a future xcstrings reflow cannot silently
///     re-flatten them back to the count-1-wrong form.
///  2. Any key in the catalog that carries a plural variation is well-formed
///     (non-empty `one` AND `other` in every localization it declares).
///
/// Parses the source `Localizable.xcstrings` JSON directly (via `#filePath`
/// anchoring), same strategy as `EmptyTranslationGuardTests`, because the
/// runtime `String(localized:)` API resolves plurals opaquely and would hide a
/// malformed block.
@Suite("xcstrings plural-variation guard — L10N-3 count keys")
struct PluralVariationGuardTests {
    /// Keys that MUST carry a one/other plural in DE + EN. Superset of the
    /// v0162 additions plus the pre-existing count plurals we depend on.
    static let requiredPluralKeys: [String] = [
        "%lld entries",
        "%lld entries in the period",
        "briefing.entries %lld",
        "Show all measurements, %lld entries",
        "%lld measurements · last 30 days",
        "%lld measurements this minute",
        "%lld values",
        "%lld heart rate values",
        "%lld points",
        "%lld weeks",
        "Streak: %lld days",
        "Based on %lld days",
        "Last measurement %lld days ago",
        "cycle.stats.daysFormat",
        "med.lowstock.threshold.value",
        "med.inventory.runway",
        "illness.insights.sickCount",
        // Pre-existing (do not regress)
        "insights.workoutsCount %lld",
        "insights.medicationsCount %lld",
        "med.schedule.cadence.rolling.preview %lld",
        "workout.hrZones.a11y.summary %lld"
    ]

    @Test("Required count keys carry a well-formed one/other plural in DE and EN")
    func requiredKeysArePluralized() throws {
        let catalog = try Self.loadCatalog()
        var problems: [String] = []
        for key in Self.requiredPluralKeys {
            guard let entry = catalog.strings[key] else {
                problems.append("\(key): missing from catalog")
                continue
            }
            for lang in ["de", "en"] {
                guard let plural = Self.plural(entry: entry, language: lang) else {
                    problems.append("\(key)/\(lang): no plural variation")
                    continue
                }
                if plural.one?.isEmpty ?? true { problems.append("\(key)/\(lang): empty `one`") }
                if plural.other?.isEmpty ?? true { problems.append("\(key)/\(lang): empty `other`") }
            }
        }
        #expect(problems.isEmpty, "Plural regressions:\n\(problems.joined(separator: "\n"))")
    }

    @Test("English singular differs from plural for the count keys (grammar)")
    func englishSingularDiffersFromPlural() throws {
        let catalog = try Self.loadCatalog()
        var same: [String] = []
        for key in Self.requiredPluralKeys {
            guard let entry = catalog.strings[key],
                  let plural = Self.plural(entry: entry, language: "en"),
                  let one = plural.one, let other = plural.other else { continue }
            if one == other { same.append("\(key): one == other == \(one)") }
        }
        #expect(same.isEmpty, "English one/other should differ:\n\(same.joined(separator: "\n"))")
    }

    @Test("Every plural block in the catalog is well-formed (one + other non-empty)")
    func allPluralBlocksWellFormed() throws {
        let catalog = try Self.loadCatalog()
        var malformed: [String] = []
        for (key, entry) in catalog.strings {
            guard let locs = entry.localizations else { continue }
            for (lang, loc) in locs {
                guard let plural = loc.variations?.plural else { continue }
                if plural.one?.value?.isEmpty ?? true { malformed.append("\(key)/\(lang): empty `one`") }
                if plural.other?.value?.isEmpty ?? true { malformed.append("\(key)/\(lang): empty `other`") }
            }
        }
        #expect(malformed.isEmpty, "Malformed plural blocks:\n\(malformed.prefix(20).joined(separator: "\n"))")
    }

    // MARK: - JSON model

    private struct Catalog: Decodable {
        let strings: [String: Entry]
    }

    private struct Entry: Decodable {
        let localizations: [String: Localization]?
    }

    private struct Localization: Decodable {
        let variations: Variations?
    }

    private struct Variations: Decodable {
        let plural: PluralCases?
    }

    private struct PluralCases: Decodable {
        let one: CaseUnit?
        let other: CaseUnit?
    }

    private struct CaseUnit: Decodable {
        let stringUnit: StringUnit?
        var value: String? {
            stringUnit?.value
        }
    }

    private struct StringUnit: Decodable {
        let value: String?
    }

    // MARK: - Helpers

    private struct FlatPlural {
        let one: String?
        let other: String?
    }

    private static func plural(entry: Entry, language: String) -> FlatPlural? {
        guard let cases = entry.localizations?[language]?.variations?.plural else { return nil }
        return FlatPlural(one: cases.one?.value, other: cases.other?.value)
    }

    private static func loadCatalog(file: String = #filePath) throws -> Catalog {
        let testFileURL = URL(fileURLWithPath: file)
        let repoRoot = testFileURL
            .deletingLastPathComponent() // i18n
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // <repo>
        let catalogURL = repoRoot
            .appendingPathComponent("HealthLog")
            .appendingPathComponent("Resources")
            .appendingPathComponent("Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        return try JSONDecoder().decode(Catalog.self, from: data)
    }
}
