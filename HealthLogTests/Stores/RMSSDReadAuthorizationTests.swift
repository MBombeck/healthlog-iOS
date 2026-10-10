#if canImport(HealthKit) && !SWIFT_PACKAGE
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// 1.2 / V4 — an existing installation on iOS 27 is asked once, for RMSSD
    /// alone, and only once the server can store it. Older systems are never
    /// asked, and a denial touches nothing else.
    ///
    /// The simulator is iOS 26, so the resolved type is passed in. A stand-in
    /// quantity type plays RMSSD; what is pinned is which set reaches the
    /// sheet, not the type's name.
    @MainActor
    @Suite("HRV RMSSD read request for existing installations")
    struct RMSSDReadAuthorizationTests {
        private static let standIn: HKObjectType = HKQuantityType(.bloodAlcoholContent)

        private struct Harness {
            let store: HKReadinessStore
            let service: StubRMSSDAuthorizationService
            let defaults: UserDefaults
            let user: String
        }

        private static func harness(
            user: String = "returning-user",
            status: HKAuthorizationRequestStatus = .shouldRequest,
            requestedBefore: Bool = true,
            failing: Bool = false
        ) throws -> Harness {
            let defaults = try #require(UserDefaults(suiteName: "hl.tests.v4.rmssd.\(UUID().uuidString)"))
            let keychain = InMemoryKeychain()
            try keychain.setString(user, forKey: KeychainKey.userID)
            try keychain.setString("token-A", forKey: KeychainKey.authToken)
            let service = StubRMSSDAuthorizationService(status: status, failing: failing)
            let store = HKReadinessStore(
                healthKit: service,
                backgroundSync: StubBackgroundSyncCoordinator(),
                keychain: keychain,
                defaults: defaults
            )
            if requestedBefore {
                store.markAuthorizationRequested()
            }
            return Harness(store: store, service: service, defaults: defaults, user: user)
        }

        @Test("older systems: nothing is asked and nothing is recorded")
        func olderSystemIsUntouched() async throws {
            let h = try Self.harness()
            let asked = await h.store.requestRMSSDReadAuthorizationIfNeeded(type: nil, serverAccepts: true)
            #expect(!asked)
            #expect(h.service.requests.isEmpty)
            #expect(h.service.statusQueries == 0)
            #expect(!h.defaults.bool(forKey: HKReadinessStore.rmssdReadRequestedKey(for: h.user)))
        }

        @Test("on this system the public entry asks only where RMSSD resolves")
        func publicEntryFollowsTheSystem() async throws {
            let h = try Self.harness()
            // INT-N: the store's own defaults, not `.standard`, which V1's
            // `manual` tests now share through the same server version record.
            HealthKitServerTypeGate.record(ServerVersionInfo(version: "1.42.0"), defaults: h.defaults)
            let asked = await h.store.requestRMSSDReadAuthorizationIfNeeded()
            #expect(asked == (HeartRateVariabilityRMSSD.sampleType != nil))
            if HeartRateVariabilityRMSSD.sampleType == nil {
                #expect(h.service.requests.isEmpty)
            }
        }

        @Test("a returning user on iOS 27 gets one sheet with RMSSD alone, once")
        func returningUserIsAskedOnce() async throws {
            let h = try Self.harness()
            #expect(await h.store.requestRMSSDReadAuthorizationIfNeeded(type: Self.standIn, serverAccepts: true))
            #expect(h.service.requests.count == 1)
            #expect(h.service.requests.first?.read == [Self.standIn])
            #expect(h.service.requests.first?.write.isEmpty == true)
            #expect(h.defaults.bool(forKey: HKReadinessStore.rmssdReadRequestedKey(for: h.user)))

            // The next launch does not ask again, whatever the system says.
            #expect(await !(h.store.requestRMSSDReadAuthorizationIfNeeded(type: Self.standIn, serverAccepts: true)))
            #expect(h.service.requests.count == 1)
        }

        @Test("a server before v1.42 defers the question without using it up")
        func oldServerDefers() async throws {
            let h = try Self.harness()
            #expect(await !(h.store.requestRMSSDReadAuthorizationIfNeeded(type: Self.standIn, serverAccepts: false)))
            #expect(h.service.requests.isEmpty)
            #expect(!h.defaults.bool(forKey: HKReadinessStore.rmssdReadRequestedKey(for: h.user)))
            // After the upgrade the same installation is asked.
            #expect(await h.store.requestRMSSDReadAuthorizationIfNeeded(type: Self.standIn, serverAccepts: true))
            #expect(h.service.requests.count == 1)
        }

        @Test("an already answered sheet (granted or denied) is never shown again")
        func answeredSheetIsNotShown() async throws {
            let h = try Self.harness(status: .unnecessary)
            #expect(await !(h.store.requestRMSSDReadAuthorizationIfNeeded(type: Self.standIn, serverAccepts: true)))
            #expect(h.service.requests.isEmpty)
            #expect(h.defaults.bool(forKey: HKReadinessStore.rmssdReadRequestedKey(for: h.user)))
        }

        @Test("a status the system cannot give asks nothing and retries later")
        func unknownStatusAsksNothing() async throws {
            let h = try Self.harness(status: .unknown)
            #expect(await !(h.store.requestRMSSDReadAuthorizationIfNeeded(type: Self.standIn, serverAccepts: true)))
            #expect(h.service.requests.isEmpty)
            #expect(!h.defaults.bool(forKey: HKReadinessStore.rmssdReadRequestedKey(for: h.user)))
        }

        @Test("a user who never saw the sheet gets RMSSD in onboarding instead")
        func newUserIsNotAskedHere() async throws {
            let h = try Self.harness(user: "new-user", requestedBefore: false)
            #expect(await !(h.store.requestRMSSDReadAuthorizationIfNeeded(type: Self.standIn, serverAccepts: true)))
            #expect(h.service.requests.isEmpty)
            #expect(h.defaults.bool(forKey: HKReadinessStore.rmssdReadRequestedKey(for: "new-user")))
        }

        @Test("a failed request is not recorded, and the flag is per user and cleared with the user")
        func failureAndPartitioning() async throws {
            let h = try Self.harness(failing: true)
            #expect(await !(h.store.requestRMSSDReadAuthorizationIfNeeded(type: Self.standIn, serverAccepts: true)))
            #expect(h.service.requests.count == 1)
            #expect(!h.defaults.bool(forKey: HKReadinessStore.rmssdReadRequestedKey(for: h.user)))

            h.defaults.set(true, forKey: HKReadinessStore.rmssdReadRequestedKey(for: "alice"))
            #expect(!h.defaults.bool(forKey: HKReadinessStore.rmssdReadRequestedKey(for: "bob")))
            HKReadinessStore.clearPersisted(for: "alice", in: h.defaults)
            #expect(!h.defaults.bool(forKey: HKReadinessStore.rmssdReadRequestedKey(for: "alice")))
        }
    }

    /// Records what reaches the sheet and answers a fixed request status.
    final class StubRMSSDAuthorizationService: HealthKitServiceProtocol, @unchecked Sendable {
        struct Request {
            let read: Set<HKObjectType>
            let write: Set<HKSampleType>
        }

        private struct Failure: Error {}

        private let lock = NSLock()
        private let status: HKAuthorizationRequestStatus
        private let failing: Bool
        private var _requests: [Request] = []
        private var _statusQueries = 0

        init(status: HKAuthorizationRequestStatus, failing: Bool) {
            self.status = status
            self.failing = failing
        }

        var requests: [Request] {
            lock.withLock { _requests }
        }

        var statusQueries: Int {
            lock.withLock { _statusQueries }
        }

        func isAvailable() -> Bool {
            true
        }

        func authorizationStatus(for _: HKObjectType) -> HKAuthorizationStatus {
            .notDetermined
        }

        func authorizationStatuses(for _: Set<HKSampleType>) -> [String: HKReadinessStore.AuthStatus] {
            [:]
        }

        func authorizationRequestStatus(
            toShare _: Set<HKSampleType>,
            read _: Set<HKObjectType>
        ) async -> HKAuthorizationRequestStatus {
            lock.withLock { _statusQueries += 1 }
            return status
        }

        func requestAuthorization(read: Set<HKObjectType>, write: Set<HKSampleType>) async throws {
            lock.withLock { _requests.append(Request(read: read, write: write)) }
            if failing { throw Failure() }
        }

        func resetAuthDisabledTypes() async {}
        func defaultReadTypes() -> Set<HKObjectType> {
            []
        }

        func defaultWriteTypes() -> Set<HKSampleType> {
            []
        }

        func writeMeasurement(_: HealthLog.Measurement) async throws {}
        func writeMoodEntry(_: MoodEntry) async throws {}
        func startBackgroundDeliveries() async throws {}

        func write(_: HealthLog.Measurement) async throws {}
        func writeMood(_: MoodEntry) async throws {}
        func deleteMood(id _: String) async throws {}
        func requestMoodAuthorization() async throws {}
        func startMoodImport(repo _: MoodRepository, userID _: String?) async {}
        func stopMoodImport() async {}
        func resetMoodImport() async {}
        func activateBackgroundDeliveries() async throws {}
        func runBackgroundSyncPass() async {}
        func attachUploader(_: MeasurementBatchUploader) async {}
        func attachDeletionReconciler(_: MeasurementDeletionReconciler) async {}
        func setInitialBackfillCutoff(_: Date?) async {}
        func attachFeatureFlags(_: (any FeatureFlagsServicing)?) async {}
    }
#endif
