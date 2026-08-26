import Foundation
@testable import HealthLog
import Testing

/// Phase 08 Wave 0 — the privacy delta, in both directions.
///
/// Phase 08 removes one thing that touches privacy: the locally typed
/// reviewer identity behind the LOINC physician-review surface. A name typed
/// on the device is clinical identity, it is persisted in the Keychain, and it
/// buys a sign-off that no clinician gave. The RED below enumerates every
/// place that identity is currently stored, injected, mutated or shown, so the
/// removal is provable rather than assumed.
///
/// Everything else must not move. The safety flag the removal is supposed to
/// protect (`physicianReviewPending`), the disclaimers, the privacy manifest,
/// the entitlements, the purpose strings and the dependency set are frozen
/// here, because "we deleted the screen" is not the same as "the claim is now
/// true", and a phase that quietly widened data collection while narrowing a
/// UI would read as a privacy improvement in the summary.
///
/// Source contracts read comment-stripped source. Nothing under `secrets/` or
/// any local configuration is read.
@Suite("Phase 08 privacy delta")
struct Phase8PrivacyDeltaTests {
    // MARK: - Preservation

    /// The flag and the disclaimers are the whole reason the reviewer identity
    /// may go: the export stays honestly marked as a draft mapping for
    /// everyone, forever, instead of for everyone who has not typed a name.
    @Test("the pending-review flag and the unconditional disclaimers survive the removal")
    func unconditionalPendingReviewAndDisclaimersRemain() throws {
        let pending = MetricFHIRMapper.allMappings.filter(\.loinc.physicianReviewPending)
        #expect(!pending.isEmpty, "at least one mapping must still declare that it needs clinical review")

        var flags = 0
        for (_, source) in try Self.productionSources() {
            flags += source.components(separatedBy: "physicianReviewPending: true").count - 1
        }
        #expect(flags >= 57, "the frozen 57 pending-review declarations may not shrink with the UI")

        let mapper = try Self.strippedSource("HealthLog/FHIR/MetricFHIRMapper.swift")
        #expect(!mapper.contains("LOINCReviewRegistry"), "the mapping table must stay a pure static table")
        #expect(!mapper.contains("isReviewed"), "no local state may unflag a mapping")

        let about = try Self.strippedSource("HealthLog/Screens/Settings/Sub/SettingsAboutScreen.swift")
        for key in [
            "appstore.disclaimer.not_for_diagnosis",
            "appstore.disclaimer.consult_doctor",
            "appstore.disclaimer.methodology"
        ] {
            #expect(about.contains(key), "the Apple 1.4.1 disclaimer row \(key) must stay")
        }
        #expect(about.contains("disclaimerCard"), "the disclaimer card stays mounted unconditionally")

        // 18-03 — the FHIR export surface became one form of the unified sharing
        // screen. The claim follows the surface, not the filename.
        let export = try Self.strippedSource("HealthLog/Screens/Sharing/UnifiedSharingScreen.swift")
        #expect(export.contains("HealthExportDisclaimerCard"), "control: the disclaimer surface was read")
        #expect(!export.contains("isReviewed"), "the export disclaimer may not be gated on a local sign-off")
    }

