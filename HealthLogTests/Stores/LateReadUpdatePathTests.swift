#if canImport(HealthKit) && !SWIFT_PACKAGE
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// The update path for the announced read types (the five server-v1.44
    /// types and resting energy), from the state an existing installation
    /// really has on disk.
    ///
    /// The store is built after the defaults are written, exactly like a cold
    /// start after the update. A 1.4 install must be offered the five (card
    /// and settings link); an install whose flags were set without a question
    /// before must be offered them again; and someone whose sheet iOS already
    /// calls answered is never asked a second time.
    @MainActor
    @Suite("Late read types: the update path from an existing installation")
    struct LateReadUpdatePathTests {
        private struct Harness {
            let store: HKReadinessStore
            let service: StubRMSSDAuthorizationService
            let defaults: UserDefaults
            let user: String
        }

        private static let user = "usr_existing14"

        private static var five: Set<HKObjectType> {
            Set(HealthKitBasalEnergy.announcedLateReadIdentifiers.compactMap(HealthKitServer144Types.readType(for:)))
        }

        /// The defaults a 1.4.x installation leaves behind (variants by
        /// parameter), then a fresh store on top of them.
        private static func installation(
            requestedAt: Bool = true,
            lastSynced: Bool = true,
            legacyAnnouncedFlags: Bool = false,
            status: HKAuthorizationRequestStatus = .shouldRequest
        ) throws -> Harness {
            let defaults = try #require(UserDefaults(suiteName: "hl.tests.lateread.update.\(UUID().uuidString)"))
            let keychain = InMemoryKeychain()
            try keychain.setString(user, forKey: KeychainKey.userID)
            try keychain.setString("token-A", forKey: KeychainKey.authToken)
            if requestedAt {
                defaults.set(true, forKey: HKReadinessStore.requestedKey(for: user))
            }
            if lastSynced {
                defaults.set(1_760_000_000.0, forKey: HKReadinessStore.lastSyncedKey(for: user))
            }
            defaults.set(true, forKey: HKReadinessStore.rmssdReadRequestedKey(for: user))
            defaults.set(true, forKey: HKReadinessStore.waistReadRequestedKey(for: user))
            if legacyAnnouncedFlags {
                for identifier in HealthKitBasalEnergy.announcedLateReadIdentifiers {
                    defaults.set(true, forKey: legacyKey(identifier))
                }
            }
            HealthKitServerTypeGate.record(ServerVersionInfo(version: "1.47.6"), defaults: defaults)
            let service = StubRMSSDAuthorizationService(status: status, failing: false)
            let store = HKReadinessStore(
                healthKit: service,
                backgroundSync: StubBackgroundSyncCoordinator(),
                keychain: keychain,
                defaults: defaults
            )
            return Harness(store: store, service: service, defaults: defaults, user: user)
        }

        private static func key(_ identifier: String) -> String {
            HKReadinessStore.announcedReadRequestedKeyPrefix(for: identifier) + HKReadinessStore.partitionToken(for: user)
        }

        private static func legacyKey(_ identifier: String) -> String {
            HKReadinessStore.legacyAnnouncedReadRequestedKeyPrefix(for: identifier)
                + HKReadinessStore.partitionToken(for: user)
        }

        private static func anyFlagSet(in defaults: UserDefaults) -> Bool {
            HealthKitBasalEnergy.announcedLateReadIdentifiers.contains { defaults.bool(forKey: key($0)) }
        }

        @Test("a 1.4 install: card and settings link offer the five, the foreground opens nothing")
        func fromOnePointFour() async throws {
            let h = try Self.installation()
            #expect(await !(h.store.requestLateReadAuthorizationIfNeeded()))
            #expect(h.service.requests.isEmpty)
            #expect(await h.store.pendingAnnouncedReadTypes() == HealthKitBasalEnergy.announcedLateReadIdentifiers)
            #expect(await h.store.pendingAnnouncedReadTypes(ignoringFlags: true) == HealthKitBasalEnergy.announcedLateReadIdentifiers)

            #expect(await h.store.requestAnnouncedReadAuthorization())
            #expect(h.service.requests.count == 1)
            #expect(h.service.requests.first?.read == Self.five)
            #expect(h.service.requests.first?.write.isEmpty == true)
        }

        @Test("flags set without a question before (1.5, 1.6): the card comes back once")
        func silentlyFlaggedInstallIsOfferedAgain() async throws {
            let h = try Self.installation(legacyAnnouncedFlags: true)
            #expect(await h.store.pendingAnnouncedReadTypes() == HealthKitBasalEnergy.announcedLateReadIdentifiers)
            #expect(await h.store.requestAnnouncedReadAuthorization())
            #expect(h.service.requests.count == 1)
            #expect(await h.store.pendingAnnouncedReadTypes().isEmpty)
        }

        @Test("answered in an earlier version: iOS says so, no card, no link, nothing asked")
        func answeredBeforeIsNotAskedTwice() async throws {
            let h = try Self.installation(legacyAnnouncedFlags: true, status: .unnecessary)
            #expect(await h.store.pendingAnnouncedReadTypes().isEmpty)
            #expect(await h.store.pendingAnnouncedReadTypes(ignoringFlags: true).isEmpty)
            #expect(await !(h.store.requestAnnouncedReadAuthorization()))
            #expect(h.service.requests.isEmpty)
            // Recorded from the system's answer, so the card stays away for good.
            for identifier in HealthKitBasalEnergy.announcedLateReadIdentifiers {
                #expect(h.defaults.bool(forKey: Self.key(identifier)))
            }
        }

        @Test("requestedAt lost but data reached the server: still offered, no flag set silently")
        func lostRequestedAtWithSyncedData() async throws {
            let h = try Self.installation(requestedAt: false)
            #expect(await h.store.pendingAnnouncedReadTypes() == HealthKitBasalEnergy.announcedLateReadIdentifiers)
            #expect(await h.store.pendingAnnouncedReadTypes(ignoringFlags: true) == HealthKitBasalEnergy.announcedLateReadIdentifiers)
            #expect(!Self.anyFlagSet(in: h.defaults))
            #expect(h.service.requests.isEmpty)
        }

        @Test("a moment without requestedAt sets no flag, so the card appears once it is back")
        func noRequestedAtYetDoesNotUseTheCardUp() async throws {
            let h = try Self.installation(requestedAt: false, lastSynced: false)
            #expect(await h.store.pendingAnnouncedReadTypes().isEmpty)
            #expect(await h.store.pendingAnnouncedReadTypes(ignoringFlags: true).isEmpty)
            #expect(!Self.anyFlagSet(in: h.defaults))
            #expect(h.service.requests.isEmpty)

            // `refresh()` restores it from a granted write type on the next pass.
            h.store.markAuthorizationRequested()
            #expect(await h.store.pendingAnnouncedReadTypes() == HealthKitBasalEnergy.announcedLateReadIdentifiers)
        }

        @Test("iOS cannot tell: card and link still offer the five, the foreground asks nothing")
        func unknownStatusStillOffers() async throws {
            let h = try Self.installation(status: .unknown)
            #expect(await !(h.store.requestLateReadAuthorizationIfNeeded()))
            #expect(h.service.requests.isEmpty)
            #expect(await h.store.pendingAnnouncedReadTypes() == HealthKitBasalEnergy.announcedLateReadIdentifiers)
            #expect(await h.store.pendingAnnouncedReadTypes(ignoringFlags: true) == HealthKitBasalEnergy.announcedLateReadIdentifiers)
            #expect(!Self.anyFlagSet(in: h.defaults))
        }

        @Test("sign-out clears the current and the old flags")
        func signOutClearsBothKeys() async throws {
            let h = try Self.installation(legacyAnnouncedFlags: true)
            await h.store.declineAnnouncedReadTypes()
            #expect(Self.anyFlagSet(in: h.defaults))
            HKReadinessStore.clearPersisted(for: h.user, in: h.defaults)
            for identifier in HealthKitBasalEnergy.announcedLateReadIdentifiers {
                #expect(!h.defaults.bool(forKey: Self.key(identifier)))
                #expect(!h.defaults.bool(forKey: Self.legacyKey(identifier)))
            }
        }
    }
#endif
