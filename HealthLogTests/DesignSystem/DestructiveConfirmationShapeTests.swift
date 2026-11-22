import Foundation
import Testing

/// **UI-Standard R13-A1 / E14 — eine zentrierte Form für jede destruktive Frage.**
///
/// Der Betreiber hat die Rückfrage „generell zentriert und ordentlich designt"
/// verlangt — **generell** heißt app-weit. `STANDARD-ui.md` R13-A1 schreibt
/// deshalb einen einzigen Träger vor: `hlConfirmDestructive(…)`. Verboten ist
/// der **handgebaute** Dialog an der Aufrufstelle, und zwar in beiden Formen:
/// ein roher `.alert` mit destruktivem Knopf genauso wie ein roher
/// `confirmationDialog` mit destruktivem Knopf.
///
/// **Warum ausgerechnet ein `alert` das Substrat ist.** Zentriert und ankerlos
/// ist auf dem iPhone genau eine System-Präsentation. Ein
/// `confirmationDialog` ist per Konstruktion ein Anker — eine Blase an der
/// Interaktionsquelle — und kann „zentriert" gar nicht liefern. Genau daran
/// ist **b174** gescheitert,
/// und der eigene Fix des Betreibers (`cf3f8777`, „Lösch-Bestätigung im
/// Med-Verlauf unten verankert statt Popover auf Zeilenhöhe", 2026-06-11) hat
/// die Blase deshalb absichtlich an die Unterkante genagelt. Ein `alert` hat
/// **keine** Präsentationsquelle, an der er fehl-ankern könnte; das ist der
/// Grund, warum diese Ersatzform b174 löst statt es erneut zu riskieren.
///
/// **Nicht-destruktive Dialoge sind nicht gemeint.** Eine Wahl zwischen
/// gleichrangigen Optionen bleibt ein `confirmationDialog`. Dieser Test zählt
/// nur Blöcke, die einen `role: .destructive`-Knopf enthalten.
@Suite("R13-A1 — destruktive Bestätigungen tragen genau eine geteilte Form")
struct DestructiveConfirmationShapeTests {
    // MARK: - Quellbaum