    /// The declarations that make the binary shippable. Frozen exactly: a
    /// widened manifest is a privacy change, whichever direction the UI moved.
    @Test("the shipped privacy declarations are unchanged")
    func privacyDeclarationsAreUnchanged() throws {
        let manifest = try Self.plist("HealthLog/Resources/PrivacyInfo.xcprivacy")
        #expect((manifest["NSPrivacyTracking"] as? Bool) == false)
        #expect((manifest["NSPrivacyTrackingDomains"] as? [String] ?? []).isEmpty)
        let apiTypes = (manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]]) ?? []
        let categories = Set(apiTypes.compactMap { $0["NSPrivacyAccessedAPIType"] as? String })
        #expect(categories == [
            "NSPrivacyAccessedAPICategoryUserDefaults",
            "NSPrivacyAccessedAPICategoryFileTimestamp"
        ], "Phase 08 adds no required-reason API category")

        let entitlements = try Self.plist("HealthLog/Resources/HealthLog.entitlements")
        #expect((entitlements["com.apple.developer.healthkit"] as? Bool) == true)
        #expect((entitlements["com.apple.developer.healthkit.background-delivery"] as? Bool) == true)
        #expect(entitlements["com.apple.developer.healthkit.access"] == nil, "no clinical-record access is claimed")

        let info = try Self.plist("HealthLog/Resources/Info.plist")
        for key in [
            "NSHealthShareUsageDescription",
            "NSHealthUpdateUsageDescription",
            "NSUserNotificationsUsageDescription"
        ] {
            let value = info[key] as? String ?? ""
            #expect(!value.isEmpty, "\(key) must stay declared and non-empty")
        }
    }

    /// No analytics, no tracking, no new sample type, no new dependency.
    @Test("Phase 08 introduces no analytics, tracking, HealthKit type or dependency")
    func phase8AddsNoCollectionSurface() throws {
        #if canImport(HealthKit)
            #expect(
                HealthLogSampleTypeRegistry.expectedCount == 35,
                "the frozen sample-type registry may not grow here"
            )
        #endif

        let project = try Self.text("project.yml")
        let vendors = [
            "Firebase", "Crashlytics", "Amplitude", "Mixpanel", "Segment", "AppsFlyer",
            "Adjust", "Sentry", "TelemetryDeck", "PostHog", "GoogleAnalytics", "Branch"
        ]
        for vendor in vendors {
            #expect(!project.contains(vendor), "no analytics vendor may enter the dependency set: \(vendor)")
        }
        #expect(project.contains("SnapshotTesting"), "the one declared package stays declared")

        for (path, source) in try Self.productionSources() {
            for vendor in vendors {
                #expect(!source.contains("import \(vendor)"), "\(path) imports an analytics vendor: \(vendor)")
            }
        }
    }

    // MARK: - RED

    /// Every place a locally typed clinical identity is stored, injected,
    /// mutated or displayed today. All of it goes; nothing here may survive as
    /// a hidden key, an orphaned migrator, or a dead composition root entry.
    @Test("no reviewer identity is stored, injected, mutated or shown")
    func reviewerIdentityStorageAndCompositionAreAbsent() throws {
        var violations: [String] = []

        for path in Self.reviewerOwnedFiles
            where FileManager.default.fileExists(atPath: Self.root.appendingPathComponent(path).path)
        {
            violations.append("\(path) still ships")
        }

        let sources = try Self.productionSources()
        for (path, source) in sources where !Self.reviewerOwnedFiles.contains(path) {
            for symbol in Self.reviewerSymbols where source.contains(symbol) {
                violations.append("\(path) still names `\(symbol)`")
            }
        }

        #expect(violations.isEmpty, "EXPECTED_RED: 08-01 privacy reviewer identity storage or composition remains")
    }

    /// The two files whose entire purpose is the reviewer identity.
    private static let reviewerOwnedFiles = [
        "HealthLog/FHIR/LOINCReviewRegistry.swift",
        "HealthLog/Screens/Settings/Sub/SettingsLOINCReviewScreen.swift"
    ]

    /// Persisted keys, injected symbols, mutating actions and reviewed-success
    /// copy — the complete current reference set, enumerated so the removal
    /// cannot be partial.
    private static let reviewerSymbols = [
        "dev.healthlog.app.fhir.loinc.review.v1",
        "dev.healthlog.app.fhir.loinc.review.v2",
        "fhir.loinc.reviewer.name",
        "LOINCReviewRegistry",
        "loincReviewRegistry",
        "SettingsLOINCReviewScreen",
        "loincReviewCard",
        "settings.advanced.loincReviewRow",
        "settings.loincReview",
        "markReviewed",
        "reviewerName",
        "maxReviewerNameLength",
        "loinc.review.bulk.confirm",
        "physician-reviewed"
    ]

    // MARK: - File access

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func text(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static func plist(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(relativePath))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private static func strippedSource(_ relativePath: String) throws -> String {
        try strippingComments(text(relativePath))
    }

    private static func productionSources() throws -> [(String, String)] {
        let base = root.appendingPathComponent("HealthLog")
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
            return []
        }
        var sources: [(String, String)] = []
        for case let file as URL in walker where file.pathExtension == "swift" {
            let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            sources.append((relative, strippingComments(source)))
        }
        #expect(sources.count > 100, "the production-source scan must actually see the app tree")
        return sources
    }

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
