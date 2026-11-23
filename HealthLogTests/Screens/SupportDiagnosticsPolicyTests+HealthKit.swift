import Foundation
@testable import HealthLog
import Testing

extension SupportDiagnosticsPolicyTests {
    /// No Settings path may write a HealthKit sample or schedule a raw
    /// heart-rate upload, and the support screen contacts no server.
    @Test("no Settings path can write or upload raw heart-rate data")
    func settingsCannotWriteRawHeartRate() throws {
        var violations: [String] = []
        for (path, symbol) in try Self.settingsMutationHits() {
            violations.append("\(path) still exposes the raw-heart-rate mutation symbol `\(symbol)`")
        }
        let support = try Self.strippedSource(Self.supportScreen)
        let mutations = ["HKQuantitySample", "store.save(", "setDesiredMode", "HRUploadMode", "method: .post"]
        for mutation in mutations where support.contains(mutation) {
            violations.append("the support screen names the mutation symbol `\(mutation)`")
        }
        #expect(violations.isEmpty, "Settings can still mutate Health data: \(violations)")
    }

    /// The retirement schedule must survive the surface removal: deleting the
    /// switch must not delete the fail-closed policy behind it.
    @Test("the raw-heart-rate fail-closed flag survives")
    func rawHeartRatePolicyFlagSurvives() throws {
        #expect(
            try Self.strippedSource("HealthLog/App/FeatureFlags.swift")
                .contains("rawHeartRateExperimentAvailable"),
            "the raw-heart-rate feature flag is the fail-closed policy and must survive"
        )
    }
}
