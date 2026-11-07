import Foundation
@testable import HealthLog
import Testing

/// **1.5 L10N-NL — no listed language ever shows a raw key.**
///
/// nl ships in `CFBundleLocalizations` while it is still `pending`
/// (`scripts/l10n/languages.json`). The bundle looks a key up in that
/// language's own table and does not fall back to English, so a key without a
/// Dutch value showed its identifier (`biomarker.add.sheetTitle`) on screen.
/// Every gap of a pending language therefore carries the English placeholder
/// (`scripts/l10n/fill-placeholders.py`, `docs/localization.md`). This test
/// reads the built bundle the way the app does, one language table at a time,
/// and fails on any dotted key that resolves to itself. Prefixes another unit
/// is still rewriting (`scripts/l10n/placeholder-exemptions.json`) are left
/// out, exactly as the format gate leaves them out.
@Suite("every listed language resolves dotted keys to text, never to the raw key")
struct PendingLanguageFallbackTests {
    @Test("every dotted key reads as text in every listed language")
    @available(iOS 18.4, *)
    func dottedKeysNeverResolveToThemselves() throws {
        let catalog = try ParityCatalog.load()
        let exemptions = try Self.exemptPrefixes()
        var checked = 0
        var leaks: [String] = []
        for language in CatalogLanguages.listed {
            for (key, entry) in catalog.strings where Self.isDotted(key) {
                guard entry.localizations?["en"]?.stringUnit?.value?.isEmpty == false,
                      !exemptions.contains(where: { key.hasPrefix($0) }) else { continue }
                let resolved = Bundle.main.localizedString(
                    forKey: key,
                    value: nil,
                    table: nil,
                    localizations: [Locale.Language(identifier: language)]
                )
                checked += 1
                if resolved == key { leaks.append("\(language): \(key)") }
            }
        }
        #expect(leaks.isEmpty, "raw keys on screen: \(leaks.count), first \(leaks.sorted().prefix(20))")
        #expect(checked > 1000)
    }

    /// 1.5 L10N-FINAL: nl is `required` now, so the key that used to read
    /// English through its placeholder reads Dutch, and no listed language
    /// carries a placeholder any more (`check-catalog-format.py` fails on one).
    @Test("the Dutch table reads Dutch where it once carried an English placeholder")
    @available(iOS 18.4, *)
    func formerPlaceholderReadsDutch() {
        // Changed in de/en since 1.3.0, so it went without a Dutch value from
        // PR #29 and carried the English placeholder until L10N-FINAL.
        let resolved = Bundle.main.localizedString(
            forKey: "biomarker.add.sheetTitle",
            value: nil,
            table: nil,
            localizations: [Locale.Language(identifier: "nl")]
        )
        let english = Bundle.main.localizedString(
            forKey: "biomarker.add.sheetTitle",
            value: nil,
            table: nil,
            localizations: [Locale.Language(identifier: "en")]
        )
        #expect(resolved == "Biomarker")
        #expect(resolved != english)
        #expect(CatalogLanguages.required.contains("nl"))
    }

    private static func isDotted(_ key: String) -> Bool {
        key.range(of: #"^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$"#, options: .regularExpression) != nil
    }

    private static func exemptPrefixes(file: String = #filePath) throws -> [String] {
        let url = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/l10n/placeholder-exemptions.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return object?["prefixes"] as? [String] ?? []
    }
}
