import Foundation
import Testing

/// **H2 (1.1.0) — every settings card title is a catalog key.**
///
/// The QA sweep photographed "Aktueller Server" as the first card heading of
/// Settings → Server in the ENGLISH app: the literal was German and not in the
/// catalog, so both languages showed it verbatim. `check-missing-strings.sh`
/// only sees dotted keys, and the i18n guard does not know `HLSettingsCard`'s
/// parameters. This scan closes that one gap: each literal `title:` / `subtitle:`
/// handed to `HLSettingsCard(` in the app sources must be a catalog key.
/// Previews are exempt (they never ship).
@Suite("HLSettingsCard titles are catalog keys")
struct SettingsCardTitleCatalogTests {
    @Test("No settings card shows an uncatalogued literal")
    func cardLiteralsAreKeys() throws {
        let catalog = try ParityCatalog.load()
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // i18n
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // <repo>
            .appendingPathComponent("HealthLog")
        let call = try Regex(#"HLSettingsCard\(([^)]*)\)"#)
        let argument = try Regex(#"\b(?:title|subtitle):\s*"((?:[^"\\]|\\.)*)""#)
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            var source = try String(contentsOf: url, encoding: .utf8)
            if let preview = source.range(of: "#Preview") { source = String(source[..<preview.lowerBound]) }
            for match in source.matches(of: call) {
                for literal in String(source[match.range]).matches(of: argument) {
                    guard let key = literal.output[1].substring.map(String.init),
                          !key.contains("\\("), catalog.strings[key] == nil else { continue }
                    offenders.append("\(url.lastPathComponent): \(key)")
                }
            }
        }
        #expect(offenders.isEmpty, "Uncatalogued HLSettingsCard literals: \(offenders.sorted())")
    }
}
