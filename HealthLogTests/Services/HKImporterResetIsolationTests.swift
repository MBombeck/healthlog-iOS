import Foundation
@testable import HealthLog
import Testing
#if canImport(HealthKit)
    import HealthKit
#endif

// swiftlint:disable force_unwrapping

#if canImport(HealthKit)

    /// **Audit M4 — logout-race invariant.**
    ///
    /// `AuthStore.handleUnauthorized()` wipes `KeychainKey.userID` and dispatches
    /// the HK-anchor cleanup via `Task.detached`, so the importers' `resetAnchor`
    /// paths can run AFTER the keychain id is already gone. This is only safe
    /// because each importer captures its anchor key/prefix at `init` from the
    /// user-id it was built for, and `resetAnchor()` clears exactly that cached
    /// key — it must never re-resolve `KeychainKey.userID` (which would resolve
    /// to the `_anonymous` partition and clear the WRONG key, stranding the
    /// previous user's anchor).
    ///
    /// These tests pin that invariant by seeding the *pre-wipe* partition key
    /// plus a sentinel `_anonymous`-partition key, then calling reset and
    /// asserting only the pre-wipe key was cleared — the behaviour a re-read
    /// would get wrong.
    ///
    /// Strict-concurrency note: each `UserDefaults` handle is touched by exactly
    /// one isolation domain. The importer (an `actor`) gets its OWN handle from
    /// the suite name; seeding + assertions use SEPARATE handles to the same
    /// suite, so no non-`Sendable` `UserDefaults` instance is both sent across
    /// the actor boundary and used afterwards.
    @Suite("HealthKit importer reset — pre-wipe partition isolation (M4)", .serialized)
    struct HKImporterResetIsolationTests {
        private static let userA = "user-A-12345"

        private func makeAPI() -> APIClient {
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.14.8",
                buildNumber: "1"
            )
            return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        }

        /// Unique suite name per case so seeded keys never leak across tests.
        private func freshSuiteName(_ name: String) -> String {
            "hk-importer-reset-\(name)-\(UUID().uuidString)"
        }

        private func seed(suite: String, userAKey: String, anonKey: String) {
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            defaults.set(Data([0x1]), forKey: userAKey)
            defaults.set(Data([0x2]), forKey: anonKey) // what a keychain re-read would target post-wipe
        }

        private var partitionA: String {
            HealthKitService.partitionToken(for: Self.userA)
        }

        private var partitionAnon: String {
            HealthKitService.partitionToken(for: nil)
        }

        @Test("Workout reset clears the pre-wipe partition key, not the anonymous one")
        func workoutResetUsesCachedPartition() async throws {
            let suite = freshSuiteName("workout")
            let userAKey = "hl.workout.hk.anchor." + partitionA
            let anonKey = "hl.workout.hk.anchor." + partitionAnon
            seed(suite: suite, userAKey: userAKey, anonKey: anonKey)

            let importer = try WorkoutHealthKitImporter(
                store: HKHealthStore(),
                repo: WorkoutsRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true)),
                userID: Self.userA,
                defaults: #require(UserDefaults(suiteName: suite))
            )
            await importer.resetAnchor()

            // The cached (pre-wipe) partition key is gone; the anonymous key —
            // which a re-read of the wiped keychain id would have cleared —
            // survives, proving reset did not re-resolve KeychainKey.userID.
            let check = try #require(UserDefaults(suiteName: suite))
            #expect(check.data(forKey: userAKey) == nil)
            #expect(check.data(forKey: anonKey) != nil)
            #expect(partitionA != partitionAnon)
        }

        @Test("Mood reset clears the pre-wipe partition key, not the anonymous one")
        func moodResetUsesCachedPartition() async throws {
            let suite = freshSuiteName("mood")
            let userAKey = "hl.mood.stateOfMind.anchor." + partitionA
            let anonKey = "hl.mood.stateOfMind.anchor." + partitionAnon
            seed(suite: suite, userAKey: userAKey, anonKey: anonKey)

            let importer = try MoodStateOfMindImporter(
                store: HKHealthStore(),
                repo: MoodRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true)),
                userID: Self.userA,
                defaults: #require(UserDefaults(suiteName: suite))
            )
            await importer.resetAnchor()

            let check = try #require(UserDefaults(suiteName: suite))
            #expect(check.data(forKey: userAKey) == nil)
            #expect(check.data(forKey: anonKey) != nil)
        }

        @Test("Cycle reset clears the pre-wipe partition keys, not the anonymous ones")
        func cycleResetUsesCachedPartition() async throws {
            let suite = freshSuiteName("cycle")
            // Cycle keys are per category type: prefix + type.identifier.
            let type = CycleHealthKitMapping.menstrualFlow
            let userAKey = "hl.cycle.hk.anchor." + partitionA + "." + type
            let anonKey = "hl.cycle.hk.anchor." + partitionAnon + "." + type
            seed(suite: suite, userAKey: userAKey, anonKey: anonKey)

            let importer = try CycleHealthKitImporter(
                store: HKHealthStore(),
                repo: CycleRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true)),
                userID: Self.userA,
                defaults: #require(UserDefaults(suiteName: suite))
            )
            await importer.resetAnchors()

            let check = try #require(UserDefaults(suiteName: suite))
            #expect(check.data(forKey: userAKey) == nil)
            #expect(check.data(forKey: anonKey) != nil)
        }
    }

#endif
