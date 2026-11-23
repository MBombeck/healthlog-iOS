import Foundation
@testable import HealthLog
import Testing

/// The support boundary on the support screen itself: the deep detail is
/// mounted only behind a confirmed session, and the session lives in view
/// state and ends on dismissal. Both hang on the SwiftUI body, so they read
/// comment-stripped source; the session's own rules are tested as behaviour
/// in `SupportDiagnosticsSessionTests`.
@Suite("Phase 08 support-diagnostics policy")
struct SupportDiagnosticsPolicyTests {
    @Test("support detail is mounted only behind the confirmed-session guard")
    func supportDetailMountsBehindConfirmedSession() throws {
        var violations: [String] = []
        let support = try Self.strippedSource(Self.supportScreen)
        let body = try #require(Self.supportBody(in: support), "the support screen has no readable body")
        let guardIndex = try #require(
            body.range(of: "if supportSession.isConfirmed"),
            "the support screen composes detail without a confirmed-session guard"
        )
        if let gate = body.range(of: "gateCard"), gate.lowerBound > guardIndex.lowerBound {
            violations.append("the gate itself is mounted behind the gate, so nothing can open it")
        }
        for card in ["registrationCard", "categoriesCard", "pendingIdentifiersCard"] {
            guard let found = body.range(of: card) else {
                violations.append("the support screen no longer mounts `\(card)`")
                continue
            }
            if found.lowerBound < guardIndex.lowerBound {
                violations.append("`\(card)` is mounted above the confirmed-session guard")
            }
        }
        #expect(violations.isEmpty, "support detail is not behind the gate: \(violations)")
    }

    @Test("the support session is view-local state and ends on dismissal")
    func supportSessionIsViewLocalAndEndsOnDismissal() throws {
        var violations: [String] = []
        let support = try Self.strippedSource(Self.supportScreen)
        if !support.contains("@State private var supportSession = SupportDiagnosticsSession()") {
            violations.append("the support session is not constructed as view-local @State")
        }
        if !support.contains(".onDisappear { endSession() }") {
            violations.append("the support screen does not end its session on dismissal")
        }
        if !support.contains("supportSession.end()") {
            violations.append("nothing on the support screen ends the session")
        }
        #expect(violations.isEmpty, "the support session is not view-local: \(violations)")
    }

    /// Push-token fragments help support and nobody else; any other screen that
    /// shows them puts a device identifier on the consumer side of the boundary.
    @Test("push-token fragments are shown only on the support screen")
    func tokenFragmentsStayOnTheSupportScreen() throws {
        let tokens = ["SupportDiagnosticsRedaction.fragment(", "SupportDiagnosticsRedaction.tail(", "tokenPrefix", "tokenSuffix"]
        let appRoot = Self.root.appendingPathComponent("HealthLog")
        let enumerator = try #require(FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil))
        var scanned = 0
        var hits: Set<String> = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            scanned += 1
            let source = try Self.strippingComments(String(contentsOf: file, encoding: .utf8))
            if tokens.contains(where: source.contains) { hits.insert(file.lastPathComponent) }
        }
        #expect(scanned > 100, "the scan did not see the app's source tree")
        // NotificationService produces the snapshot; the support screen is the one reader.
        #expect(hits == ["NotificationService.swift", "SettingsSupportDiagnosticsScreen.swift"])
    }

    // MARK: - Structure helpers

    /// The text of `SettingsSupportDiagnosticsScreen.body`, bounded at the
    /// first member that follows it. Without the bound the slice runs to the
    /// end of the file and the ordering assertions above would bind to the card
    /// *definitions* rather than to where they are mounted — an assertion that
    /// passes for the wrong reason, which is the Phase-07 defect.
    private static func supportBody(in source: String) -> String? {
        guard let start = source.range(of: "var body: some View {") else { return nil }
        let rest = source[start.upperBound...]
        guard let end = rest.range(of: "private var gateCard") else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }

    // MARK: - Inventory helpers

    /// Every production symbol under `HealthLog/Screens/Settings` through which
    /// a release build could manufacture or schedule a raw heart-rate upload
    /// for diagnostics. Paired with the file that names it so the failure says
    /// where to look. Empty is the target state.
    static func settingsMutationHits() throws -> [(String, String)] {
        let symbols = ["PulseUpload", "HKQuantitySample", "HRUploadModeSchedule", "setDesiredMode"]
        let settings = root.appendingPathComponent("HealthLog/Screens/Settings")
        let enumerator = try #require(FileManager.default.enumerator(
            at: settings,
            includingPropertiesForKeys: [.isRegularFileKey]
        ))
        var hits: [(String, String)] = []
        var scanned = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            scanned += 1
            let source = try strippingComments(String(contentsOf: file, encoding: .utf8))
            let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
            for symbol in symbols where source.contains(symbol) {
                hits.append((relative, symbol))
            }
        }
        #expect(scanned > 30, "the Settings inventory scan did not see the Settings tree")
        return hits
    }

    // MARK: - Source access

    static let supportScreen = "HealthLog/Screens/Settings/Sub/SettingsSupportDiagnosticsScreen.swift"

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func strippedSource(_ relativePath: String) throws -> String {
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        return strippingComments(text)
    }

    /// Line comments come off first: a `/*` inside a `//` comment would
    /// otherwise open a block that never closes and swallow the rest of the file.
    static func strippingComments(_ source: String) -> String {
        stripBlockComments(from: stripLineComments(from: source))
    }

    private static func stripBlockComments(from source: String) -> String {
        var out = ""
        var rest = Substring(source)
        while let open = rest.range(of: "/*") {
            out += rest[..<open.lowerBound]
            guard let close = rest.range(of: "*/", range: open.upperBound ..< rest.endIndex) else { return out }
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    private static func stripLineComments(from source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var quoted = false
            var previous: Character = " "
            for (offset, character) in line.enumerated() {
                if character == "\"", previous != "\\" { quoted.toggle() }
                if !quoted, character == "/", previous == "/" { return String(line.prefix(offset - 1)) }
                previous = character
            }
            return String(line)
        }.joined(separator: "\n")
    }
}
