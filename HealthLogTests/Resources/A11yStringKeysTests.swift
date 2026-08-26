import Foundation
@testable import HealthLog
import Testing

/// **W-B188 — accessibility-string localization regression anchor.**
///
/// The b187 a11y audit (`AUDIT-A11Y-b187.md`, finding L1) flagged a set of
/// accessibility labels that were passed to `.accessibilityLabel(_:)` as bare
/// Swift `String`s — which hit the non-localizing `StringProtocol` overload, so
/// German VoiceOver spoke English. The fix routed each through the catalog
/// (`Text(_:)` / `LocalizedStringKey`). This suite locks that: every key those
/// sites resolve to must produce a non-empty value in BOTH `en` and `de`, and a
/// DE value distinct from the raw key, so a regression to the bare-`String`
/// overload (or a deleted key) fails the build.
///
/// Mirrors the proven ``CycleI18nKeysTests`` strategy (load the compiled lproj
/// tables from the host-app bundle, assert `resolved != "MISSING"` + non-empty).
@Suite("W-B188 — a11y label keys resolve in EN + DE")
struct A11yStringKeysTests {
    /// Catalog keys backing the previously-hardcoded accessibility labels.
    /// `%@` / `%lld` format args are part of the stored value; we assert presence
    /// + non-empty, not the formatted output.
    static let a11yKeys: [String] = [
        // InsightsVitalsDashboard — confidence-band VoiceOver label (new key).
        "Confidence %@",
        // ArchivedMedicationsSection — restore button.
        "Restore %@",
        // Add/EditMedicationSheet — remove-time button.
        "Remove time",
        // MedicationsScreen — loading skeleton.
        "Loading medications",
        // HealthScoreTile — loading skeleton.
        "Health Score loading",
        // CadencePicker — weekday group label.
        "med.schedule.weekday.group.label"
    ]

    @Test("Every a11y label key resolves to a non-empty EN value")
    func englishValuesPresent() throws {
        let bundle = try Self.lprojBundle(language: "en")
        for key in Self.a11yKeys {
            let resolved = bundle.localizedString(forKey: key, value: "MISSING", table: nil)
            #expect(resolved != "MISSING", "Missing EN entry for a11y key: \(key)")
            #expect(!resolved.isEmpty, "Empty EN value for a11y key: \(key)")
        }
    }

    @Test("Every a11y label key resolves to a non-empty DE value distinct from the key")
    func germanValuesPresent() throws {
        let bundle = try Self.lprojBundle(language: "de")
        for key in Self.a11yKeys {
            let resolved = bundle.localizedString(forKey: key, value: "MISSING", table: nil)
            #expect(resolved != "MISSING", "Missing DE entry for a11y key: \(key)")
            #expect(resolved != key, "DE value is the raw key (untranslated): \(key)")
            #expect(!resolved.isEmpty, "Empty DE value for a11y key: \(key)")
        }
    }

    // MARK: - Helpers

    private static func lprojBundle(language: String) throws -> Bundle {
        guard let lprojPath = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: lprojPath) else
        {
            throw A11yI18nTestError.missingLproj(language: language)
        }
        return bundle
    }

    private enum A11yI18nTestError: Error, CustomStringConvertible {
        case missingLproj(language: String)

        var description: String {
            switch self {
            case let .missingLproj(language):
                "Missing \(language).lproj in host-app bundle — catalog compile broke?"
            }
        }
    }
}
