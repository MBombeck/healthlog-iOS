import Foundation
@testable import HealthLog
import Testing

/// **1.5 SIRI-L10N** — Siri and Shortcuts read App Shortcut phrases only from
/// `AppShortcuts.xcstrings`, never from `Localizable.xcstrings`. Until 1.5 the
/// phrases sat in `Localizable` as `%@` keys, so the built
/// `Metadata.appintents/root.ssu.yaml` gave the German corpus the English
/// phrases and a German Siri never heard "Erfasse Blutdruck in HealthLog".
///
/// Two layers:
///   - source: every phrase in `HealthLogAppShortcuts.swift` has its key in
///     `AppShortcuts.xcstrings` with a value in every required language, and the
///     catalog holds no phrase the code no longer has;
///   - bundle: the built app ships `de.lproj/AppShortcuts.strings` with the
///     German phrases (absent before 1.5).
@Suite("App Shortcut phrases: AppShortcuts.xcstrings")
struct AppShortcutPhraseCatalogTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Intents
        .deletingLastPathComponent() // HealthLogTests
        .deletingLastPathComponent() // <repo>

    /// The phrase literals of the provider, written as the catalog keys Xcode
    /// derives from them: `\(.applicationName)` becomes `${applicationName}`,
    /// `\(\.$kind)` becomes `${kind}`.
    static func codePhrases() throws -> [String] {
        let source = try Phase8SourceScan.stripped("HealthLog/Intents/HealthLogAppShortcuts.swift")
        var phrases: [String] = []
        var rest = source[...]
        while let open = rest.range(of: "phrases: [") {
            let tail = rest[open.upperBound...]
            guard let close = tail.range(of: "],") else { break }
            let block = String(tail[..<close.lowerBound])
            let literal = try Regex(#""((?:[^"\\]|\\.)*)""#)
            for match in block.matches(of: literal) {
                let raw = String(match.output[1].substring ?? "")
                phrases.append(Self.catalogKey(fromLiteral: raw))
            }
            rest = tail[close.upperBound...]
        }
        return phrases
    }

    static func catalogKey(fromLiteral raw: String) -> String {
        raw.replacingOccurrences(of: #"\(.applicationName)"#, with: "${applicationName}")
            .replacingOccurrences(of: #"\\\(\\\.\$(\w+)\)"#, with: "${$1}", options: .regularExpression)
    }

    static func catalog() throws -> [String: [String: String]] {
        let url = root.appendingPathComponent("HealthLog/Resources/AppShortcuts.xcstrings")
        let data = try Data(contentsOf: url)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: [String: Any]])
        var result: [String: [String: String]] = [:]
        for (key, entry) in strings {
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            result[key] = localizations.compactMapValues { block in
                (block["stringUnit"] as? [String: Any])?["value"] as? String
            }
        }
        return result
    }

    @Test("Key derivation matches Xcode's: application name and parameter tokens")
    func keyDerivation() {
        #expect(Self.catalogKey(fromLiteral: #"Log \(\.$kind) in \(.applicationName)"#)
            == "Log ${kind} in ${applicationName}")
    }

    @Test("Every phrase in code has a catalog entry in every required language, nothing stale")
    func everyPhraseIsInTheCatalog() throws {
        let phrases = try Self.codePhrases()
        #expect(phrases.count >= 31, "phrase scan found only \(phrases.count): parser out of step with the provider")
        let catalog = try Self.catalog()
        for phrase in phrases {
            let values = try #require(catalog[phrase], "no AppShortcuts.xcstrings key for \(phrase)")
            for lang in CatalogLanguages.required {
                let value = try #require(values[lang], "\(phrase) has no \(lang) value")
                #expect(value.contains("${applicationName}"), "\(lang) phrase without the app name: \(value)")
            }
        }
        #expect(Set(catalog.keys) == Set(phrases), "stale catalog keys: \(Set(catalog.keys).subtracting(phrases))")
    }

    @Test("German phrases differ from English, so Siri learns real German phrasings")
    func germanIsTranslated() throws {
        let catalog = try Self.catalog()
        let untranslated = catalog.filter { $0.value["de"] == $0.value["en"] }.keys.sorted()
        #expect(untranslated.isEmpty, "German still English: \(untranslated)")
    }

    /// The table Siri's phrase index reads. `Metadata.appintents/root.ssu.yaml`
    /// shows the same German corpus after a clean build, but an incremental
    /// build can leave it out, so the stable signal is the compiled table.
    @Test("The built app ships a German AppShortcuts table with the German phrases")
    func bundleCarriesGermanTable() throws {
        let path = try #require(Bundle.main.path(
            forResource: "AppShortcuts", ofType: "strings", inDirectory: nil, forLocalization: "de"
        ), "app bundle has no de.lproj/AppShortcuts.strings")
        let table = try #require(NSDictionary(contentsOfFile: path) as? [String: String])
        #expect(table["Log blood pressure in ${applicationName}"] == "Erfasse Blutdruck in ${applicationName}")
        #expect(table["Log my mood in ${applicationName}"] == "Erfasse meine Stimmung in ${applicationName}")
    }
}
