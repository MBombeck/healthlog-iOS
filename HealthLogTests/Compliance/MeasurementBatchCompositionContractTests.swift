import Foundation
import Testing

@Suite("Measurement batch production composition")
struct MeasurementBatchCompositionContractTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Phase 07 Wave 2 moved two of these assertions, and did not weaken them.
    ///
    /// `captureAuthenticationLeaseIfConfigured()` and the lease hand-off used to
    /// sit inline in `HealthLogStandard.handleNewSamples`. They now sit in
    /// `HealthSampleConsumption`, the `Sendable` operation the Standard and the
    /// app-owned `AnchoredHealthSampleCollector` both call — so the account-bound
    /// upload is asserted where it lives, and it now covers both paths rather than
    /// only the Spezi callback. The Standard keeps the assertion that is genuinely
    /// its own (an observation arriving before composition waits rather than being
    /// dropped) and gains the Phase-07 one: it decides nothing about a cursor on
    /// its own, it asks the installed commit rule.
    @Test("production HealthKit uploader is account leased and fail closed")
    func productionUploaderWiringIsAccountBound() throws {
        let composition = try source("HealthLog/Stores/AppContainer+HealthKitLifecycle.swift")
        #expect(composition.contains("authenticationSnapshot:"))
        #expect(composition.contains("KeychainKey.userID"))
        #expect(composition.contains("KeychainKey.authToken"))

        let consumption = try source("HealthLog/Services/HealthKit/HealthSampleConsumption.swift")
        #expect(consumption.contains("captureAuthenticationLeaseIfConfigured()"))
        #expect(consumption.contains("requiring: authenticationLease"))

        let standard = try source("HealthLog/Services/HealthKit/HealthLogStandard.swift")
        #expect(standard.contains("uploaderWaiters.append(continuation)"))
        #expect(standard.contains("HealthSyncCursorPolicy.installed"))

        let uploader = try source("HealthLog/Repositories/MeasurementBatchUploader.swift")
        #expect(uploader.contains("[\"Authorization\": $0.authorizationHeader]"))
        #expect(uploader.contains("maxRetries: authLease == nil ? base.maxRetries : 0"))
        #expect(uploader.contains("allowsAuthenticationRecovery: authLease == nil"))
        #expect(uploader.contains("try MeasurementBatchAcceptance.validate"))
    }
}
