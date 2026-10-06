// #10 — "Settings > Apple Health" showed "Not synced yet" forever.
//
// `MeasurementBatchUploader.setSuccessNotifier(_:)` existed, was documented as
// "set by the composition root" and was unit-tested with an injected closure;
// `HKReadinessStore.noteSuccessfulSync(at:)` existed and was unit-tested by
// calling it directly. Nothing in the app connected the two, so both halves
// were green and the caption never moved. These suites pin the connection:
// the REAL container, the REAL uploader, the REAL APIClient over a
// session-scoped mock transport.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @MainActor
    @Suite("#10 — the composition root wires the sync stamp", .serialized, .mockURLSession)
    struct HealthKitSyncStampWiringTests {
        private static let owner = "user-m1"

        private static let entry = HealthKitBatchEntryDTO(
            hkIdentifier: "HKQuantityTypeIdentifierBodyMass",
            value: 81.0,
            unit: "kg",
            startDate: Date(timeIntervalSince1970: 1_758_960_000),
            endDate: Date(timeIntervalSince1970: 1_758_960_000),
            externalId: "hk:m1-sample-1"
        )

        private nonisolated static let acceptedBody = Data(
            #"""
            {"data":{"processed":1,"inserted":1,"duplicates":0,"skipped":[],
            "entries":[{"index":0,"status":"inserted"}]},"error":null}
            """#.utf8
        )

        /// Every other request the live container makes on its own (probes,
        /// prefetches) gets a plain 404, never a 401 that could log it out.
        private nonisolated static func respond(_ request: URLRequest) -> (HTTPURLResponse, Data?) {
            if request.httpMethod == "POST", request.url?.path == "/api/measurements/batch" {
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    acceptedBody
                )
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null,"error":"not found"}"#.utf8)
            )
        }

        private func makeSignedInContainer() throws -> AppContainer {
            MockURLProtocol.install(Self.respond)
            let keychain = InMemoryKeychain()
            try keychain.setString(Self.owner, forKey: KeychainKey.userID)
            try keychain.setString("token-m1", forKey: KeychainKey.authToken)
            let container = AppContainer(
                environment: AppEnvironment(
                    baseURL: URL(string: "https://test.healthlog.local"),
                    bundleID: "dev.healthlog.app.tests",
                    appVersion: "0.0.0-test",
                    buildNumber: "0"
                ),
                keychain: keychain,
                passkey: TestPasskeyService(),
                healthKit: MockHealthKitWriter(),
                apiSessionConfiguration: .mock()
            )
            container.authStore.setPhaseForTesting(
                .authenticated(User(id: Self.owner, email: nil, username: nil, displayName: nil, createdAt: .now))
            )
            return container
        }

        private func clearPersistedStamp() {
            UserDefaults.standard.removeObject(forKey: HKReadinessStore.lastSyncedKey(for: Self.owner))
        }

        @Test("an accepted upload through the container's own uploader moves lastSyncedAt")
        func acceptedUploadMovesLastSyncedAt() async throws {
            clearPersistedStamp()
            defer { clearPersistedStamp() }
            let container = try makeSignedInContainer()
            #expect(container.hkReadinessStore.lastSyncedAt == nil)
            #expect(container.hkReadinessStore.isConnected == false, "no sheet, no sync: nothing proves a connection yet")

            let outcomes = try await container.healthKitUploader.upload([Self.entry])

            #expect(outcomes.count == 1)
            #expect(
                container.hkReadinessStore.lastSyncedAt != nil,
                "the uploader's success notifier must reach HKReadinessStore.noteSuccessfulSync"
            )
            #expect(container.hkReadinessStore.isConnected, "a delivered batch is the proof isConnected checks first")
            #expect(UserDefaults.standard.double(forKey: HKReadinessStore.lastSyncedKey(for: Self.owner)) > 0)
        }

        @Test("the outbox replay's HealthKit delivery path is wired too")
        func outboxReplayDeliveryIsWired() throws {
            let container = try makeSignedInContainer()
            #expect(container.outboxReplay.isHealthKitDeliveryNotifierAttached)
        }

        /// The fence: a stamp is admitted only for the owner that still holds
        /// the current registry generation AND is the Keychain's user.
        @Test("the wired stamp refuses a foreign, missing or retired owner")
        func stampIsFencedToTheCurrentSession() async throws {
            clearPersistedStamp()
            defer { clearPersistedStamp() }
            let container = try makeSignedInContainer()
            let stamp = AppContainer.makeMeasurementSyncStamp(
                readiness: container.hkReadinessStore,
                registry: container.authenticatedSessionRegistry
            )
            let first = Date(timeIntervalSince1970: 1_758_960_000)

            await stamp(first, "someone-else")
            await stamp(first, nil)
            #expect(container.hkReadinessStore.lastSyncedAt == nil)

            await stamp(first, Self.owner)
            #expect(container.hkReadinessStore.lastSyncedAt == first)

            // Logout / terminal 401 / deletion / server switch invalidate the
            // registry at their commitment point, before any wipe. An upload
            // of the retired session that answers afterwards stamps nothing.
            container.authenticatedSessionRegistry.invalidate()
            await stamp(first.addingTimeInterval(60), Self.owner)
            #expect(container.hkReadinessStore.lastSyncedAt == first)
        }
    }

    @MainActor
    @Suite("#10 — HKReadinessStore stamp fence + caption fallback")
    struct HKReadinessSyncStampTests {
        private static func makeStore(userID: String?) throws -> (HKReadinessStore, UserDefaults) {
            let defaults = try #require(UserDefaults(suiteName: "hl.tests.m1.\(UUID().uuidString)"))
            let keychain = InMemoryKeychain()
            if let userID {
                try keychain.setString(userID, forKey: KeychainKey.userID)
            }
            let store = HKReadinessStore(
                healthKit: nil,
                backgroundSync: StubBackgroundSyncCoordinator(),
                keychain: keychain,
                defaults: defaults
            )
            return (store, defaults)
        }

        @Test("stamps for the current owner and persists under that owner's key")
        func stampsForCurrentOwner() throws {
            let (store, defaults) = try Self.makeStore(userID: "alice")
            let date = Date(timeIntervalSince1970: 1_758_960_000)

            #expect(store.noteSuccessfulSync(at: date, ownerUserID: " alice "))
            #expect(store.lastSyncedAt == date)
            #expect(defaults.double(forKey: HKReadinessStore.lastSyncedKey(for: "alice")) == date.timeIntervalSince1970)
        }

        @Test("refuses a foreign owner, a missing owner, and a signed-out store")
        func refusesEverythingElse() throws {
            let date = Date(timeIntervalSince1970: 1_758_960_000)
            let (store, defaults) = try Self.makeStore(userID: "bob")
            #expect(store.noteSuccessfulSync(at: date, ownerUserID: "alice") == false)
            #expect(store.noteSuccessfulSync(at: date, ownerUserID: nil) == false)
            #expect(store.noteSuccessfulSync(at: date, ownerUserID: "  ") == false)
            #expect(store.lastSyncedAt == nil)
            #expect(defaults.object(forKey: HKReadinessStore.lastSyncedKey(for: "bob")) == nil)
            #expect(defaults.object(forKey: HKReadinessStore.lastSyncedKey(for: "alice")) == nil)

            let (signedOut, _) = try Self.makeStore(userID: nil)
            #expect(signedOut.noteSuccessfulSync(at: date, ownerUserID: "alice") == false)
            #expect(signedOut.lastSyncedAt == nil)
        }

        @Test("the caption prefers this device's stamp and falls back to the server's")
        func captionFallsBackToServerStamp() throws {
            let (store, _) = try Self.makeStore(userID: "alice")
            let server = Date(timeIntervalSince1970: 1_758_900_000)
            let local = Date(timeIntervalSince1970: 1_758_960_000)

            #expect(store.displayedLastSyncedAt(serverLastSyncedAt: nil) == nil)
            #expect(store.displayedLastSyncedAt(serverLastSyncedAt: server) == server, "a reinstall keeps a real answer")

            store.noteSuccessfulSync(at: local)
            #expect(store.displayedLastSyncedAt(serverLastSyncedAt: server) == local)
        }

        /// The server stamp is account-wide (any device of the account stamps
        /// it), so it must not suppress the "declined" warning on THIS device.
        @Test("the server stamp does not make isConnected true")
        func serverStampDoesNotConnect() throws {
            let (store, _) = try Self.makeStore(userID: "alice")
            _ = store.displayedLastSyncedAt(serverLastSyncedAt: Date(timeIntervalSince1970: 1_758_900_000))
            #expect(store.isConnected == false)
        }
    }

    @Suite("#10 — the PATCH echo keeps the GET's read fields")
    struct HealthKitSyncConfigReadFieldsTests {
        private static let entry = HealthKitSyncEntry(id: "weight", kind: "bodyMass", direction: .bidirectional, enabled: false)

        @Test("fields the echo does not carry come from the previous GET, entries from the echo")
        func keepsReadFields() {
            let synced = Date(timeIntervalSince1970: 1_758_900_000)
            let background = Date(timeIntervalSince1970: 1_758_800_000)
            let previous = HealthKitSyncConfig(
                entries: [Self.entry.withEnabled(true)],
                lastSyncedAt: synced,
                lastSyncTrigger: "background",
                lastBackgroundSyncAt: background
            )
            let echo = HealthKitSyncConfig(entries: [Self.entry], lastSyncedAt: nil)

            let merged = echo.keepingReadFields(of: previous)

            #expect(merged.entries == [Self.entry])
            #expect(merged.lastSyncedAt == synced)
            #expect(merged.lastSyncTrigger == "background")
            #expect(merged.lastBackgroundSyncAt == background)
        }

        @Test("a value the echo does carry wins, and no previous config changes nothing")
        func echoWins() {
            let echoStamp = Date(timeIntervalSince1970: 1_758_960_000)
            let echo = HealthKitSyncConfig(entries: [Self.entry], lastSyncedAt: echoStamp)
            let previous = HealthKitSyncConfig(entries: [], lastSyncedAt: Date(timeIntervalSince1970: 1))

            #expect(echo.keepingReadFields(of: previous).lastSyncedAt == echoStamp)
            #expect(echo.keepingReadFields(of: nil) == echo)
        }
    }

    /// The caption's fallback is only as good as the `hkConfig` it reads. The
    /// PATCH route answers `lastSyncedAt: null`; before #10 the store took that
    /// echo verbatim, so toggling one data type erased the server stamp.
    @MainActor
    @Suite("#10 — toggling a data type keeps the server's lastSyncedAt", .serialized, .mockURLSession)
    struct SettingsToggleKeepsServerStampTests {
        private nonisolated static func reply(_ request: URLRequest, _ status: Int, _ body: String) -> (HTTPURLResponse, Data?) {
            (
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }

        @Test("the PATCH echo's null does not overwrite the GET's stamp")
        func toggleKeepsStamp() async throws {
            MockURLProtocol.install { request in
                switch (request.httpMethod, request.url?.path) {
                case ("GET", "/api/integrations/healthkit"):
                    Self.reply(request, 200, #"""
                    {"data":{"entries":[{"id":"weight","kind":"bodyMass","direction":"bidirectional","enabled":true}],
                    "lastSyncedAt":"2026-09-27T08:00:00.000Z","lastSyncTrigger":"background"},"error":null}
                    """#)
                case ("PATCH", "/api/integrations/healthkit"):
                    Self.reply(request, 200, #"""
                    {"data":{"entries":[{"id":"weight","kind":"bodyMass","direction":"bidirectional","enabled":false}],
                    "lastSyncedAt":null},"error":null}
                    """#)
                case ("GET", "/api/user/profile"):
                    Self.reply(request, 200, #"{"data":{},"error":null}"#)
                default:
                    Self.reply(request, 404, #"{"data":null,"error":"not found"}"#)
                }
            }
            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: "owner-m1")
            let api = APIClient(
                environment: AppEnvironment(
                    baseURL: URL(string: "https://test.healthlog.local"),
                    bundleID: "dev.healthlog.app",
                    appVersion: "1.1.0",
                    buildNumber: "300"
                ),
                keychain: InMemoryKeychain(),
                sessionConfiguration: .mock()
            )
            let defaults = try #require(UserDefaults(suiteName: "hl.tests.m1.toggle.\(UUID().uuidString)"))
            let store = SettingsStore(
                repo: SettingsRepository(api: api),
                defaults: defaults,
                authenticatedSessionRegistry: registry,
                userIDProvider: { "owner-m1" }
            )
            await store.load()
            let stamp = try #require(store.hkConfig?.lastSyncedAt)

            await store.toggle(syncEntryID: "weight")

            #expect(store.hkConfig?.entries.first?.enabled == false, "the entries come from the echo")
            #expect(store.hkConfig?.lastSyncedAt == stamp, "the echo's null is not news about the last sync")
            #expect(store.hkConfig?.lastSyncTrigger == "background")
        }
    }

#endif // !SWIFT_PACKAGE

// swiftlint:enable force_unwrapping
