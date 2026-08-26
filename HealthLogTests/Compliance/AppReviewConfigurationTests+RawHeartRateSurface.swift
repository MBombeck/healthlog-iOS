import Foundation
@testable import HealthLog
import Testing

/// **08-15 — the inventory half of `productionRawHeartRatePolicyFailsClosed`.**
///
/// Until this plan, the release guard read
/// `SettingsHKSyncDiagnosticsScreen+PulseUpload.swift` and asserted that the
/// switch it contained was gated on `FeatureFlags.rawHeartRateExperimentAvailable`.
/// That assertion had a failure mode nobody wants from a compliance test: the
/// moment the file is deleted it throws rather than passes, and the obvious
/// repair — dropping the clause — would leave nothing at all watching the
/// Settings tree for a *new* raw-upload control.
///
/// So the clause was inverted rather than removed. Instead of proving one file
/// fails closed, it now proves that no file under `HealthLog/Screens/Settings`
/// can reach the raw-heart-rate machinery at all: not the deleted switch, not
/// the schedule it wrote, not a HealthKit sample type, not a save site. The
/// fail-closed default itself is asserted separately and directly on
/// `HRUploadModeSchedule`, where it actually lives.
///
/// Lives in a sibling file so the case count and the primary type's body length
/// are both unchanged.
extension AppReviewConfigurationTests {
    /// Symbols through which a release Settings surface could manufacture,
    /// schedule or upload a raw heart-rate sample. Paired with the file that
    /// names one, so a failure says where to look. Empty is the contract.
    ///
    /// **`store.save(` is deliberately not in the list, and is checked as a
    /// pair instead.** Three unrelated Settings screens legitimately call
    /// `store.save(` on a SwiftData or preferences store; flagging the bare
    /// token would have made this guard fire on the Health Score screen and
    /// taught the next reader to widen it until it meant nothing. The thing
    /// that matters is a Settings file that both imports HealthKit *and*
    /// saves — which is exactly the pair `healthKitWriteSitesStayAllowlisted`
    /// keys on, and there must be none of them under Settings at all.
    static func releaseSettingsRawHeartRateHits() throws -> [String] {
        let symbols = [
            "PulseUpload",
            "HRUploadModeSchedule",
            "setDesiredMode",
            "HKQuantitySample"
        ]
        let settings = repositoryRoot.appendingPathComponent("HealthLog/Screens/Settings")
        let enumerator = try #require(FileManager.default.enumerator(
            at: settings,
            includingPropertiesForKeys: [.isRegularFileKey]
        ))
        var hits: [String] = []
        var scanned = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            scanned += 1
            let source = try String(contentsOf: file, encoding: .utf8)
            let relative = file.path.replacingOccurrences(of: repositoryRoot.path + "/", with: "")
            for symbol in symbols where source.contains(symbol) {
                hits.append("\(relative): \(symbol)")
            }
            if source.contains("import HealthKit"), source.contains("store.save(") {
                hits.append("\(relative): a HealthKit write site under Settings")
            }
        }
        // A scan that saw nothing proves nothing — the same trap the
        // `scannedFiles > 100` guard in the reviewer-credential audit closes.
        #expect(scanned > 30, "the release Settings inventory scan did not see the Settings tree")
        return hits
    }

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
