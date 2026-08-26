import Foundation
@testable import HealthLog
import Testing

/// Locks the 27 xcstrings keys added by `fix/v052-reconcile-r4-i18n` against
/// accidental removal in future xcstrings reflows.
///
/// Background: a pre-merge audit (`V052-QA-i18n-findings.md`) flagged 27
/// hardcoded German `Text(...)` literals that v0.5.2-touched surfaces used
/// without a corresponding catalog entry. With `sourceLanguage: de`, EN-locale
/// builds rendered the German source text verbatim. R4 added DE+EN catalog
/// entries for all 27; this suite is the regression anchor.
///
/// Strategy: load `de.lproj/Localizable.strings` and `en.lproj/Localizable.strings`
/// directly from the host-app bundle (`Bundle(for: HealthLogTests …)` resolves to
/// the test bundle; `Bundle.main` resolves to the host app once `BUNDLE_LOADER`
/// is configured — both contain compiled catalog tables). For each key, assert
/// the lookup yields a non-empty value distinct from the key (which would
/// indicate the entry is missing or the catalog wasn't compiled).
///
/// Pre-existing 166 empty `{}` skeletons (see audit) are out of scope — they
/// belong to the v0.5.3 EN-sprint.
@Suite("v0.5.2 i18n reconcile keys — catalog presence + DE/EN parity")
struct V052I18nKeysTests {
    /// The 27 keys added by the R4 reconcile pass. After the v0.7.2 source-
    /// language flip (de → en) the catalogue keys are the English source
    /// strings; the regression intent is unchanged (catalogue presence +
    /// DE/EN parity), only the key spelling is now English.
    static let r4Keys: [String] = [
        // A1 — chart detail empty-states
        "No measurements in the selected range",
        "No measurements for the selected source",
        "Enable assistant insight",
        "Show insights",
        // A3 — more-tab section titles (v0.13 WP: renamed from the stale
        // "Mental health & vital signs" after the v0.11 IA cut its vital-signs row)
        "Mood & achievements",
        "App",
        // A5 — metric kind units
        "bpm",
        "%",
        // A6 — mood custom-tag surface
        "My tags",
        "Add custom tag",
        "New",
        "Create new tag",
        "Server sync arrives in a later version.",
        "Tag already exists.",
        "Add tag",
        "Add tags & note",
        // Medications
        "Archived",
        "Reminder times",
        "Add your first medication. Reminders, compliance heatmap and history follow automatically.",
        "At least one time. Up to eight per day.",
        "No medications yet",
        "Optional: photograph the packaging to suggest name and dose. The image never leaves the device.",
        "Weekdays",
        // AI consent
        "Accept",
        "Enable assistant insights",
        "You can change this choice at any time in Settings.",
        // Theme picker
        "Dark"
    ]

    @Test("R4 added exactly 27 keys — list-size lock")
    func keyCountIsTwentySeven() {
        #expect(Self.r4Keys.count == 27)
    }

    @Test("Every R4 key resolves to a non-empty German value")
    func germanValuesPresent() throws {
        let bundle = try Self.lprojBundle(language: "de")
        for key in Self.r4Keys {
            let resolved = bundle.localizedString(forKey: key, value: "MISSING", table: nil)
            #expect(resolved != "MISSING", "Missing DE entry for key: \(key)")
            #expect(!resolved.isEmpty, "Empty DE translation for key: \(key)")
        }
    }

    @Test("Every R4 key resolves to a non-empty English value")
    func englishValuesPresent() throws {
        let bundle = try Self.lprojBundle(language: "en")
        for key in Self.r4Keys {
            let resolved = bundle.localizedString(forKey: key, value: "MISSING", table: nil)
            #expect(resolved != "MISSING", "Missing EN entry for key: \(key)")
            #expect(!resolved.isEmpty, "Empty EN translation for key: \(key)")
        }
    }

    @Test("English values differ from German source for translatable strings")
    func englishDiffersWhereExpected() throws {
        // Some entries are intentionally DE==EN (e.g. "App", "%", "bpm" — universal
        // tokens, identical in both locales). For the rest, assert the EN value
        // actually translates rather than mirroring the DE key — guards against
        // silent "translated"-state regressions where the EN field was left
        // empty + the catalog falls back to the key.
        let deBundle = try Self.lprojBundle(language: "de")
        let enBundle = try Self.lprojBundle(language: "en")
        let universalKeys: Set = ["App", "%", "bpm", "HRV"]
        for key in Self.r4Keys where !universalKeys.contains(key) {
            let de = deBundle.localizedString(forKey: key, value: "", table: nil)
            let en = enBundle.localizedString(forKey: key, value: "", table: nil)
            #expect(de != en, "EN value equals DE source for key — likely untranslated: \(key)")
        }
    }

    // MARK: - Helpers

    /// Resolves the bundle that ships compiled `Localizable.strings` for a given
    /// language code. The HealthLog app bundle ships `de.lproj/` + `en.lproj/`;
    /// the test target's `BUNDLE_LOADER` ensures `Bundle.main` is the host app.
    private static func lprojBundle(language: String) throws -> Bundle {
        guard let lprojPath = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: lprojPath) else
        {
            throw I18nTestError.missingLproj(language: language)
        }
        return bundle
    }

    private enum I18nTestError: Error, CustomStringConvertible {
        case missingLproj(language: String)

        var description: String {
            switch self {
            case let .missingLproj(language):
                "Missing \(language).lproj in host-app bundle — catalog compile broke?"
            }
        }
    }
}
