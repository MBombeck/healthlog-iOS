// J1 / F2 — the app-lock prompt texts come from the string catalog.
//
// The Face ID / passcode system prompt showed "HealthLog freischalten" in an
// English build (App Review walk, 26.09.2026): `BiometricGate` passed a fixed
// German `localizedReason` and `localizedFallbackTitle`. The system prompt is
// not observable from a unit test, so the guard is at the source and catalog.

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

        private func source(_ relativePath: String) throws -> String {
            try String(contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
        }

        /// Every `"…"` literal on a non-comment line.
        private func literals(in text: String) throws -> [String] {
            let regex = try NSRegularExpression(pattern: #""([^"\\]|\\.)*""#)
            var found: [String] = []
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                let range = NSRange(line.startIndex..., in: line)
                for match in regex.matches(in: line, range: range) {
                    if let r = Range(match.range, in: line) { found.append(String(line[r])) }
                }
            }
            return found
        }

        private static let lockFiles = [
            "HealthLog/Services/BiometricGate.swift",
            "HealthLog/App/RootPrivacyShield.swift",
            "HealthLog/App/AppLockClock.swift"
        ]

        @Test("no hard-coded German text in the app-lock files", arguments: lockFiles)
        func noGermanLiterals(path: String) throws {
            let german = CharacterSet(charactersIn: "äöüÄÖÜß")
            let offenders = try literals(in: source(path)).filter {
                $0.rangeOfCharacter(from: german) != nil
                    || $0.contains("freischalten")
                    || $0.contains("Geräte-Code")
            }
            #expect(offenders.isEmpty, "\(path): \(offenders)")
        }

        @Test("the LAContext texts are read from the catalog")
        func gateReadsCatalog() throws {
            let text = try source("HealthLog/Services/BiometricGate.swift")
            #expect(text.contains(#"String(localized: "applock.prompt.reason")"#))
            #expect(text.contains(#"String(localized: "applock.prompt.fallback")"#))
            #expect(text.contains("context.localizedFallbackTitle = localizedFallbackTitle"))
            #expect(text.contains("reason: String = BiometricGate.localizedReason"))
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
