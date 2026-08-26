import Foundation
import Testing

/// **UI-Standard E5 — die Ratsche.**
///
/// `.planning/ux/STANDARD-ui.md` §4 verlangt sechs SwiftLint-Regeln für die
/// Bausteinsprache. SwiftLint alleine trägt das aber nicht: die Regeln starten
/// laut Umsetzungsschnitt auf `warning`, und eine `warning`-Regel mit 80
/// Treffern wird in der Praxis überlesen, nicht befolgt. Eine
/// `excluded:`-Dateiliste in `.swiftlint.yml` wäre noch schlechter — sie
/// schluckt jeden **neuen** Verstoß in einer bereits gelisteten Datei still.
///
/// Dieser Test ist deshalb die eigentliche Erzwingung. Er zählt die
/// Verletzungen **pro Datei** und vergleicht sie mit
/// `HealthLogTests/Resources/UIStandardBaseline.json`. Der Vergleich ist
/// **exakt**, nicht „höchstens":
///
/// | Was passiert | Ergebnis |
/// |---|---|
/// | neue Verletzung in einer gelisteten Datei | ❌ Zahl zu hoch |
/// | Verletzung in einer **nicht** gelisteten Datei | ❌ unbekannte Datei |
/// | eine Verletzung wurde beseitigt | ❌ Baseline veraltet — Zahl senken |
/// | alle Verletzungen einer Datei beseitigt | ❌ Baseline veraltet — Eintrag streichen |
///
/// **Warum die Liste nicht wachsen kann:** sie zu vergrößern ist möglich, aber
/// nur durch das Anheben einer Zahl bzw. das Hinzufügen eines Schlüssels *in
/// der Baseline-Datei* — eine Änderung, die im Diff auf einer Zeile steht, die
/// nichts anderes tut als „hier ist Schuld dazugekommen". Sie zu verkleinern
/// ist dagegen erzwungen: wer eine Fundstelle aufräumt, **muss** die Baseline
/// senken, sonst wird sein eigener Testlauf rot. Die Liste bewegt sich also
/// nur unter Begründung nach oben und zwangsläufig nach unten.
///
/// U1–U7 räumen ihre Flächen und senken dabei ihre Zeilen. U9 schaltet die
/// SwiftLint-Regeln erst auf `error`, wenn die zugehörige Regel hier bei null
/// steht — die Baseline ist damit gleichzeitig die Restschuld-Anzeige.
@Suite("UI-Standard — Ratschen-Baseline der E5-Bausteinregeln (kann nur schrumpfen)")
struct UIStandardBaselineTests {
    // MARK: - Regel-Katalog

    /// Eine Regel aus der Erzwingungstabelle: Pfadfilter + Muster. Die Muster
    /// sind wortgleich mit den `custom_rules` in `.swiftlint.yml` — eine
    /// Konvention, zwei Erzwingungsorgane (dasselbe Muster wie
    /// `PercentFormatLintTests` ↔ `percent_use_hlnumberformat`).
    struct Rule {
        let id: String
        /// Repo-relative Pfad-Präfixe, die gescannt werden.
        let includePrefixes: [String]
        /// Repo-relative Pfad-Teilstücke, die ausgenommen sind.
        let excludeSubstrings: [String]
        /// `nil` ⇒ Sonderfall, der nicht über ein Regex läuft (siehe `count`).
        let pattern: String?
        /// Was die Regel erzwingt — landet in der Fehlermeldung.
        let rationale: String
    }

