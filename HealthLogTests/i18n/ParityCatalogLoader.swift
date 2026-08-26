import Foundation

/// Shared raw-`Localizable.xcstrings` reader for the Build-8 coherence guards
/// (Anrede-Guard, Co-Named-Key-Guard, Glossary-Guard).
///
/// Why parse the source JSON instead of `Bundle.localizedString(...)`?
/// `LocalizedStringKey` never resolves to a `String` in a unit test, and
/// `localizedString(forKey:value:table:)` falls back to the *key* when a
/// translation is missing — so a raw catalog value and its key would both
/// resolve to the same string, hiding exactly the drift these guards detect.
/// Parsing the checked-in JSON sees the raw catalog state (same rationale as
/// `EmptyTranslationGuardTests`).
///
/// The type is a plain `enum` with `nonisolated` statics so the guards can call
/// it from `@Sendable` test closures without actor-isolation friction.
enum ParityCatalog {
    // MARK: - JSON model

    struct Root: Decodable {
        let sourceLanguage: String
        let strings: [String: Entry]
    }

    struct Entry: Decodable {
        let comment: String?
        let extractionState: String?
        let localizations: [String: Localization]?
    }

    struct Localization: Decodable {
        let stringUnit: StringUnit?
        /// Plurals — opaque; presence alone means "localized".
        let variations: AnyOpaque?
    }

    struct StringUnit: Decodable {
        let state: String?
        let value: String?
    }

    /// Decodes-but-ignores an arbitrary sub-tree (plural `variations`).
    struct AnyOpaque: Decodable {
        init(from _: Decoder) throws { /* opaque */ }
    }

    // MARK: - Loading

    /// Loads `HealthLog/Resources/Localizable.xcstrings` from the repository
    /// source tree, anchored via this file's `#filePath` so it works regardless
    /// of build location (DerivedData / CI / local worktree).
    nonisolated static func load(file: String = #filePath) throws -> Root {
        // <repo>/HealthLogTests/i18n/ParityCatalogLoader.swift
        //   → <repo>/HealthLog/Resources/Localizable.xcstrings
        let repoRoot = URL(fileURLWithPath: file)
            .deletingLastPathComponent() // i18n
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // <repo>
        let catalogURL = repoRoot
            .appendingPathComponent("HealthLog")
            .appendingPathComponent("Resources")
            .appendingPathComponent("Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        return try JSONDecoder().decode(Root.self, from: data)
    }

    // MARK: - Value extraction

    /// The non-empty `stringUnit` value for `language` on an entry, or `nil`
    /// when the entry has no plain string for that language (missing block, or
    /// a `variations`/plural entry that carries no single `stringUnit`).
    nonisolated static func value(_ entry: Entry, language: String) -> String? {
        guard let loc = entry.localizations?[language],
              let value = loc.stringUnit?.value,
              !value.isEmpty else { return nil }
        return value
    }

    /// Whether the entry carries *any* localization payload for `language`
    /// (a non-empty `stringUnit` **or** a plural `variations` block).
    nonisolated static func hasLocalization(_ entry: Entry, language: String) -> Bool {
        guard let loc = entry.localizations?[language] else { return false }
        if let value = loc.stringUnit?.value, !value.isEmpty { return true }
        if loc.variations != nil { return true }
        return false
    }
}
