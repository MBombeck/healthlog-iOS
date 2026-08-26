import Foundation
@testable import HealthLog
import Testing

/// **Phase 08 Plan 15 — the support boundary, measured on both sides.**
///
/// Every case here carries a preservation half. Moving the APNs token fragment
/// behind a confirmation is only a fix if the permission status, the test
/// banner and the concise sync outcome stay exactly where a user can reach
/// them — a diagnostics screen that a consumer cannot use is not more private,
/// it is just less useful. `Phase8ReleaseSurfaceTests.diagnosticsRespectConsumerBoundary`
/// asks whether the deep detail is gated; these ask whether the gate is real,
/// whether it is ephemeral, and whether what it opens is read-only.
///
/// **Source contracts read comment-stripped source**, for the reason Phase 07
/// learned twice: a doc comment naming a symbol is not the symbol, and a
/// tombstone comment describing what was removed would otherwise keep every
/// removal assertion passing forever.
@Suite("Phase 08 support-diagnostics policy")
struct SupportDiagnosticsPolicyTests {
    // MARK: - RED closure: notifications

    /// The deep notification instruments are reachable only through a session
    /// that a fresh mount cannot be in, and the consumer half of the screen is
    /// untouched.
    @Test("notification internals need a confirmed, view-local session")
    func notificationDetailsRequireConfirmedEphemeralSession() throws {
        // 1. The gate is a real two-step, and one step is not enough.
        var session = SupportDiagnosticsSession()
        #expect(!session.isConfirmed, "a freshly constructed session must be locked")
        session.confirm()
        #expect(
            !session.isConfirmed,
            "confirm() reached .confirmed from .locked — the consequence was never stated"
        )
        session.requestConfirmation()
        #expect(session.isAwaitingConfirmation && !session.isConfirmed)
        session.confirm()
        #expect(session.isConfirmed, "the two-step must actually open the session")

        var violations: [String] = []

        // 2. The instruments left the consumer screen rather than being copied.
        let screen = try Self.strippedSource(Self.notificationScreen)
        let moved = ["Token prefix", "Token suffix", "forceFreshInFlight", "Re-register APNs token"]
        for instrument in moved where screen.contains(instrument) {
            violations.append("the consumer notification diagnostics still compose `\(instrument)`")
        }
        if screen.contains("meds.diagnostics.category.") {
            violations.append("the consumer notification diagnostics still list banner-category identifiers")
        }
        if screen.contains("meds.diagnostics.pending.") {
            violations.append("the consumer notification diagnostics still list pending request identifiers")
        }

        // 3. They arrived behind the gate, not merely somewhere else. The
        //    contract is structural and is read inside `body` only: every
        //    detail card is mounted after the confirmed-session guard, and the
        //    gate itself is mounted before it.
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
        let arrived = ["Token prefix", "Re-register APNs token", "meds.diagnostics.category."]
        for instrument in arrived where !support.contains(instrument) {
            violations.append("the support screen no longer carries `\(instrument)`")
        }

        // 4. Preservation: the consumer half is still there and still useful.
        for kept in ["authorizationCard", "testNotificationCard", "meds.diagnostics.pendingCount", "medsDataCard"] {
            #expect(screen.contains(kept), "consumer notification help lost `\(kept)`")
        }
        #expect(
            screen.contains("HLSettingsPage(title: \"Advanced diagnostics\")"),
            "the consumer diagnostics page must keep its own name and entry"
        )

        #expect(violations.isEmpty, "support gating moved or duplicated detail incorrectly: \(violations)")
    }

    // MARK: - RED closure: the session is ephemeral by construction

    /// Reset on dismissal, on logout and on cold launch are one mechanism here,
    /// not three cleanup paths — because the session is a value held in view
    /// state and nothing else can hold it.
    @Test("the support session resets at its boundary and is never persisted")
    func sessionResetsOnDismissalAndNeverPersists() throws {
        var session = SupportDiagnosticsSession()
        session.requestConfirmation()
        session.confirm()
        #expect(session.isConfirmed)
        session.end()
        #expect(!session.isConfirmed, "end() must return the session to locked")
        #expect(!session.isAwaitingConfirmation, "end() must not leave a half-open session")
        session.confirm()
        #expect(!session.isConfirmed, "after end(), a bare confirm() must not re-open the session")

        // A cancelled confirmation is a full reset, not a step backwards into
        // some state a second tap could finish.
        var cancelled = SupportDiagnosticsSession()
        cancelled.requestConfirmation()
        cancelled.end()
        cancelled.confirm()
        #expect(!cancelled.isConfirmed)

        // Cold launch: there is no initializer that takes a stage, so a new
        // instance is the only thing a new process can have.
        #expect(SupportDiagnosticsSession() == SupportDiagnosticsSession())
        #expect(!SupportDiagnosticsSession().isConfirmed)

        var violations: [String] = []
        let store = try Self.strippedSource(Self.sessionType)
        let persisters = ["UserDefaults", "Keychain", "FileManager", "Codable", "NSUbiquitous", "SwiftData"]
        for persistence in persisters where store.contains(persistence) {
            violations.append("the support session names `\(persistence)` — it must not outlive the view")
        }
        if store.contains("static let shared") || store.contains("static var shared") {
            violations.append("the support session exposes a process-wide instance")
        }
        if store.contains("class SupportDiagnosticsSession") {
            violations.append("the support session is a reference type, so a copy of it can outlive the screen")
        }

        // View-local, and reset at the boundary.
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

        // Never injected: a container-held session would need its own logout
        // sweep, which is the thing this shape exists to avoid.
        for path in Self.containerFiles {
            let source = try Self.strippedSource(path)
            if source.contains("SupportDiagnosticsSession") {
                violations.append("\(path) composes the support session — it must never be injected")
            }
        }

        #expect(violations.isEmpty, "the support session is not ephemeral by construction: \(violations)")
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

    private static let notificationScreen = "HealthLog/Screens/Notifications/NotificationDiagnosticsScreen.swift"
    static let supportScreen = "HealthLog/Screens/Settings/Sub/SettingsSupportDiagnosticsScreen.swift"
    static let healthKitScreen = "HealthLog/Screens/Settings/Sub/SettingsHKSyncDiagnosticsScreen.swift"
    static let pulseUpload = "HealthLog/Screens/Settings/Sub/SettingsHKSyncDiagnosticsScreen+PulseUpload.swift"
    private static let sessionType = "HealthLog/Stores/SupportDiagnosticsSession.swift"
    private static let containerFiles = [
        "HealthLog/Stores/AppContainer.swift",
        "HealthLog/Stores/AppContainer+Logout.swift",
        "HealthLog/App/HealthLogApp.swift"
    ]

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func strippedSource(_ relativePath: String) throws -> String {
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        return strippingComments(text)
    }

    /// **Line comments come off first, and the order is load-bearing.**
    ///
    /// The sibling helper in `Phase8ReleaseSurfaceTests` strips block comments
    /// first, and that loses whole files: `FeatureFlags.swift` carries the doc
    /// comment ``` `HealthLog/Standalone/*` ``` , whose `/*` opens a block that
    /// never closes, so a block-first pass returns only the text above it and
    /// every later assertion silently reads an empty tail. Removing `//` lines
    /// first makes that `/*` disappear with the comment it lives in.
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
