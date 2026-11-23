// Hängt an `AppContainer` (App-Target-only).
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// The HealthKit uploader the app actually builds must lease the signed-in
    /// Keychain account, so a batch never goes out without an owner or under a
    /// successor account's bearer.
    @MainActor
    @Suite("Measurement batch uploader composition", .serialized)
    struct MeasurementBatchUploaderCompositionTests {
        private func makeContainer(keychain: InMemoryKeychain) -> AppContainer {
            AppContainer(
                environment: AppEnvironment(
                    baseURL: URL(string: "https://example.invalid"),
                    bundleID: "dev.healthlog.app.tests",
                    appVersion: "0.0.0-test",
                    buildNumber: "0"
                ),
                keychain: keychain,
                passkey: TestPasskeyService(),
                healthKit: MockHealthKitWriter()
            )
        }

        @Test("without a signed-in account the production uploader refuses to lease")
        func productionUploaderFailsClosedWithoutAccount() async {
            let container = makeContainer(keychain: InMemoryKeychain())

            await #expect(throws: MeasurementUploadAuthenticationLease.ValidationError.self) {
                _ = try await container.healthKitUploader.captureAuthenticationLease()
            }
        }

        @Test("the production uploader leases the Keychain account and goes stale on a switch")
        func productionUploaderLeasesTheKeychainAccount() async throws {
            let keychain = InMemoryKeychain()
            let container = makeContainer(keychain: keychain)
            try keychain.setString("owner-a", forKey: KeychainKey.userID)
            try keychain.setString("bearer-a", forKey: KeychainKey.authToken)

            let lease = try await container.healthKitUploader.captureAuthenticationLease()
            #expect(lease.ownerUserID == "owner-a")
            #expect(lease.authorizationHeader == "Bearer bearer-a")
            try lease.validate()

            try keychain.setString("owner-b", forKey: KeychainKey.userID)
            #expect(throws: MeasurementUploadAuthenticationLease.ValidationError.self) {
                try lease.validate()
            }
        }
    }

#endif
