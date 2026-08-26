import Foundation
@testable import HealthLog
import Testing

/// v0.5.4 SP-2 — regression lock against empty xcstrings translations.
///
/// Background: a pre-merge audit of v0.5.2 surfaced 166 keys with an empty
/// `localizations: {}` block plus 17 keys with a German value but a missing
/// English translation. With `sourceLanguage: de`, EN-locale builds would
/// render the German key verbatim, producing visible bilingual leak in the
/// English UI. SP-2 filled all 183 entries by hand; this suite locks the
/// catalog so future xcstrings reflows cannot silently re-drop a translation.
///
/// Strategy: parse the **source** `Localizable.xcstrings` JSON directly from
/// the repository (via `#filePath`-anchored lookup). Walk every key, assert
/// both a non-empty DE `stringUnit` value AND a non-empty EN `stringUnit`
/// value exist — or that a `variations` block is present (plurals don't use
/// `stringUnit`). The single empty-string key (`""`) is whitelisted because
/// it is an intentionally-empty placeholder used as a default-value sentinel.
///
/// Why parse the source file instead of `Bundle.localizedString(...)`?
/// Because `localizedString(forKey:value:table:)` falls back to the key when
/// a translation is missing, so an empty `stringUnit` and a non-empty DE-key
/// would both resolve to the same German string on an EN-locale build — the
/// bug we want to detect. Parsing the JSON sees the raw catalog state.
@Suite("xcstrings empty-translation guard — full-catalog regression lock")
struct EmptyTranslationGuardTests {
    /// Keys deliberately left with an empty value (used as default-value
    /// sentinels, e.g. `String(localized: "", defaultValue: "...")`). These
    /// are not bugs and must not be flagged.
    static let intentionallyEmptyKeys: Set<String> = [""]

    @Test("Every catalog key has a non-empty German translation")
    func germanTranslationsArePresent() throws {
        let catalog = try Self.loadCatalog()
        var missing: [String] = []
        for (key, entry) in catalog.strings {
            if Self.intentionallyEmptyKeys.contains(key) { continue }
            if !Self.hasNonEmptyValue(entry: entry, language: "de") {
                missing.append(key)
            }
        }
        #expect(
            missing.isEmpty,
            "Catalog keys missing a German translation (\(missing.count)): \(missing.prefix(10))"
        )
    }

    @Test("Every catalog key has a non-empty English translation")
    func englishTranslationsArePresent() throws {
        let catalog = try Self.loadCatalog()
        var missing: [String] = []
        for (key, entry) in catalog.strings {
            if Self.intentionallyEmptyKeys.contains(key) { continue }
            if !Self.hasNonEmptyValue(entry: entry, language: "en") {
                missing.append(key)
            }
        }
        #expect(
            missing.isEmpty,
            "Catalog keys missing an English translation (\(missing.count)): \(missing.prefix(10))"
        )
    }

    @Test("Catalog has no entries with an empty `localizations` block")
    func noEmptyLocalizationsBlocks() throws {
        let catalog = try Self.loadCatalog()
        var empty: [String] = []
        for (key, entry) in catalog.strings {
            if Self.intentionallyEmptyKeys.contains(key) { continue }
            if entry.localizations == nil || entry.localizations?.isEmpty == true {
                empty.append(key)
            }
        }
        #expect(
            empty.isEmpty,
            "Catalog keys with empty `localizations: {}` block (\(empty.count)): \(empty.prefix(10))"
        )
    }

    // MARK: - JSON model

    private struct Catalog: Decodable {
        let sourceLanguage: String
        let strings: [String: Entry]
    }

    private struct Entry: Decodable {
        let comment: String?
        let extractionState: String?
        let localizations: [String: Localization]?
    }

    private struct Localization: Decodable {
        let stringUnit: StringUnit?
        /// Plurals — present means non-empty by definition; opaque to us.
        let variations: AnyCodable?
    }

    private struct StringUnit: Decodable {
        let state: String?
        let value: String?
    }

    private struct AnyCodable: Decodable {
        init(from _: Decoder) throws { /* opaque */ }
    }

    // MARK: - Helpers

    /// Returns `true` if the catalog entry has a usable value (non-empty
    /// `stringUnit.value`, or a `variations` plural block) for the given
    /// language code.
    private static func hasNonEmptyValue(entry: Entry, language: String) -> Bool {
        guard let locs = entry.localizations, let loc = locs[language] else { return false }
        if let unit = loc.stringUnit, let value = unit.value, !value.isEmpty { return true }
        if loc.variations != nil { return true }
        return false
    }

    /// Loads `HealthLog/Resources/Localizable.xcstrings` from the repository
    /// source tree, anchored via `#filePath` so the test works regardless of
    /// build location (DerivedData / CI / local).
    private static func loadCatalog(file: String = #filePath) throws -> Catalog {
        let testFileURL = URL(fileURLWithPath: file)
        // <repo>/HealthLogTests/i18n/EmptyTranslationGuardTests.swift
        //   → <repo>/HealthLog/Resources/Localizable.xcstrings
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
