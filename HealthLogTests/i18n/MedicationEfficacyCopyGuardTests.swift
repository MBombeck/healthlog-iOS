import Foundation
import Testing

/// v1.28 (GH iOS #45) — banned-verb guard for the `med.wirkung.*` namespace
/// (the medication-efficacy / "Wirkung" view).
///
/// The efficacy view is a medication-adjacent claim, so its safety boundary is
/// **structural, not left to reviewer vigilance**: the copy must stay strictly
/// descriptive — a temporal association, never "the drug works / is effective",
/// never a verdict or efficacy score, never dose advice. This test parses the
/// **source** `Localizable.xcstrings` (via `#filePath`, like
/// `EmptyTranslationGuardTests`), walks every `med.wirkung.*` value in DE + EN,
/// and fails if any contains a verdict / efficacy-adjective / dose-advice verb.
/// Mirrors the server's `medications-efficacy-verb-guard` denylist so the two
/// platforms enforce the same boundary.
///
/// If this fails: rewrite the offending string to descriptive phrasing (numbers
/// + neutral connectives). Do NOT weaken the denylist to pass.
@Suite("med.wirkung copy guard — no verdict/efficacy/dose-advice wording")
struct MedicationEfficacyCopyGuardTests {
    /// Verdict + efficacy-adjective + dose-advice terms (EN + DE), matched
    /// case-insensitively on word boundaries. Mirrors the server denylist.
    private static let banned: [String] = [
        // English — verdict / efficacy / trend-direction / dose advice
        "works", "work", "working", "effective", "effectively", "ineffective",
        "cure", "cures", "cured", "heal", "heals", "healed",
        "improve", "improved", "improves", "improvement",
        "worsen", "worsens", "worsened", "better", "worse",
        "increase", "decrease", "reduce", "raise", "lower", "success", "successful",
        // German — verdict / efficacy / trend-direction / dose advice
        "wirksam", "unwirksam", "anschlägt", "heilt",
        "verbessert", "verschlechtert", "erhöhen", "senken", "absetzen"
    ]

    @Test("Every med.wirkung.* string in DE + EN is free of banned verbs")
    func noBannedWordsInEfficacyCopy() throws {
        let catalog = try Self.loadCatalog()
        let efficacyKeys = catalog.strings.keys.filter { $0.hasPrefix("med.wirkung.") }.sorted()

        // Sanity: the namespace must exist (a rename would otherwise pass vacuously).
        #expect(efficacyKeys.count >= 20, "expected the med.wirkung.* namespace, found \(efficacyKeys.count) keys")

        var violations: [String] = []
        for key in efficacyKeys {
            guard let entry = catalog.strings[key], let locs = entry.localizations else { continue }
            for language in ["de", "en"] {
                guard let value = locs[language]?.stringUnit?.value, !value.isEmpty else { continue }
                for term in Self.banned where Self.contains(word: term, in: value) {
                    violations.append("\(key) [\(language)] contains \"\(term)\": \(value)")
                }
            }
        }

        #expect(
            violations.isEmpty,
            "The medication-efficacy view is association-only. Rewrite to descriptive phrasing (numbers + neutral connectives):\n\(violations.joined(separator: "\n"))"
        )
    }

    /// Whole-word, case-insensitive containment — so "Bereich" never trips on a
    /// substring and only standalone banned verbs match.
    private static func contains(word: String, in text: String) -> Bool {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    // MARK: - JSON model (mirrors EmptyTranslationGuardTests)

    private struct Catalog: Decodable {
        let strings: [String: Entry]
    }

    private struct Entry: Decodable {
        let localizations: [String: Localization]?
    }

    private struct Localization: Decodable {
        let stringUnit: StringUnit?
    }

    private struct StringUnit: Decodable {
        let value: String?
    }

    /// Loads `HealthLog/Resources/Localizable.xcstrings` from the repository
    /// source tree, anchored via `#filePath`.
    private static func loadCatalog(file: String = #filePath) throws -> Catalog {
        let repoRoot = URL(fileURLWithPath: file)
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
