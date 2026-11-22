import Foundation

/// One resolved Swift package with the license it ships under.
///
/// The bundle file `ThirdPartyLicenses.json` is written by
/// `scripts/third-party-licenses.py --generate` from `Package.resolved` and the
/// license files of the resolved checkouts; `--check` fails when a resolved
/// package has no entry. Nothing here is typed by hand.
struct ThirdPartyLicense: Decodable, Identifiable, Hashable, Sendable {
    /// The SwiftPM identity, as `Package.resolved` names the pin.
    let identity: String
    /// The repository name, as the package presents itself.
    let name: String
    let version: String
    /// SPDX expression, e.g. `MIT` or `Apache-2.0`.
    let license: String
    /// The repository the package resolves from.
    let source: String
    /// The full license text, verbatim from the package.
    let text: String
    /// The package's `NOTICE` file, where it ships one (Apache-2.0, 4d).
    let notice: String?

    var id: String {
        identity
    }

    var sourceURL: URL? {
        URL(string: source)
    }

    /// A license text as running paragraphs.
    ///
    /// License files are hard-wrapped at about 80 columns. In a 330 pt column
    /// those lines break a second time and the text reads ragged, so the
    /// wrapped lines of a paragraph are joined into one. The words stay as
    /// they are; only line breaks inside a paragraph become spaces. A blank
    /// line, a list item, a `Copyright` line and a rule (`====`) keep their
    /// own line, so headings, notices and enumerations stand as written; a
    /// list item keeps its indent.
    static func reflowed(_ text: String) -> String {
        var lines: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let last = lines.last, !last.isEmpty, !line.isEmpty,
               !isRule(last), !isRule(line), !startsOwnLine(line)
            {
                lines[lines.count - 1] = last + " " + line
            } else {
                // A list item keeps its indent, so a nested item stays nested.
                lines.append(startsOwnLine(line) ? String(raw) : line)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A line made of one repeated mark, the underline of a heading.
    private static func isRule(_ text: String) -> Bool {
        let line = text.trimmingCharacters(in: .whitespaces)
        guard let first = line.first, "=-*_#~".contains(first) else { return false }
        return line.allSatisfy { $0 == first }
    }

    /// A line that starts a list item or a copyright statement.
    private static func startsOwnLine(_ line: String) -> Bool {
        if line.hasPrefix("Copyright") || line.hasPrefix("(c)") || line.hasPrefix("(C)") { return true }
        if let first = line.first, "-*\u{2022}".contains(first) { return true }
        // "1." / "2)" / "(a)" / "(iv)"
        return line.range(of: #"^(\d+[.)]|\([0-9A-Za-z]{1,4}\))\s"#, options: .regularExpression) != nil
    }
}

/// The license notices bundled with the app, read once per launch.
enum ThirdPartyLicenseCatalog {
    static let resourceName = "ThirdPartyLicenses"

    /// Every package, sorted by name as the generator wrote them.
    static let all: [ThirdPartyLicense] = load(bundle: .main)

    static func load(bundle: Bundle) -> [ThirdPartyLicense] {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return decode(data)
    }

    static func decode(_ data: Data) -> [ThirdPartyLicense] {
        struct File: Decodable {
            let packages: [ThirdPartyLicense]
        }
        return (try? JSONDecoder().decode(File.self, from: data))?.packages ?? []
    }
}

/// HealthLog's own license, as `LICENSE` and the README state it.
enum HealthLogAppLicense {
    /// The `Required Notice:` line of `LICENSE`, which the license asks to
    /// travel with every copy.
    static let requiredNotice = "Required Notice: Copyright (c) 2026 MBombeck"
    static let licenseURL = URL(string: "https://polyformproject.org/licenses/noncommercial/1.0.0")
    static let sourceCodeURL = URL(string: "https://github.com/MBombeck/healthlog-iOS")
}
