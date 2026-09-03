import Foundation
import Testing

/// Build 273 — the coach composer carries a persistent, visible statement that
/// its answers are generated and fallible (App Review 1.2 / 5.1.1: generated
/// content must be identifiable; the first-launch disclaimer alone is one
/// screen the reviewer may never reopen).
///
/// It deliberately stops there. The medical framing lives where the project
/// decided it belongs — the first-launch disclaimer and the AI consent sheet —
/// and `UIStandardCopyGuardTests` keeps blanket "kein medizinischer Rat" tails
/// out of ordinary surfaces.
@Suite("Coach — AI-generated note copy")
struct CoachAIGeneratedNoteTests {
    private static func catalog() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HealthLog/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("the note exists in both languages and names generation and fallibility")
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
        // The blanket medical tail belongs to the disclaimer and the consent
        // sheet, not to every AI surface (UIStandardCopyGuardTests, rule R16).
        #expect(!de.contains("kein medizinischer Rat"))
        #expect(en.count <= 90 && de.count <= 100, "one footnote line")
    }
}