    static let rules: [Rule] = [
        Rule(
            id: "hl_no_handmade_chevron",
            includePrefixes: ["HealthLog/"],
            excludeSubstrings: ["/DesignSystem/"],
            pattern: #"\bHLDisclosureChevron\("#,
            rationale: "R8/R10 — Chevron-Zeilen sind HLSettingsActionRow(presents: .push); das Glyph gehört dem Primitive."
        ),
        Rule(
            id: "hl_no_system_buttonstyle",
            includePrefixes: ["HealthLog/Screens/"],
            excludeSubstrings: [],
            pattern: #"\.buttonStyle\(\.(?:borderedProminent|bordered|borderless)\b"#,
            rationale: "R8/R9 — rohe System-Button-Styles fallen aus dem Designsystem heraus."
        ),
        Rule(
            id: "hl_no_raw_toggle",
            includePrefixes: ["HealthLog/Screens/"],
            excludeSubstrings: [],
            pattern: #"\bToggle\("#,
            rationale: "R11 — Schalter-Zeilen sind HLSettingsToggleRow, sonst driften Schrift, Tinte und Gap."
        ),
        Rule(
            id: "hl_no_hlcard_in_settings",
            includePrefixes: ["HealthLog/Screens/Settings/", "HealthLog/Screens/PersonalSettings/"],
            excludeSubstrings: [],
            pattern: #"\bHLCard\("#,
            rationale: "R12 — in den Einstellungen gilt HLSettingsCard; HLCard ist Dashboard-/Insights-Primitive."
        ),
        Rule(
            id: "hl_no_sectionlabel_in_settings",
            includePrefixes: ["HealthLog/Screens/Settings/", "HealthLog/Screens/PersonalSettings/"],
            excludeSubstrings: [],
            pattern: #"\bHLSectionLabel\("#,
            rationale: "R12 — die Abschnittsmarke einer Einstellungsseite ist der Kartentitel."
        ),
        Rule(
            id: "hl_button_legacy_variant",
            includePrefixes: ["HealthLog/"],
            excludeSubstrings: [],
            pattern: #"variant:\s*\.(?:ghost|restrained)\b"#,
            rationale: """
            R9 — das Varianten-Enum schrumpft auf .primary/.secondary/.destructive. \
            `.outline` ist in W0 gefallen (1:1 nach .secondary); `.ghost` und `.restrained` \
            brauchen pro Fundstelle die R9-Entscheidung „Vollbreiten-Aktion (→ .secondary)" \
            oder „Zeile in einer Karte (→ HLSettingsActionRow)" und gehören damit der \
            Einheit, die die Fläche besitzt. \
            \
            Seit R9/E2-A1 (2026-08-23) gibt es eine dritte Übersetzung, und sie ist die \
            häufigste: eine ruhige Aktion INNERHALB einer Kachel wird HLTileActionButton \
            (44 pt, .hlSubhead, monochrome HLText.secondary-Tinte, keine Füllung). Diese \
            Form hebt diesen Zähler NICHT an — genau dafür wurde sie geschrieben. Wer eine \
            Kachel-Aktion braucht und dafür `.restrained` reaktiviert, erhöht die Ratsche \
            und macht aus einer gelösten Regel wieder Schuld.
            """
        ),
        Rule(
            id: "hl_card_both_slots",
            includePrefixes: ["HealthLog/"],
            excludeSubstrings: [],
            pattern: nil, // Sonderfall — Argumentliste, nicht Zeilenmuster.
            rationale: """
            R5/E9 — eine Karte belegt höchstens einen Beitext-Slot: Subtitle ODER Footer. \
            Wo ein Review beide verlangt (Datenschutz-Fläche), macht \
            `bothSlotsJustification:` das am Aufruf sichtbar und nimmt die Karte hier heraus.
            """
        )
    ]

    // MARK: - Baseline

    struct Baseline: Codable {
        /// Regel-ID → (repo-relativer Pfad → Anzahl Verletzungen).
        let rules: [String: [String: Int]]
    }

    /// **`resolvingSymlinksInPath()` ist hier nicht kosmetisch.** `#filePath`
    /// liefert den Pfad, unter dem übersetzt wurde (`/tmp/wt-x/…`), während
    /// `FileManager.enumerator` seine URLs symlink-aufgelöst zurückgibt
    /// (`/private/tmp/wt-x/…`, weil `/tmp` auf macOS ein Symlink ist). Ohne
    /// Auflösung auf **beiden** Seiten greift der Präfix-Abgleich unten nicht,
    /// die Datei-Liste fällt leer aus — und ein zählender Test, der nichts
    /// zählt, ist grün, ohne irgendetwas zu prüfen. Genau dagegen steht
    /// zusätzlich `scanSeesTheSourceTree()`.
    private nonisolated static func repoRoot(file: String = #filePath) -> URL {
        // <repo>/HealthLogTests/DesignSystem/UIStandardBaselineTests.swift
        URL(fileURLWithPath: file)
            .deletingLastPathComponent() // DesignSystem
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // <repo>
            .resolvingSymlinksInPath()
    }

    private nonisolated static func loadBaseline() throws -> Baseline {
        let url = repoRoot()
            .appendingPathComponent("HealthLogTests")
            .appendingPathComponent("Resources")
            .appendingPathComponent("UIStandardBaseline.json")
        return try JSONDecoder().decode(Baseline.self, from: Data(contentsOf: url))
    }

    // MARK: - Scanning

