// Hängt an `AppContainer` (App-Target-only).
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// #113 — the skip register holds health values of the signed-in account;
    /// every logout reason removes them, like every other account-bound store.
    @MainActor
    @Suite("Skip register logout wipe (#113)", .serialized)
    struct SkipRegisterLogoutWipeTests {
        @Test(
            "performFullLocalLogout empties the skip register for every reason",
            arguments: [LogoutReason.userInitiated, .tokenExpired, .accountDeleted, .switchServer]
        )
        func logoutEmptiesTheRegister(reason: LogoutReason) async throws {
            let container = AppContainer(
                environment: AppEnvironment(
                    baseURL: URL(string: "https://example.invalid"),
                    bundleID: "dev.healthlog.app.tests",
                    appVersion: "0.0.0-test",
                    buildNumber: "0"
                ),
                keychain: InMemoryKeychain(),
                passkey: TestPasskeyService(),
                healthKit: MockHealthKitWriter()
            )
            let entry = HealthKitBatchEntryDTO(
                hkIdentifier: "HKQuantityTypeIdentifierOxygenSaturation",
                value: 0.97,
                unit: "%",
                startDate: Date(timeIntervalSince1970: 1_726_300_800),
                endDate: Date(timeIntervalSince1970: 1_726_300_800),
                externalId: "logout-wipe-\(reason)"
            )
            // INT-A — nutrient refusals live in the same register and go too.
            let nutrient = NutrientIntakeEntryDTO(day: "2026-09-14", nutrient: .zinc, unit: "mg", amount: 999_999)
            try await HealthKitSkippedRowRegister.shared.record(
                [
                    HealthKitSkippedEntry(entry: entry, reason: "value_out_of_range"),
                    HealthKitSkippedEntry(nutrient: nutrient, reason: "value_out_of_range")
                ],
                ownerID: "account-a",
                build: "0"
            )
            #expect(await HealthKitSkippedRowRegister.shared.count(ownerID: "account-a") >= 2)

            await container.performFullLocalLogout(reason: reason)

            #expect(await HealthKitSkippedRowRegister.shared.count(ownerID: "account-a") == 0)
        }
    }

#endif
