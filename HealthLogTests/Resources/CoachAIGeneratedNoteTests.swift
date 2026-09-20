import Foundation
import Testing

/// Build 273 — the coach composer carries a persistent, visible statement that
/// its answers are generated and fallible (App Review 1.2 / 5.1.1: generated
/// content must be identifiable; the first-launch disclaimer alone is one
/// screen the reviewer may never reopen).
///
/// **1.0.3 (App Review 1.4.1, Ruling R11)** — it no longer stops at
/// "generated and fallible". Apple rejected 1.0 under 1.4.1, and the audit's
/// finding was that the only always-visible sentence on the coach surface
/// stopped short of saying the answers are not medical advice. The medical
/// framing still lives in the first-launch disclaimer and the AI consent
/// sheet; this line now says it too, because it is the one the reviewer
/// cannot miss. `UIStandardCopyGuardTests` keeps the phrase off ORDINARY
/// surfaces — this key is named in that allowlist's `protected` bucket, with
/// the reason.
@Suite("Coach — AI-generated note copy")
struct CoachAIGeneratedNoteTests {
    private static func catalog() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HealthLog/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("the note exists in both languages and names generation, fallibility and non-advice")
    func noteCopy() throws {
        let strings = try #require(try Self.catalog()["strings"] as? [String: Any])
        let entry = try #require(strings["coach.aiGeneratedNote"] as? [String: Any])
        let locs = try #require(entry["localizations"] as? [String: Any])
        func value(_ lang: String) throws -> String {
            let l = try #require(locs[lang] as? [String: Any])
            let u = try #require(l["stringUnit"] as? [String: Any])
            return try #require(u["value"] as? String)
        }
        let en = try value("en"), de = try value("de")
        #expect(en.localizedCaseInsensitiveContains("AI-generated"))
        #expect(en.localizedCaseInsensitiveContains("wrong"))
        #expect(de.localizedCaseInsensitiveContains("KI-generiert"))
        #expect(de.localizedCaseInsensitiveContains("falsch"))
        // R11 — the sentence the 1.4.1 rejection asked for, in both languages.
        #expect(en.localizedCaseInsensitiveContains("not medical advice"))
        #expect(de.contains("kein medizinischer Rat"))
        #expect(en.count <= 90 && de.count <= 100, "one footnote line")
    }
}
