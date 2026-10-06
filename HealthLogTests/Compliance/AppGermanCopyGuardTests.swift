// L1 — no hard-coded German user copy anywhere in the app code.
//
// App Review reads 1.1.0 in English. J1 (`AppLockLocalizationGuardTests`) found
// German literals in the app-lock prompt and guarded those three files; the
// sweep that followed (L1) found the same class of leak across the app:
// Personal Records (segment labels, metric names, streak and best-day labels,
// the comparison band, every VoiceOver sentence), the workout detail tiles,
// chart audio-graph labels, error detail sentences and passkey errors.
//
// `scripts/i18n-guard.py` (CI) only looks at literals sitting directly inside a
// localization API. Most of these leaks were one step removed: a German
// literal in a `String` table, a `static let` the view later wraps in
// `LocalizedStringKey(...)`, a `String` a view renders verbatim, an
// `HLError.unknown("…")` a screen shows. This guard looks at EVERY string
// literal in the app targets instead, and fails on any that reads German and
// is not a key of its target's String Catalog.
//
// What counts as German: an umlaut / ß, or one of the German words in
// `germanWords` (function words plus the vocabulary the leaks actually used).
// Exempt, each for a stated reason:
//   * comments, `#if DEBUG` blocks, `#Preview` bodies;
//   * log / assertion calls (`HLLog.*`, `Logger`, `print`, `precondition`, …)
//     and FoundationModels `@Guide(description:)` prompt text;
//   * all-lowercase literals without sentence punctuation — identifiers,
//     wire tokens, legacy ids and search synonyms (`"blutdruck"`, `"serie"`);
//   * literals that ARE a key of the target's catalog (`"Höhenmeter"`);
//   * `bothSlotsJustification:` (a `StaticString` lint note, never shown);
//   * `allowedPaths` below — vocabulary matched against German input, the
//     German branch of the doctor PDF, on-device model prompts;
//   * a line carrying `// i18n-guard: allow` (the marker `i18n-guard.py` uses).

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @Suite("App-wide German copy guard (L1)")
    struct AppGermanCopyGuardTests {
        struct Finding: CustomStringConvertible {
            let path: String
            let line: Int
            let literal: String
            var description: String {
                "\(path):\(line) \(literal.debugDescription)"
            }
        }

        // MARK: - Policy

        /// Target root → its String Catalog.
        static let targets: [(root: String, catalog: String)] = [
            ("HealthLog", "HealthLog/Resources/Localizable.xcstrings"),
            ("HealthLogWatch", "HealthLogWatch/Resources/Localizable.xcstrings"),
            ("HealthLogWatchWidgets", "HealthLogWatchWidgets/Localizable.xcstrings"),
            ("HealthLogWidgets", "HealthLogWidgets/Resources/Localizable.xcstrings"),
            ("NotificationServiceExtension", "NotificationServiceExtension/Resources/Localizable.xcstrings")
        ]

        /// Path prefixes whose German literals are not user copy.
        static let allowedPaths: [(prefix: String, reason: String)] = [
            ("HealthLog/Services/AI/", "on-device model prompts, safety-filter patterns; replies branch on the language"),
            ("HealthLog/Services/PDF/DoctorReport", "the explicit `ReportLocale.de` branch of the doctor PDF"),
            ("HealthLog/Services/Vision/", "OCR vocabulary matched against German packs and lab reports"),
            ("HealthLog/Screens/Labs/BiomarkerExplainer.swift", "German analyte aliases matched against lab names"),
            ("HealthLog/Services/HealthKit/MoodStateOfMindMapping.swift", "German mood words matched onto HealthKit labels"),
            ("HealthLog/FHIR/", "German input values the FHIR mappers accept (männlich, hämoglobin)")
        ]

        /// Call contexts whose string arguments never reach a user.
        static let exemptCallees: Set<String> = [
            "print", "debugPrint", "NSLog", "os_log", "fatalError", "precondition", "preconditionFailure",
            "assert", "assertionFailure", "Guide", "@Guide", "NSRegularExpression", "Regex"
        ]

        static let logLevels: Set<String> = [
            "debug", "info", "notice", "warning", "error", "fault", "trace", "critical", "log"
        ]

        static let exemptArgumentLabels: Set<String> = ["bothSlotsJustification"]

        static let germanWords: Set<String> = Set("""
        und oder nicht noch kein keine keinen keiner wird wurde werden ist sind dein deine deinen deiner \
        dich eine einen einer eines mehr mit bei ohne heute gestern bitte nach seit zuvor erreicht \
        tage tagen minuten stunden woche wochen monat monate jahr jahre serie rekord rekorde einträge \
        eintrag wert werte messung messungen messpunkte allzeit dieses diese dieser neuer neue neues \
        längste bester bestwert bestleistung vergleich vergleichsbereich zeit ziel auswahl jetzt spiegel \
        datum kalorien manuell puls gewicht glukose blutzucker blutdruck temperatur systolisch diastolisch \
        stimmung stockwerke schlaf schritte bereit niedrig verbunden getrennt erscheinungsbild kritisch \
        willkommen archiviert grund fehler netzwerk anmelden abmelden anmeldung abgelaufen verfügbar \
        erneut versuch versuche speichern gespeichert löschen abbrechen fertig weiter zurück schließen \
        öffnen tippen teilen einstellungen passwort benutzername quelle quellen hinweis hinweise zeitraum \
        verlauf durchschnitt typischen bereich letzte letzten nacht tief kern wach herzfrequenz \
        medikament medikamente einnahme erinnerung erfasst erfasse erfassen genommen fällig überfällig \
        abgelehnt ungültig unbekannt unbekannte gerät konnte
        """.split(whereSeparator: \.isWhitespace).map(String.init))

        static func looksGerman(_ text: String) -> Bool {
            if text.rangeOfCharacter(from: CharacterSet(charactersIn: "äöüÄÖÜß")) != nil { return true }
            let words = text.lowercased().split { !$0.isLetter }
            return words.contains { germanWords.contains(String($0)) }
        }

        /// Identifiers, wire tokens, search synonyms: no capital letter and no
        /// sentence punctuation.
        static func isToken(_ text: String) -> Bool {
            !text.contains { $0.isUppercase || ".!?:".contains($0) }
        }

        // MARK: - Scanner

        /// Every string literal of a Swift source with its line, the call
        /// context it sits in and whether it is exempt by position.
        struct Literal {
            let line: Int
            let text: String
            let exempt: Bool
        }

        /// A cursor over one Swift source that collects its string literals.
        private struct Scanner {
            let chars: [Character]
            var index = 0
            var line = 1
            var out: [Literal] = []
            /// Callee expression of every open `(` — `HLLog.auth.error`, `.debug`, `Text`.
            var calls: [String] = []
            /// One entry per open `#if`; `true` while inside a `#if DEBUG` branch.
            var conditionals: [Bool] = []
            var braceDepth = 0
            var previewDepth: Int?
            var previewPending = false

            init(_ source: String) {
                chars = Array(source)
            }

            func peek(_ text: String, at position: Int) -> Bool {
                guard position >= 0 else { return false }
                var cursor = position
                for char in text {
                    guard cursor < chars.count, chars[cursor] == char else { return false }
                    cursor += 1
                }
                return true
            }

            func isIdentifierChar(_ char: Character) -> Bool {
                char.isLetter || char.isNumber || "_.#@".contains(char)
            }

            /// The dotted identifier that ends right before `position`,
            /// skipping whitespace (`HLLog.auth.error`, `.debug`, `Text`).
            func identifier(before position: Int) -> String {
                var end = position - 1
                while end >= 0, chars[end].isWhitespace {
                    end -= 1
                }
                var start = end
                while start >= 0, isIdentifierChar(chars[start]) {
                    start -= 1
                }
                guard start < end else { return "" }
                return String(chars[(start + 1) ... end])
            }

            func argumentLabel(before position: Int) -> String? {
                var end = position - 1
                while end >= 0, chars[end].isWhitespace {
                    end -= 1
                }
                guard end >= 0, chars[end] == ":" else { return nil }
                let label = identifier(before: end)
                return label.isEmpty ? nil : label
            }

            func isExemptCallee(_ callee: String) -> Bool {
                if AppGermanCopyGuardTests.exemptCallees.contains(callee) { return true }
                let parts = callee.split(separator: ".").map(String.init)
                if callee.hasPrefix("HLLog") || parts.contains("logger") || parts.contains("Logger")
                    || parts.contains("log")
                {
                    return true
                }
                // A log call continued on its own line: `.debug(` after `HLLog.x`.
                return callee.hasPrefix(".") && AppGermanCopyGuardTests.logLevels.contains(String(callee.dropFirst()))
            }

            func positionIsExempt() -> Bool {
                if conditionals.contains(true) || previewDepth != nil || previewPending { return true }
                if calls.contains(where: isExemptCallee) { return true }
                if let label = argumentLabel(before: index), AppGermanCopyGuardTests.exemptArgumentLabels.contains(label) { return true }
                return false
            }

            func startsRawString(at position: Int) -> Bool {
                var cursor = position
                while cursor < chars.count, chars[cursor] == "#" {
                    cursor += 1
                }
                return cursor > position && cursor < chars.count && chars[cursor] == "\""
            }

            /// Reads one string literal starting at `index` (its `#` or `"`).
            /// Interpolated segments become `%@`; a literal nested inside an
            /// interpolation is reported on its own.
            mutating func readString(exempt: Bool) {
                var hashes = 0
                while chars[index] == "#" {
                    hashes += 1
                    index += 1
                }
                let multiline = peek("\"\"\"", at: index)
                let startLine = line
                index += multiline ? 3 : 1
                let closer = (multiline ? "\"\"\"" : "\"") + String(repeating: "#", count: hashes)
                let escape = "\\" + String(repeating: "#", count: hashes)
                var text = ""
                while index < chars.count {
                    if peek(closer, at: index) {
                        index += closer.count
                        break
                    }
                    if peek(escape + "(", at: index) {
                        index += escape.count + 1
                        skipInterpolation(exempt: exempt)
                        text += "%@"
                        continue
                    }
                    if peek(escape, at: index) {
                        // An escape sequence: keep it, never let it close the literal.
                        let end = min(index + escape.count + 1, chars.count)
                        for char in chars[index ..< end] {
                            if char == "\n" { line += 1 }
                            text.append(char)
                        }
                        index = end
                        continue
                    }
                    if chars[index] == "\n" {
                        line += 1
                        if !multiline { break }
                    }
                    text.append(chars[index])
                    index += 1
                }
                out.append(Literal(line: startLine, text: text, exempt: exempt))
            }

            /// Skips an interpolation body up to its closing paren; string
            /// literals inside it are read (and reported) on their own.
            mutating func skipInterpolation(exempt: Bool) {
                var depth = 1
                while index < chars.count, depth > 0 {
                    let char = chars[index]
                    if char == "\"" || startsRawString(at: index) {
                        readString(exempt: exempt)
                        continue
                    }
                    if char == "(" { depth += 1 }
                    if char == ")" { depth -= 1 }
                    if char == "\n" { line += 1 }
                    index += 1
                }
            }

            /// Handles a `#if` / `#else` / `#endif` / `#Preview` at `index`;
            /// returns `true` when it consumed the directive line.
            mutating func readDirective() -> Bool {
                let lineEnd = chars[index...].firstIndex(of: "\n") ?? chars.count
                let directive = String(chars[index ..< lineEnd])
                if directive.hasPrefix("#if ") || directive.hasPrefix("#if(") {
                    conditionals.append(directive.contains("DEBUG") && !directive.contains("!DEBUG"))
                } else if directive.hasPrefix("#else") || directive.hasPrefix("#elseif") {
                    if !conditionals.isEmpty { conditionals[conditionals.count - 1] = false }
                } else if directive.hasPrefix("#endif") {
                    _ = conditionals.popLast()
                } else {
                    if directive.hasPrefix("#Preview") { previewPending = true }
                    return false
                }
                index = lineEnd
                return true
            }

            mutating func skipComment() -> Bool {
                if peek("//", at: index) {
                    while index < chars.count, chars[index] != "\n" {
                        index += 1
                    }
                    return true
                }
                guard peek("/*", at: index) else { return false }
                index += 2
                while index < chars.count, !peek("*/", at: index) {
                    if chars[index] == "\n" { line += 1 }
                    index += 1
                }
                index = min(index + 2, chars.count)
                return true
            }

            mutating func trackStructure(_ char: Character) {
                switch char {
                case "(":
                    calls.append(identifier(before: index))
                case ")":
                    _ = calls.popLast()
                case "{":
                    braceDepth += 1
                    if previewPending, previewDepth == nil {
                        previewDepth = braceDepth
                        previewPending = false
                    }
                case "}":
                    if let depth = previewDepth, depth == braceDepth { previewDepth = nil }
                    braceDepth -= 1
                case "\n":
                    line += 1
                default:
                    break
                }
            }

            mutating func run() -> [Literal] {
                while index < chars.count {
                    if skipComment() { continue }
                    let char = chars[index]
                    if char == "#", readDirective() { continue }
                    if char == "\"" || startsRawString(at: index) {
                        readString(exempt: positionIsExempt())
                        continue
                    }
                    trackStructure(char)
                    index += 1
                }
                return out
            }
        }

        static func literals(in source: String) -> [Literal] {
            var scanner = Scanner(source)
            return scanner.run()
        }

        // MARK: - Repository access

        static func repoRoot() -> URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // Compliance
                .deletingLastPathComponent() // HealthLogTests
                .deletingLastPathComponent() // repo root
        }

        static func catalogKeys(_ relativePath: String) throws -> Set<String> {
            let data = try Data(contentsOf: repoRoot().appendingPathComponent(relativePath))
            let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let strings = try #require(root["strings"] as? [String: Any])
            return Set(strings.keys)
        }

        static func swiftFiles(under root: String) -> [String] {
            let base = repoRoot().appendingPathComponent(root).resolvingSymlinksInPath()
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
                return []
            }
            let prefix = base.path + "/"
            return walker.compactMap { item in
                guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
                let path = url.resolvingSymlinksInPath().path
                guard path.hasPrefix(prefix) else { return nil }
                return root + "/" + path.dropFirst(prefix.count)
            }.sorted()
        }

        static func findings(path: String, source: String, catalog: Set<String>) -> [Finding] {
            if allowedPaths.contains(where: { path.hasPrefix($0.prefix) }) { return [] }
            let lines = source.components(separatedBy: "\n")
            return literals(in: source).compactMap { literal in
                guard !literal.exempt, looksGerman(literal.text), !isToken(literal.text) else { return nil }
                guard !catalog.contains(literal.text) else { return nil }
                let lineText = literal.line - 1 < lines.count ? lines[literal.line - 1] : ""
                if lineText.range(of: #"//\s*i18n-guard:\s*allow"#, options: .regularExpression) != nil {
                    return nil
                }
                return Finding(path: path, line: literal.line, literal: literal.text)
            }
        }

        // MARK: - Tests

        @Test("no hard-coded German user copy in any app target")
        func appCodeHasNoGermanCopy() throws {
            var all: [Finding] = []
            var scanned = 0
            for target in Self.targets {
                let catalog = try Self.catalogKeys(target.catalog)
                for path in Self.swiftFiles(under: target.root) {
                    let source = try String(
                        contentsOf: Self.repoRoot().appendingPathComponent(path),
                        encoding: .utf8
                    )
                    scanned += 1
                    all += Self.findings(path: path, source: source, catalog: catalog)
                }
            }
            // A guard that reads nothing passes vacuously.
            #expect(scanned > 1000, "scanned only \(scanned) Swift files")
            #expect(
                all.isEmpty,
                """
                \(all.count) German literal(s) outside the String Catalog. Move the text into \
                Localizable.xcstrings (en + de) and reference the key; a deliberate exception \
                gets `// i18n-guard: allow` plus a reason.
                \(all.map(\.description).joined(separator: "\n"))
                """
            )
        }

        @Test("the scanner sees what it must and skips what it may")
        func scannerSelfTest() {
            let sample = #"""
            struct Sample {
                // "Kommentar mit Umlaut ä" is ignored
                let label = "Längste Serie"
                let a11y = "\(metric) Vergleich. Dein Wert: \(value)"
                let nested = "\(flag ? "Bester Tag" : "Best day")"
                let key = "Höhenmeter"
                let token = "blutdruck"
                let english = "Personal best"
                func log() { HLLog.auth.error("Anmeldung fehlgeschlagen: \(x)") }
                func chained() {
                    HLLog.auth
                        .debug("Übersprungen, kein Fehler.")
                }
                let card = HLSettingsCard(bothSlotsJustification: "Zwei Aussagen, beide nötig.")
                let marked = "Grund: bewusst" // i18n-guard: allow — fixture
            }
            #if DEBUG
                let debugOnly = "Nur für Tests"
            #endif
            #Preview("Vorschau") {
                Text("Gewicht")
            }
            """#
            let found = Self.findings(path: "HealthLog/Sample.swift", source: sample, catalog: ["Höhenmeter"])
            let texts = found.map(\.literal)
            #expect(texts == ["Längste Serie", "%@ Vergleich. Dein Wert: %@", "Bester Tag"], "\(found)")
            #expect(found.map(\.line) == [3, 4, 5])
        }
    }

#endif
