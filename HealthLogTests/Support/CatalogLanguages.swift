import Foundation
@testable import HealthLog

/// **1.5 L10N-CORE — which languages a catalogue test holds to.**
///
/// Tests used to name `["de", "en"]`. They now start from
/// ``AppLanguage/allCases`` (the languages the code knows) and read the gate
/// status of each one from `scripts/l10n/languages.json`, the same list
/// `check-strings.sh` and `check-catalog-format.py` read:
/// - ``required``: every gap is a failure (today de and en);
/// - ``listed``: also `pending` languages, whose gaps are only counted, so a
///   test may check what is there but must not demand completeness.
/// A code language missing from the list (nl before L10N-NL) is in neither.
enum CatalogLanguages {
    static var required: [String] {
        languages(withStatus: ["required"])
    }

    static var listed: [String] {
        languages(withStatus: ["required", "pending"])
    }

    /// The raw list, for the consistency check against ``AppLanguage``.
    static var statusByLanguage: [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Support
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // <repo>
            .appendingPathComponent("scripts/l10n/languages.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let languages = root["languages"] as? [String: String] else { return [:] }
        return languages
    }

    private static func languages(withStatus statuses: Set<String>) -> [String] {
        let list = statusByLanguage
        return AppLanguage.allCases.map(\.rawValue).filter { statuses.contains(list[$0] ?? "") }
    }
}
