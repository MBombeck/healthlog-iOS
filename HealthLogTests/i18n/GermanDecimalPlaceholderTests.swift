import Foundation
import Testing

/// **H2 (1.1.0) — a German placeholder shows a German number.**
///
/// The QA sweep photographed "z. B. 1.0 mg" under the dose field of the German
/// add-medication sheet. The field parses with the locale (`LocaleDecimalParser`),
/// so the example taught a German user the one form that reads as a thousands
/// separator. Every `…placeholder` key's German value writes decimals with a
/// comma.
@Suite("German placeholders use the decimal comma")
struct GermanDecimalPlaceholderTests {
    @Test("No German placeholder carries a decimal point between digits")
    func germanPlaceholdersUseComma() throws {
        let catalog = try ParityCatalog.load()
        let pattern = try Regex(#"\d\.\d"#)
        let offenders = catalog.strings
            .filter { $0.key.hasSuffix("placeholder") }
            .compactMap { key, entry -> String? in
                guard let german = ParityCatalog.value(entry, language: "de"),
                      german.contains(pattern) else { return nil }
                return "\(key) = \(german)"
            }
            .sorted()
        #expect(offenders.isEmpty, "German placeholders with a decimal point: \(offenders)")
    }
}
