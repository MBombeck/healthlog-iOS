import Foundation
@testable import HealthLog
import Testing

/// **Phase 08 Plan 15, Task 2 — the HealthKit half of the support boundary.**
///
/// In an `extension` in a sibling file rather than in the suite's own file, for
/// the reason 08-08 established: a large test type that grows a case at a time
/// eventually trips `type_body_length`, and the strict baseline refuses a new
/// warning. The suite census is unchanged either way — `@Test` cases are
/// counted, not files.
extension SupportDiagnosticsPolicyTests {
    // MARK: - RED closure: HealthKit

    /// No release Settings path manufactures or uploads a raw heart-rate
    /// sample, and the deep Apple-Health detail that remains is read-only and
    /// shortened.
    @Test("HealthKit support detail is read-only and redacted")
    func healthKitDiagnosticsAreReadOnlyAndRedacted() throws {
        var violations: [String] = []

        // 1. The mutation control is gone, file and mount.
        if FileManager.default.fileExists(atPath: Self.root.appendingPathComponent(Self.pulseUpload).path) {
            violations.append("\(Self.pulseUpload) still ships the raw-heart-rate diagnostic switch")
        }
        let hk = try Self.strippedSource(Self.healthKitScreen)
        let relocated = ["pulseUploadCard", "setPulseUploadMode", "pulseUploadMode", "wakeChannelsCard"]
        for gone in relocated where hk.contains(gone) {
            violations.append("the consumer Apple-Health diagnostics still compose `\(gone)`")
        }

        // 2. Nothing anywhere under Settings can write a HealthKit sample or
        //    schedule a raw upload mode. This is the inventory assertion that
        //    replaces reading the deleted file.
        for (path, symbol) in try Self.settingsMutationHits() {
            violations.append("\(path) still exposes the raw-heart-rate mutation symbol `\(symbol)`")
        }

        // 3. What moved is read-only: the support screen writes nothing, and
        //    appearing on it contacts no server.
        let support = try Self.strippedSource(Self.supportScreen)
        let mutations = ["HKQuantitySample", "store.save(", "setDesiredMode", "HRUploadMode", "method: .post"]
        for mutation in mutations where support.contains(mutation) {
            violations.append("the support screen names the mutation symbol `\(mutation)`")
        }
        for card in ["wakeChannelsCard", "anchorsCard"] where !support.contains(card) {
            violations.append("the Apple-Health support detail lost `\(card)`")
        }

        // 4. Redaction is a function, not a promise.
        #expect(SupportDiagnosticsRedaction.fragment(nil) == nil, "an absent value must stay absent")
        #expect(SupportDiagnosticsRedaction.fragment("") == nil, "an empty value must stay absent")
        #expect(SupportDiagnosticsRedaction.fragment("abcd", keeping: 8) == "abcd")
        let long = "0123456789abcdef"
        let head = try #require(SupportDiagnosticsRedaction.fragment(long, keeping: 8))
        #expect(head == "01234567" + SupportDiagnosticsRedaction.elision)
        #expect(!head.contains("abcdef"), "a fragment must never carry the whole value")
        let tail = try #require(SupportDiagnosticsRedaction.tail(long, keeping: 8))
        #expect(tail == SupportDiagnosticsRedaction.elision + "89abcdef")
        #expect(!tail.contains("01234567"))

        // 5. Preservation: the consumer sync answer is untouched.
        for kept in [
            "settings.hkdiag.summary_samples_read",
            "settings.hkdiag.summary_samples_uploaded",
            "settings.hkdiag.summary_last_activity",
            "serverHealthCard",
            "kindListCard"
        ] {
            #expect(hk.contains(kept), "the consumer Apple-Health sync answer lost `\(kept)`")
        }
        // The retirement schedule itself must survive the surface removal —
        // deleting the switch must not delete the fail-closed policy behind it.
        #expect(
            try Self.strippedSource("HealthLog/App/FeatureFlags.swift")
                .contains("rawHeartRateExperimentAvailable"),
            "the raw-heart-rate feature flag is the fail-closed policy and must survive"
        )

        #expect(violations.isEmpty, "HealthKit diagnostics are not read-only and redacted: \(violations)")
    }
}
