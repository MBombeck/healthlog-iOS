// The app-lock prompt texts come from the string catalog.
//
// The Face ID / passcode system prompt showed "HealthLog freischalten" in an
// English build (App Review walk, 26.09.2026): `BiometricGate` passed a fixed
// German `localizedReason` and `localizedFallbackTitle`. The resolved texts are
// pinned in `AppLockPromptCopyTests`; this suite checks both catalog languages.

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @Suite("App-lock prompt localization (J1 / F2)")
    struct AppLockLocalizationGuardTests {
        private func repoRoot() -> URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // Compliance
                .deletingLastPathComponent() // HealthLogTests
                .deletingLastPathComponent() // repo root
        }

        @Test("both prompt keys carry en and de, and they differ")
        func catalogHasBothLanguages() throws {
            let data = try Data(contentsOf: repoRoot().appendingPathComponent("HealthLog/Resources/Localizable.xcstrings"))
            let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let strings = try #require(root["strings"] as? [String: Any])
            for key in ["applock.prompt.reason", "applock.prompt.fallback"] {
                let entry = try #require(strings[key] as? [String: Any], "\(key) missing")
                let locs = try #require(entry["localizations"] as? [String: Any])
                func value(_ lang: String) -> String? {
                    ((locs[lang] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
                }
                let en = try #require(value("en"), "\(key) en")
                let de = try #require(value("de"), "\(key) de")
                #expect(en != de, "\(key) is not translated")
            }
        }
    }

#endif
