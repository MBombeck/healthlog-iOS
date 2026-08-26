import Foundation
@testable import HealthLog
import Testing

/// Phase 08 Wave 0 — the four release-surface truths, frozen before any UI is
/// deleted.
///
/// Each RED here names a claim the shipped binary makes that the product does
/// not support: a table presentation that only half exists, a physician
/// sign-off produced by a locally typed name, an About version composed by
/// arithmetic, and operator diagnostics reachable by every consumer. The
/// preservation assertions in the same tests are the other half of the
/// contract — deleting the surface is not the same as making the claim true,
/// and a plan that removes the medication order, the pending-review flag, the
/// disclaimers, the test notification or the concise sync outcome has not
/// closed these REDs, it has traded one defect for another.
///
/// **Source contracts read comment-stripped source.** Twice in Phase 07 an
/// assertion kept passing against a doc comment after the symbol it named had
/// moved; every scan below therefore runs over ``strippingComments(_:)``.
@Suite("Phase 08 release-surface truth")
struct Phase8ReleaseSurfaceTests {
    // MARK: - Preservation

    /// Cards-only is a decision about presentation, not about the saved manual
    /// order — that order is per-account server state shared with web, and it
    /// applies to the card list exactly as it applied to both views before.
    @Test("the saved manual medication order survives the cards-only decision")
    func medicationOrderSurvivesCardsOnly() throws {
        let layout = try Self.decodeLayout(#"{"version":1,"view":"cards","order":["m2","m1"]}"#)
        #expect(layout.order == ["m2", "m1"])
        #expect(MedicationListLayout.orderMaxEntries == 200)

        let ordered = layout.applied(to: ["m1", "m2", "m3"], id: { $0 })
        #expect(ordered == ["m2", "m1", "m3"], "the saved order must still rank the card list")

        let untouched = MedicationListLayout.default.applied(to: ["m1", "m2"], id: { $0 })
        #expect(untouched == ["m1", "m2"], "an empty order is a passthrough, not a re-sort")
    }

    /// The consumer half of diagnostics. Whatever gate Wave 1 puts in front of
    /// the operator surfaces, these two must stay in front of it: a user who
    /// cannot tell whether notifications arrive, or whether the last Health
    /// sync did anything, has no way to ask for help in the first place.
    @Test("the consumer notification test and the concise sync outcome stay reachable")
    func consumerDiagnosticsRemainVisible() throws {
        let logic = try Self.strippedSource("HealthLog/Screens/Notifications/NotificationsScreen+Logic.swift")
        #expect(logic.contains("func sendTestNotification(variant:"), "the consumer test notification must stay")

        let channels = try Self.strippedSource("HealthLog/Screens/Notifications/NotificationsScreen+ChannelCards.swift")
        #expect(channels.contains("sendTestNotification(variant:"), "the test-notification affordance must stay mounted")

        let row = try Self.strippedSource("HealthLog/Screens/Settings/ManualSyncStatusRow.swift")
        #expect(row.contains("struct ManualSyncStatusRow"), "the concise manual-sync outcome must stay")
        #expect(ManualSyncState.idle.hasMessage == false, "the concise outcome stays silent until there is one")
    }

    // MARK: - RED

    /// Medication presentation is cards-only, and the removal has to hold for
    /// an installation that already stored `view: table` — that legacy value
    /// must be accepted, neutralised to cards, and never written back as a
    /// user choice.
    @Test("medication presentation is cards-only, legacy wire included")
    func cardsOnlyMedicationContract() throws {
        var violations: [String] = []

        if MedicationListView.allCases.map(\.rawValue) != ["cards"] {
            violations.append("MedicationListView offers \(MedicationListView.allCases.count) presentations, not one")
        }
        if MedicationListView(rawValue: "table") != nil {
            violations.append("the table presentation is still a constructible layout choice")
        }

        let legacy = try Self.decodeLayout(#"{"version":1,"view":"table","order":["m2","m1"]}"#)
        if legacy.view.rawValue != "cards" {
            violations.append("a stored `view: table` still restores a table choice on update")
        }
        #expect(legacy.order == ["m2", "m1"], "neutralising the legacy view must not drop the saved order")
        if let written = try Self.encodedView(of: legacy), written != "cards" {
            violations.append("the legacy table choice is written back as a user choice")
        }

        try violations.append(contentsOf: Self.cardsOnlySourceViolations())

        #expect(violations.isEmpty, "EXPECTED_RED: 08-01 release medication still exposes a table layout")
    }

    /// A name typed into a text field on the device is not a clinical review.
    /// Nothing local may flip a mapping to reviewed, and nothing local may
    /// remove the unconditional medical / FHIR-draft disclaimers.
    @Test("no locally typed name can produce a reviewed clinical claim")
    func localClinicalAttestationIsAbsent() throws {
        let pending = MetricFHIRMapper.allMappings.filter(\.loinc.physicianReviewPending)
        #expect(!pending.isEmpty, "the pending-review flag is the safety statement; it must survive the removal")

        let about = try Self.strippedSource("HealthLog/Screens/Settings/Sub/SettingsAboutScreen.swift")
        for key in ["appstore.disclaimer.not_for_diagnosis", "appstore.disclaimer.consult_doctor"] {
            #expect(about.contains(key), "the App-Review 1.4.1 disclaimer row \(key) must stay unconditional")
        }
        #expect(!about.contains("isReviewed"), "no review state may gate the disclaimer card")

        var violations: [String] = []
        for (path, symbol) in try Self.localAttestationHits() {
            violations.append("\(path) still composes the local sign-off symbol `\(symbol)`")
        }

        #expect(violations.isEmpty, "EXPECTED_RED: 08-01 release local clinical attestation is still reachable")
    }

    /// About must show the exact marketing version and the exact build,
    /// separately, and must not claim the installation is current — nothing on
    /// iOS asks a server what "current" is.
    @Test("About shows the exact marketing version and the exact build")
    func aboutUsesExactBundleTruth() throws {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        #expect(!(short ?? "").isEmpty, "the host bundle must carry a marketing version to be truthful about")
        #expect(!(build ?? "").isEmpty, "the host bundle must carry a build number to be truthful about")

        let source = try Self.strippedSource("HealthLog/Screens/Settings/Sub/SettingsAboutScreen.swift")
        var violations: [String] = []
        if source.contains("build - 40") {
            violations.append("About composes the displayed version by arithmetic on the build number")
        }
        if source.contains("Current version installed.") {
            violations.append("About states the installation is current without any version check")
        }
        if !Self.hasPureIdentitySeam(in: source) {
            violations.append("About exposes no pure seam returning both bundle identity strings")
        }

        #expect(violations.isEmpty, "EXPECTED_RED: 08-01 release About does not show exact bundle version and build")
    }

    /// Token prefixes, wake channels and forced re-registrations are support
    /// instruments. They may stay in the binary, but reaching them has to be a
    /// deliberate act, not a third tap from Settings.
    @Test("deep diagnostics sit behind an explicit support session")
    func diagnosticsRespectConsumerBoundary() throws {
        var violations: [String] = []

        let hk = try Self.strippedSource("HealthLog/Screens/Settings/Sub/SettingsHKSyncDiagnosticsScreen.swift")
        let entry = try Self.strippedSource("HealthLog/Screens/Settings/Sub/AppleHealthIntegrationDetailScreen.swift")
        if hk.contains("wakeChannelsCard"), !Self.namesSupportGate(hk + entry) {
            violations.append("the Apple-Health wake and per-kind counters push without a support session")
        }

        let push = try Self.strippedSource("HealthLog/Screens/Notifications/NotificationDiagnosticsScreen.swift")
        let pushEntry = try Self.strippedSource("HealthLog/Screens/Notifications/NotificationsScreen+ChannelCards.swift")
        if push.contains("Token prefix"), !Self.namesSupportGate(push + pushEntry) {
            violations.append("the device-token prefix and suffix are reachable without a support session")
        }
        if push.contains("forceFreshInFlight"), !Self.namesSupportGate(push + pushEntry) {
            violations.append("the forced push re-registration is reachable without a support session")
        }

        #expect(violations.isEmpty, "EXPECTED_RED: 08-01 release deep diagnostics remain available without a support session")
    }

    // MARK: - Layout helpers

    private static func decodeLayout(_ json: String) throws -> MedicationListLayout {
        try JSONDecoder().decode(MedicationListLayout.self, from: Data(json.utf8))
    }

    /// The value the layout writes back for `view`, or `nil` once the field is
    /// gone. `nil` is the target state; `"cards"` is an acceptable neutralised
    /// intermediate; anything else is a restored table choice.
    private static func encodedView(of layout: MedicationListLayout) throws -> String? {
        let data = try JSONEncoder().encode(layout)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["view"] as? String
    }

    private static func cardsOnlySourceViolations() throws -> [String] {
        var violations: [String] = []
        let sheet = try strippedSource("HealthLog/Screens/Medications/MedicationsLayoutCustomizeSheet.swift")
        if sheet.contains("med.layout.view.table") {
            violations.append("the medication layout sheet still offers a table choice")
        }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(tableRowPath).path) {
            violations.append("\(tableRowPath) still ships a table presentation")
        }
        let store = try strippedSource("HealthLog/Stores/MedicationsStore+CRUD.swift")
        if store.contains("func setListView(") {
            violations.append("the store still writes a user-chosen list view")
        }
        return violations
    }

    private static let tableRowPath = "HealthLog/Screens/Medications/MedicationTableRow.swift"

    // MARK: - Claim helpers

    /// Every production symbol through which a locally typed name reaches a
    /// reviewed claim today. Paired with the file that still names it so the
    /// failure says where to look.
    private static func localAttestationHits() throws -> [(String, String)] {
        let candidates = [
            "HealthLog/FHIR/LOINCReviewRegistry.swift": ["markReviewed", "reviewerName"],
            "HealthLog/Screens/Settings/Sub/SettingsLOINCReviewScreen.swift": ["markReviewed", "reviewerName"],
            "HealthLog/Screens/Settings/Sub/SettingsAdvancedScreen.swift": ["SettingsLOINCReviewScreen"],
            "HealthLog/Stores/AppContainer.swift": ["LOINCReviewRegistry"],
            "HealthLog/App/HealthLogApp.swift": ["loincReviewRegistry"]
        ]
        var hits: [(String, String)] = []
        for path in candidates.keys.sorted() {
            guard let source = try? strippedSource(path) else { continue }
            for symbol in candidates[path, default: []] where source.contains(symbol) {
                hits.append((path, symbol))
            }
        }
        return hits
    }

    /// True when the file exposes a `static` seam that reads both bundle
    /// identity keys, i.e. About's version truth can be asserted without
    /// standing up a view.
    ///
    /// Each candidate is truncated at the end of its own member (the first
    /// closing brace at member indentation) before it is read. Without that
    /// cut the chunk runs to the end of the file and matches the two private
    /// computed properties further down — an assertion that binds to the
    /// wrong text passes for the wrong reason, which is the exact defect
    /// Phase 07 hit twice.
    private static func hasPureIdentitySeam(in source: String) -> Bool {
        source.components(separatedBy: "static func").dropFirst().contains { chunk in
            let member = chunk.components(separatedBy: "\n    }").first ?? chunk
            return member.contains("CFBundleShortVersionString") && member.contains("CFBundleVersion")
        }
    }

    /// Wave 1 owns the mechanism; this only asks that some deliberate session
    /// concept is named on the path to the surface.
    private static func namesSupportGate(_ source: String) -> Bool {
        ["supportSession", "SupportSession", "supportDiagnostics"].contains { source.contains($0) }
    }

    // MARK: - Source access

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func strippedSource(_ relativePath: String) throws -> String {
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        return strippingComments(text)
    }

    /// A doc comment naming a symbol is not the symbol. Phase 07 lost two
    /// assertions to exactly that, so every scan here reads code only.
    private static func strippingComments(_ source: String) -> String {
        stripLineComments(from: stripBlockComments(from: source))
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
