import Foundation
import Testing

/// **POLISH-C (C3)** — iOS offers to save a password whenever a filled secure
/// field leaves the window, and that system prompt swallows the next tap
/// (SET-ROUTE probe G: the first Back after leaving the app did nothing). A
/// secure field that is not a sign-in (an access header value, an API key, a
/// channel token, an export passphrase) is marked with `.hlSecretEntry()`,
/// which keeps iOS from treating it as a login form. Only the sign-in and
/// password screens keep the password content types.
@Suite("Secure fields outside sign-in are no password fields")
struct SecretFieldContentTypeTests {
    /// The screens where a secure field really is the account password.
    private static let signInFiles: Set<String> = [
        "Screens/Onboarding/ServerAuthStep.swift",
        "Screens/Settings/ChangePasswordSheet.swift",
        "Screens/Settings/TwoFactorManagementScreen.swift"
    ]

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("HealthLog")

    private struct Field {
        let file: String
        let line: Int
        let block: String
    }

    /// Every `SecureField(` outside the sign-in screens, with the five lines
    /// after it, where its modifiers stand.
    private static func secureFields() throws -> [Field] {
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var found: [Field] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(sources.path.count + 1))
            guard !signInFiles.contains(relative) else { continue }
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("SecureField(") {
                let block = lines[index ..< min(lines.count, index + 6)].joined(separator: "\n")
                found.append(Field(file: relative, line: index + 1, block: block))
            }
        }
        return found
    }

    @Test("every secure field outside sign-in is a secret entry, never a password")
    func secretFieldsAreMarked() throws {
        let fields = try Self.secureFields()
        #expect(fields.count >= 10, "the scan found too few secure fields to mean anything")
        for field in fields {
            #expect(field.block.contains(".hlSecretEntry()"), "\(field.file):\(field.line) is not marked .hlSecretEntry()")
            #expect(!field.block.contains(".textContentType(.password)"), "\(field.file):\(field.line) still says password")
            #expect(!field.block.contains(".textContentType(.newPassword)"), "\(field.file):\(field.line) still says new password")
        }
    }
}
