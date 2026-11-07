#if canImport(HealthKit) && !SWIFT_PACKAGE
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// **HK-NEW (1.5) — (b) the update path from 1.4.1.**
    ///
    /// An installation that answered the HealthKit sheet in 1.4.1 has never
    /// been asked for exercise and stand minutes, stand hours, mindful sessions
    /// or AFib burden. It must not meet a system sheet out of nowhere: the
    /// foreground path leaves these types alone, the dashboard card explains
    /// them, and "Continue" asks exactly once, in one sheet, for exactly the
    /// five. "Not now" is final for the card; the settings link stays a way
    /// back while iOS still calls the types unanswered.
    @MainActor
    @Suite("HK-NEW — new read types for installations updated from 1.4.1")
    struct Server144ReadAuthorizationTests {
        private struct Harness {
            let store: HKReadinessStore
            let service: StubRMSSDAuthorizationService
            let defaults: UserDefaults
            let user: String
        }

        private static var five: Set<HKObjectType> {
            Set(HealthKitServer144Types.lateReadIdentifiers.compactMap(HealthKitServer144Types.readType(for:)))
        }

        /// A 1.4.1 installation: the first sheet answered, RMSSD and waist
        /// asked before, and a server at `version`.
        private static func harness141(
            version: String? = "1.47.0",
            status: HKAuthorizationRequestStatus = .shouldRequest,
            requestedBefore: Bool = true
        ) throws -> Harness {
            let defaults = try #require(UserDefaults(suiteName: "hl.tests.hknew.lateread.\(UUID().uuidString)"))
            let keychain = InMemoryKeychain()
            let user = "updated-from-141"
            try keychain.setString(user, forKey: KeychainKey.userID)
            try keychain.setString("token-A", forKey: KeychainKey.authToken)
            let service = StubRMSSDAuthorizationService(status: status, failing: false)
            let store = HKReadinessStore(
                healthKit: service,
                backgroundSync: StubBackgroundSyncCoordinator(),
                keychain: keychain,
                defaults: defaults
            )
            if requestedBefore {
                store.markAuthorizationRequested()
                defaults.set(true, forKey: HKReadinessStore.rmssdReadRequestedKey(for: user))
                defaults.set(true, forKey: HKReadinessStore.waistReadRequestedKey(for: user))
            }
            if let version {
                HealthKitServerTypeGate.record(ServerVersionInfo(version: version), defaults: defaults)
            }
            return Harness(store: store, service: service, defaults: defaults, user: user)
        }

        @Test("the five resolve on this system and are the announced late types")
        func fiveAnnounced() throws {
            #expect(Self.five.count == 5)
            let h = try Self.harness141()
            let announced = h.store.lateReadTypes().filter(\.announced)
            #expect(Set(announced.compactMap(\.type)) == Self.five)
            #expect(!announced.map(\.serverAccepts).contains(false))
            #expect(h.store.lateReadTypes().filter { !$0.announced }.count == 2) // RMSSD, waist
        }

        @Test("the foreground after the update opens no system sheet")
        func foregroundAsksNothing() async throws {
            let h = try Self.harness141()
            #expect(await !(h.store.requestLateReadAuthorizationIfNeeded()))
            #expect(h.service.requests.isEmpty)
        }

        @Test("the card lists the five; Continue asks once, in one read-only sheet, and never again")
        func continueAsksExactlyOnce() async throws {
            let h = try Self.harness141()
            #expect(await h.store.pendingAnnouncedReadTypes() == HealthKitServer144Types.lateReadIdentifiers)

            #expect(await h.store.requestAnnouncedReadAuthorization())
            #expect(h.service.requests.count == 1)
            #expect(h.service.requests.first?.read == Self.five)
            #expect(h.service.requests.first?.write.isEmpty == true)

            // Granted or declined in the sheet: the card is gone and nothing asks again.
            #expect(await h.store.pendingAnnouncedReadTypes().isEmpty)
            #expect(await !(h.store.requestAnnouncedReadAuthorization()))
            #expect(await !(h.store.requestLateReadAuthorizationIfNeeded()))
            #expect(h.service.requests.count == 1)
        }

        @Test("Not now: no sheet, the card stays away, the settings link still offers the five")
        func notNow() async throws {
            let h = try Self.harness141()
            await h.store.declineAnnouncedReadTypes()
            #expect(h.service.requests.isEmpty)
            #expect(await h.store.pendingAnnouncedReadTypes().isEmpty)
            #expect(await h.store.pendingAnnouncedReadTypes(ignoringFlags: true) == HealthKitServer144Types.lateReadIdentifiers)

            #expect(await h.store.requestAnnouncedReadAuthorization(ignoringFlags: true))
            #expect(h.service.requests.count == 1)
            #expect(h.service.requests.first?.read == Self.five)
        }

        @Test("a sheet iOS already calls answered: no card, no link, nothing asked")
        func answeredInIOS() async throws {
            let h = try Self.harness141(status: .unnecessary)
            #expect(await h.store.pendingAnnouncedReadTypes().isEmpty)
            #expect(await h.store.pendingAnnouncedReadTypes(ignoringFlags: true).isEmpty)
            #expect(h.service.requests.isEmpty)
        }

        @Test("server 1.43 or unknown: nothing is announced or asked")
        func oldServerAsksNothing() async throws {
            for version in [nil, "1.43.10"] {
                let h = try Self.harness141(version: version)
                #expect(await h.store.pendingAnnouncedReadTypes().isEmpty)
                #expect(await h.store.pendingAnnouncedReadTypes(ignoringFlags: true).isEmpty)
                #expect(await !(h.store.requestAnnouncedReadAuthorization()))
                #expect(h.service.requests.isEmpty)
            }
        }

        @Test("acceptedTypes without AFib burden: the card names and asks only the other four")
        func acceptedTypesNarrowTheSheet() async throws {
            let h = try Self.harness141()
            HealthKitAcceptedTypes.record(
                HealthKitServer144Types.lateReadIdentifiers.filter { $0 != HealthKitServer144Types.afibBurden },
                defaults: h.defaults
            )
            let pending = await h.store.pendingAnnouncedReadTypes()
            #expect(pending.count == 4)
            #expect(!pending.contains(HealthKitServer144Types.afibBurden))
        }

        @Test("a new install gets them in onboarding: no card, the flags are set without asking")
        func newInstall() async throws {
            let h = try Self.harness141(requestedBefore: false)
            #expect(await h.store.pendingAnnouncedReadTypes().isEmpty)
            #expect(h.service.requests.isEmpty)
            for identifier in HealthKitServer144Types.lateReadIdentifiers {
                let key = HKReadinessStore.announcedReadRequestedKeyPrefix(for: identifier)
                    + HKReadinessStore.partitionToken(for: h.user)
                #expect(h.defaults.bool(forKey: key))
            }
        }

        @Test("the flags go with the user on sign-out")
        func flagsClearedWithUser() async throws {
            let h = try Self.harness141()
            await h.store.declineAnnouncedReadTypes()
            HKReadinessStore.clearPersisted(for: h.user, in: h.defaults)
            for identifier in HealthKitServer144Types.lateReadIdentifiers {
                let key = HKReadinessStore.announcedReadRequestedKeyPrefix(for: identifier)
                    + HKReadinessStore.partitionToken(for: h.user)
                #expect(!h.defaults.bool(forKey: key))
            }
        }

        @Test("the card text names the types with the permission list's names")
        func cardText() {
            let text = HealthKitNewReadTypesCard.body(for: HealthKitServer144Types.lateReadIdentifiers)
            for identifier in HealthKitServer144Types.lateReadIdentifiers {
                #expect(text.contains(HealthAccessTypeNaming.displayName(for: identifier)), "\(identifier)")
            }
            #expect(!text.contains("HKQuantityTypeIdentifier"))
        }
    }
#endif
