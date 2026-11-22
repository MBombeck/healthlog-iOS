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
/// `HealthLogTests/Resources/UIStandardBaseline.json`. Die Zahl je Datei ist
/// eine **Obergrenze**:
///
/// | Was passiert | Ergebnis |
/// |---|---|
/// | neue Verletzung in einer gelisteten Datei | ❌ Zahl zu hoch |
/// | Verletzung in einer **nicht** gelisteten Datei | ❌ unbekannte Datei (Grenze 0) |
/// | eine Verletzung wurde beseitigt | ✅ grün |
///
/// **Warum keine Gleichheit:** Mehrere Zweige räumen parallel auf. Müsste jeder
/// seine Senkung in diese gemeinsame Datei schreiben, kämen sich die Zweige
/// beim Zusammenführen in die Quere. Gesenkt wird die Datei deshalb zentral
/// nach jedem Zusammenführen mit `scripts/refresh-ui-standard-baseline.py`;
/// das Skript liest die Regeln aus dieser Datei und weigert sich, eine Zahl
/// anzuheben.
///
/// Die verworfenen Knopfvarianten (`ghost`, `restrained`) zählt die
/// SwiftLint-Regel `hl_no_rejected_button_variant` je Paket in
/// `scripts/design-ratchets/`, nicht dieser Test.
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

    /// Sonderfall `hl_card_both_slots`: zählt `HLCard(`- und
    /// `HLSettingsCard(`-Aufrufe, deren Argumentliste **sowohl** `subtitle:`
    /// als auch `footer:` enthält, ohne dass eine `bothSlotsJustification:`
    /// mitgegeben wurde.
    nonisolated static func countCardsWithBothSlots(in text: String) -> Int {
        cardNeedles.reduce(0) { $0 + countBothSlots(in: text, needle: Array($1)) }
    }

    /// Die Kartennamen, die den Kopf mit Untertitel und Fußzeile tragen. Kein
    /// Name ist im anderen enthalten, also zählt keine Karte doppelt.
    nonisolated static let cardNeedles = ["HLCard(", "HLSettingsCard("]

    private nonisolated static func countBothSlots(in text: String, needle: [Character]) -> Int {
        let chars = Array(text)
        var hits = 0
        var index = 0
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

    @Test("Keine E5-Regel liegt in einer Datei über ihrer Baseline, neue Dateien stehen bei null", arguments: rules)
    func ruleMatchesBaseline(rule: Rule) throws {
        let baseline = try Self.loadBaseline()
        let expected = baseline.rules[rule.id] ?? [:]
        let actual = Self.measure()[rule.id] ?? [:]

        // Obergrenze statt Gleichheit: mehrere Zweige senken parallel, ohne
        // diese gemeinsame Datei zu ändern. Gesenkt wird sie nach dem
        // Zusammenführen zentral mit scripts/refresh-ui-standard-baseline.py.
        var lines: [String] = []
        for path in actual.keys.sorted() {
            let allowed = expected[path] ?? 0
            let now = actual[path] ?? 0
            if now > allowed {
                lines.append("  ⬆︎ \(path): \(allowed) → \(now)  NEUE Verletzung — bitte beheben, nicht die Baseline anheben.")
            }
        }
        guard !lines.isEmpty else { return }
        Issue.record(
            """
            Regel \(rule.id) liegt über der Baseline.
            \(rule.rationale)

            \(lines.joined(separator: "\n"))

            Die Baseline in HealthLogTests/Resources/UIStandardBaseline.json ist eine
            Obergrenze je Datei, keine Erlaubnisliste: sie wird nur nach unten korrigiert,
            zentral nach dem Zusammenführen.
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