    /// Alle `*.swift` unter `HealthLog/`, als repo-relative Pfade.
    private nonisolated static func sourceFiles() -> [(relative: String, contents: String)] {
        let root = repoRoot()
        let scanRoot = root.appendingPathComponent("HealthLog")
        guard let enumerator = FileManager.default.enumerator(at: scanRoot, includingPropertiesForKeys: nil) else { return [] }
        let rootPath = root.path
        var out: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            var rel = url.resolvingSymlinksInPath().path
            guard rel.hasPrefix(rootPath) else { continue }
            rel.removeFirst(rootPath.count)
            if rel.hasPrefix("/") { rel.removeFirst() }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            out.append((rel, text))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    private nonisolated static func applies(_ rule: Rule, to relative: String) -> Bool {
        guard rule.includePrefixes.contains(where: { relative.hasPrefix($0) }) else { return false }
        return !rule.excludeSubstrings.contains { relative.contains($0) }
    }

    /// Anzahl der Verletzungen einer Regel in einer Datei.
    nonisolated static func count(_ rule: Rule, in text: String) -> Int {
        guard let pattern = rule.pattern else { return countCardsWithBothSlots(in: text) }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// Sonderfall `hl_card_both_slots`: zählt `HLSettingsCard(`-Aufrufe, deren
    /// Argumentliste **sowohl** `subtitle:` als auch `footer:` enthält, ohne
    /// dass eine `bothSlotsJustification:` mitgegeben wurde.
    nonisolated static func countCardsWithBothSlots(in text: String) -> Int {
        let chars = Array(text)
        var hits = 0
        var index = 0
        let needle = Array("HLSettingsCard(")
        while index + needle.count <= chars.count {
            guard Array(chars[index ..< index + needle.count]) == needle else {
                index += 1
                continue
            }
            let open = index + needle.count - 1
            guard let close = matchingParen(chars, from: open) else { break }
            let args = String(chars[(open + 1) ..< close])
            if args.contains("subtitle:"), args.contains("footer:"),
               !args.contains("bothSlotsJustification:")
            {
                hits += 1
            }
            index = close
        }
        return hits
    }

    /// Index der schließenden Klammer zu `chars[start] == "("`, unter
    /// Auslassung von String-Literalen.
    private nonisolated static func matchingParen(_ chars: [Character], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else {
                switch c {
                case "\"": inString = true
                case "(", "[", "{": depth += 1
                case ")", "]", "}":
                    depth -= 1
                    if depth == 0 { return i }
                default: break
                }
            }
            i += 1
        }
        return nil
    }

    /// Der gemessene Ist-Zustand: Regel-ID → (Pfad → Anzahl), Nullen entfernt.
    nonisolated static func measure() -> [String: [String: Int]] {
        let files = sourceFiles()
        var result: [String: [String: Int]] = [:]
        for rule in rules {
            var perFile: [String: Int] = [:]
            for (relative, contents) in files where applies(rule, to: relative) {
                let hits = count(rule, in: contents)
                if hits > 0 { perFile[relative] = hits }
            }
            result[rule.id] = perFile
        }
        return result
    }

    // MARK: - Tests

    @Test("Jede E5-Regel entspricht exakt ihrer Baseline — mehr ist ein Verstoß, weniger ist eine fällige Senkung", arguments: rules)
    func ruleMatchesBaseline(rule: Rule) throws {
        let baseline = try Self.loadBaseline()
        let expected = baseline.rules[rule.id] ?? [:]
        let actual = Self.measure()[rule.id] ?? [:]
        guard expected != actual else { return }

        var lines: [String] = []
        for path in Set(expected.keys).union(actual.keys).sorted() {
            let was = expected[path] ?? 0
            let now = actual[path] ?? 0
            guard was != now else { continue }
            if now > was {
                lines.append("  ⬆︎ \(path): \(was) → \(now)  NEUE Verletzung — bitte beheben, nicht die Baseline anheben.")
            } else if now == 0 {
                lines.append("  ✅ \(path): \(was) → 0  aufgeräumt — Eintrag aus UIStandardBaseline.json STREICHEN.")
            } else {
                lines.append("  ✅ \(path): \(was) → \(now)  aufgeräumt — Zahl in UIStandardBaseline.json auf \(now) SENKEN.")
            }
        }
        Issue.record(
            """
            Regel \(rule.id) weicht von der Baseline ab.
            \(rule.rationale)

            \(lines.joined(separator: "\n"))

            Die Baseline in HealthLogTests/Resources/UIStandardBaseline.json ist eine
            Restschuld-Anzeige, keine Erlaubnisliste: sie darf nur nach unten korrigiert
            werden. Steht eine Regel bei null, darf U9 sie in .swiftlint.yml auf `error` heben.
            """
        )
    }

    @Test("Der Scan sieht den Quellbaum überhaupt — ein Zähler, der nichts zählt, ist kein Test")
    func scanSeesTheSourceTree() {
        let files = Self.sourceFiles()
        #expect(
            files.count > 500,
            """
            Der Datei-Scan hat nur \(files.count) Swift-Dateien unter HealthLog/ gefunden. \
            Das ist kein Aufräum-Erfolg, sondern ein kaputter Pfad: dann melden alle \
            Regeln oben „0 Verletzungen" und die Ratsche wird wirkungslos. Häufigste \
            Ursache ist ein nicht symlink-aufgelöster Pfadvergleich (siehe repoRoot()).
            """
        )
        #expect(files.contains { $0.relative == "HealthLog/DesignSystem/HLSettingsRow.swift" })
    }

    @Test("Die Baseline enthält keine Null-Einträge und keine Regeln, die es nicht gibt")
    func baselineIsWellFormed() throws {
        let baseline = try Self.loadBaseline()
        let known = Set(Self.rules.map(\.id))
        for (ruleID, perFile) in baseline.rules {
            #expect(known.contains(ruleID), "Unbekannte Regel-ID in der Baseline: \(ruleID)")
            for (path, count) in perFile {
                #expect(count > 0, "Null-Eintrag in der Baseline (\(ruleID) → \(path)) — streichen statt auf 0 setzen.")
            }
        }
        for rule in Self.rules {
            #expect(
                baseline.rules[rule.id] != nil,
                "Regel \(rule.id) fehlt in der Baseline — auch eine geräumte Regel braucht ihren (leeren) Eintrag, damit sichtbar bleibt, dass sie bei null steht."
            )
        }
    }
}