    private nonisolated static func repoRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent() // DesignSystem
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // <repo>
            .resolvingSymlinksInPath()
    }

    /// Alle `*.swift` unter `HealthLog/`, als repo-relative Pfade.
    private nonisolated static func sourceFiles() -> [(relative: String, contents: String)] {
        let root = repoRoot()
        let scanRoot = root.appendingPathComponent("HealthLog")
        guard let enumerator = FileManager.default.enumerator(at: scanRoot, includingPropertiesForKeys: nil) else {
            return []
        }
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

    // MARK: - Blockweiser Scan

    /// Ein Präsentations-Modifier samt seiner **vollständigen** Argumentliste
    /// und Trailing-Closures.
    ///
    /// Ein Fenster fester Zeilenzahl reicht hier nicht, und das ist keine
    /// Theorie: 17-04 hat mit einem 30-Zeilen-Fenster gezählt und dabei die
    /// `role: .destructive` des Lösch-Dialogs in
    /// `IllnessEpisodeDetailScreen` dem **neutralen** Genesungs-Dialog neun
    /// Zeilen darüber zugeschlagen — 33 statt 32 destruktive Dialoge. Deshalb
    /// wird hier über balancierte Klammern gelaufen.
    struct Block {
        let file: String
        let line: Int
        let modifier: String
        let isDestructive: Bool
    }

    nonisolated static func blocks(in text: String, file: String) -> [Block] {
        let chars = Array(text)
        var out: [Block] = []
        for modifier in [".confirmationDialog(", ".alert("] {
            let needle = Array(modifier)
            var index = 0
            while index + needle.count <= chars.count {
                guard Array(chars[index ..< index + needle.count]) == needle else {
                    index += 1
                    continue
                }
                let open = index + needle.count - 1
                guard let close = endOfModifier(chars, from: open) else { break }
                let body = String(chars[index ... close])
                let line = chars[..<index].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                out.append(Block(
                    file: file,
                    line: line,
                    modifier: String(modifier.dropFirst().dropLast()),
                    isDestructive: body.contains("role: .destructive")
                ))
                index = close
            }
        }
        return out.sorted { ($0.line, $0.modifier) < ($1.line, $1.modifier) }
    }

    /// Index des letzten Zeichens des Modifiers ab `chars[start] == "("` —
    /// inklusive angehängter Trailing-Closures (`) { … } message: { … }`).
    private nonisolated static func endOfModifier(_ chars: [Character], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < chars.count {
            let character = chars[index]
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                index += 1
                continue
            }
            switch character {
            case "\"": inString = true
            case "(", "[", "{": depth += 1
            case ")", "]", "}":
                depth -= 1
                if depth == 0 {
                    var peek = index + 1
                    while peek < chars.count, chars[peek] == " " || chars[peek] == "\n" || chars[peek] == "\t" {
                        peek += 1
                    }
                    let tail = String(chars[peek ..< min(peek + 9, chars.count)])
                    if peek < chars.count, chars[peek] == "{" || tail.hasPrefix("message:") || tail.hasPrefix("actions:") {
                        index = peek
                        continue
                    }
                    return index
                }
            default: break
            }
            index += 1
        }
        return nil
    }

    /// Der Träger selbst darf (und muss) einen `alert` bauen — er ist die
    /// Ausnahme, weil er die Form **ist**.
    private nonisolated static var carrierDirectory: String {
        "HealthLog/DesignSystem/"
    }

    nonisolated static func handBuiltDestructiveConfirmations() -> [Block] {
        sourceFiles()
            .filter { !$0.relative.hasPrefix(carrierDirectory) }
            .flatMap { blocks(in: $0.contents, file: $0.relative) }
            .filter(\.isDestructive)
    }

    // MARK: - Tests

    /// Ein zählender Test, der nichts zählt, ist grün, ohne etwas zu prüfen.
    @Test("Der Scan sieht den Quellbaum")
    func scanSeesTheSourceTree() {
        let files = Self.sourceFiles()
        #expect(files.count > 400, "Quellbaum-Scan lieferte nur \(files.count) Dateien — der Pfad stimmt nicht.")
        // Ob der Blockscanner greift, zeigt eine feste Probe, nicht die Zahl
        // der Alerts im Baum: die OK-Hinweise laufen inzwischen über
        // `hlAcknowledgeAlert`, und jede weitere Umstellung ließe eine
        // Schwelle grundlos rot werden.
        let probe = """
        .alert("t", isPresented: $a) { Button("OK") {} } message: { Text("m") }
        .confirmationDialog("t", isPresented: $b) { Button("Weg", role: .destructive) {} }
        """
        let found = Self.blocks(in: probe, file: "probe")
        #expect(found.map(\.modifier) == ["alert", "confirmationDialog"], "Der Blockscanner greift nicht.")
        #expect(found.map(\.isDestructive) == [false, true], "Der Blockscanner liest die Rolle nicht.")
    }

    @Test("Keine destruktive Bestätigung ist an einer Aufrufstelle handgebaut")
    func noHandBuiltDestructiveConfirmation() {
        let hits = Self.handBuiltDestructiveConfirmations()
        let listing = hits.map { "  \($0.file):\($0.line) — \($0.modifier)" }.joined(separator: "\n")
        #expect(hits.isEmpty, """
        31 destructive confirmations are hand-built at their call sites
        R13-A1: \(hits.count) handgebaute destruktive Bestätigung(en) außerhalb von \
        \(Self.carrierDirectory):

        \(listing)

        Destruktive Rückfragen sind app-weit zentriert und ankerlos — Träger ist \
        `hlConfirmDestructive(…)`, nicht ein eigener Bau je Bildschirm. Ein roher \
        `confirmationDialog` kann zentriert gar nicht liefern (er ist per Konstruktion \
        ein Anker), und ein roher `alert` an der Aufrufstelle umgeht den Träger, ohne \
        das Problem zu lösen. Wer hier legitim etwas ändern will, bewegt STANDARD-ui.md \
        R13-A1, den Träger und diesen Test in einer Änderung.
        """)
    }

    /// Ein Alert hat keine Präsentationsquelle, an der er fehl-ankern kann; ein
    /// Dialog oder Popover am Träger brächte die Fehlankerung an jede Rückfrage zurück.
    @Test("Der Träger baut einen Alert, keinen Dialog und kein Popover")
    func theSharedShapeIsAnAlert() throws {
        let carrier = try #require(
            Self.sourceFiles().first { $0.relative == "\(Self.carrierDirectory)HLConfirmDestructive.swift" },
            "der Träger HLConfirmDestructive.swift fehlt"
        )
        let code = carrier.contents
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(code.contains("alert("))
        #expect(!code.contains("confirmationDialog("))
        #expect(!code.contains("popover("))
    }
}
