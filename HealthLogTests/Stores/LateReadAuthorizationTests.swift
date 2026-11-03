#if canImport(HealthKit) && !SWIFT_PACKAGE
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// **B5 (1.4) — waist circumference for installations that already
    /// answered the first sheet.**
    ///
    /// The type joins the read set in 1.4. A new install gets it in the
    /// onboarding sheet; an existing one is asked once, in one sheet together
    /// with any other open late type, with a flag of its own. Someone who
    /// already answered the RMSSD request (1.2) is still asked once for waist;
    /// a declined request never comes back.
    @MainActor
    @Suite("B5 — late read types (waist) for existing installations")
    struct LateReadAuthorizationTests {
        private static let waist: HKObjectType = HKQuantityType(.waistCircumference)
        /// Plays RMSSD on an iOS 26 simulator.
        private static let rmssdStandIn: HKObjectType = HKQuantityType(.bloodAlcoholContent)

        private struct Harness {
            let store: HKReadinessStore
            let service: StubRMSSDAuthorizationService
            let defaults: UserDefaults
            let user: String
        }

        private static func harness(status: HKAuthorizationRequestStatus = .shouldRequest) throws -> Harness {
            let defaults = try #require(UserDefaults(suiteName: "hl.tests.b5.lateread.\(UUID().uuidString)"))
            let keychain = InMemoryKeychain()
            let user = "returning-user"
            try keychain.setString(user, forKey: KeychainKey.userID)
            try keychain.setString("token-A", forKey: KeychainKey.authToken)
            let service = StubRMSSDAuthorizationService(status: status, failing: false)
            let store = HKReadinessStore(
                healthKit: service,
                backgroundSync: StubBackgroundSyncCoordinator(),
                keychain: keychain,
                defaults: defaults
            )
            store.markAuthorizationRequested()
            return Harness(store: store, service: service, defaults: defaults, user: user)
        }

        @Test("waist is one of the late read types, stored by every supported server")
        func waistIsALateType() throws {
            let h = try Self.harness()
            let waist = try #require(h.store.lateReadTypes().first { $0.type == Self.waist })
            #expect(waist.flagPrefix == HKReadinessStore.waistReadRequestedKeyPrefix)
            #expect(waist.serverAccepts)
        }

        @Test("a user who already answered the RMSSD request is asked once for waist alone")
        func rmssdAnsweredStillAsksWaist() async throws {
            let h = try Self.harness()
            h.defaults.set(true, forKey: HKReadinessStore.rmssdReadRequestedKey(for: h.user))

            #expect(await h.store.requestLateReadAuthorizationIfNeeded())
            #expect(h.service.requests.count == 1)
            #expect(h.service.requests.first?.read == [Self.waist])
            #expect(h.service.requests.first?.write.isEmpty == true)
            #expect(h.defaults.bool(forKey: HKReadinessStore.waistReadRequestedKey(for: h.user)))

            // Declined or granted, the next launch asks nothing.
            #expect(await !(h.store.requestLateReadAuthorizationIfNeeded()))
            #expect(h.service.requests.count == 1)
        }

        @Test("two open late types share one sheet, and both flags are set")
        func openTypesShareOneSheet() async throws {
            let h = try Self.harness()
            let asked = await h.store.requestLateReadAuthorizationIfNeeded([
                .init(type: Self.rmssdStandIn, flagPrefix: HKReadinessStore.rmssdReadRequestedKeyPrefix, serverAccepts: true),
                .init(type: Self.waist, flagPrefix: HKReadinessStore.waistReadRequestedKeyPrefix, serverAccepts: true)
            ])
            #expect(asked)
            #expect(h.service.requests.count == 1)
            #expect(h.service.requests.first?.read == [Self.rmssdStandIn, Self.waist])
            #expect(h.defaults.bool(forKey: HKReadinessStore.rmssdReadRequestedKey(for: h.user)))
            #expect(h.defaults.bool(forKey: HKReadinessStore.waistReadRequestedKey(for: h.user)))
        }

        @Test("an answered waist sheet is recorded without asking, and the flag goes with the user")
        func answeredAndCleared() async throws {
            let h = try Self.harness(status: .unnecessary)
            #expect(await !(h.store.requestLateReadAuthorizationIfNeeded()))
            #expect(h.service.requests.isEmpty)
            #expect(h.defaults.bool(forKey: HKReadinessStore.waistReadRequestedKey(for: h.user)))

            HKReadinessStore.clearPersisted(for: h.user, in: h.defaults)
            #expect(!h.defaults.bool(forKey: HKReadinessStore.waistReadRequestedKey(for: h.user)))
        }
    }
#endif
