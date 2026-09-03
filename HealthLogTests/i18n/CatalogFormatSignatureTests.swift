import Foundation
import Testing

/// Build 273 — every language of a key that takes arguments must consume the
/// same arguments, in the same order.
///
/// The dashboard's compliance line shipped as `String(localized: "\(pct)% today")`.
/// The stray percent is not a literal to Foundation: `% to` parses as a second
/// specifier (space flag, `t` length, `o` octal conversion). The German value
/// `%lld% heute` therefore parsed as `%lld` plus `% he` (a float), a different
/// signature — Foundation rejected the translation and fell back to English, so
/// German users read "66% today" on the first screen of the app.
///
/// This pins the class, not the instance: a translation whose argument
/// signature drifts from the key's is silently dropped at runtime, and no other
/// gate sees it.
@Suite("String catalog — format signatures agree across languages")
struct CatalogFormatSignatureTests {
    /// Argument-consuming specifiers, in order. `%%` is a literal, and
    /// `%#@name@` is a stringsdict plural reference rather than an argument.
    static func argumentSignature(of value: String) -> [String] {
        let pattern = #"%(?:(\d+)\$)?([-+ #0]*)(\d*)(?:\.(\d+))?(hh|h|ll|l|q|L|z|j|t)?([@dDiuUxXoOfFeEgGcCsSpaAb%])"#
        // swiftlint:disable:next force_try
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = value as NSString
        var out: [(Int?, String)] = []
        var index = 0
        for match in regex.matches(in: value, range: NSRange(location: 0, length: ns.length)) {
            let conversion = ns.substring(with: match.range(at: 6))
            if conversion == "%" { continue }
            // `%#@name@` — the `#` flag with an `@` conversion is a plural
            // variable reference, not a positional argument.
            let flags = ns.substring(with: match.range(at: 2))
            if flags.contains("#"), conversion == "@" { continue }
            let position: Int? = match.range(at: 1).location == NSNotFound
                ? nil
                : Int(ns.substring(with: match.range(at: 1)))
            index += 1
            let length = match.range(at: 5).location == NSNotFound ? "" : ns.substring(with: match.range(at: 5))
            out.append((position ?? index, length + conversion))
        }
        return out.sorted { ($0.0 ?? 0) < ($1.0 ?? 0) }.map(\.1)
    }

    private static func catalog() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HealthLog/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("the parser sees the accidental specifier the shipped defect was built on")
    func parserMatchesFoundation() {
        #expect(Self.argumentSignature(of: "%lld% today") == ["lld", "to"])
        #expect(Self.argumentSignature(of: "%lld% heute") == ["lld", "he"])
        #expect(Self.argumentSignature(of: "%lld%% today") == ["lld"])
        #expect(Self.argumentSignature(of: "%1$lld/%#@total@") == ["lld"])
    }

    @Test("every language of an argument-taking key consumes the same arguments")
    func signaturesAgree() throws {
        let strings = try #require(try Self.catalog()["strings"] as? [String: Any])
        var offenders: [String] = []
        for (key, raw) in strings {
            guard !Self.argumentSignature(of: key).isEmpty else { continue }
            guard let entry = raw as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any] else { continue }
            var perLanguage: [String: [String]] = [:]
            for (language, value) in localizations {
                guard let value = value as? [String: Any],
                      let unit = value["stringUnit"] as? [String: Any],
                      let text = unit["value"] as? String else { continue }
                perLanguage[language] = Self.argumentSignature(of: text)
            }
            let distinct = Set(perLanguage.values.map { $0.joined(separator: ",") })
            if distinct.count > 1 {
                offenders.append("\(key): \(perLanguage)")
            }
        }
        #expect(offenders.isEmpty, "format signature drifts:\n\(offenders.joined(separator: "\n"))")
    }
}
