// Diese Suite hängt an App-Target-Symbolen (`AuthStore`, `AppContainer`,
// `StandaloneRetirement`) — im SPM-Library-Build gibt es sie nicht, also wird
// die Datei dort übersprungen.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// **The offline ("standalone") mode is removed; prove an installation that
    /// stored it survives the update.**
    ///
    /// No App Store build ever offered the mode, but TestFlight builds up to b197
    /// (until 19 June 2026) could store it. The fixture below is such an
    /// installation: the
    /// keys and files that build wrote, with the literal names and formats it
    /// used, planted in isolated defaults and an isolated directory. The literals
    /// stay in this file on purpose — the production code no longer knows them,
    /// and this suite is where the history of what a device may carry lives.
    ///
    /// A device that ran the mode and is signed in as well (the old build kept
    /// reading locally while `hl.syncMode` still said `standalone`) now sees its
    /// server's data instead of the local records.
    @MainActor
    @Suite("Standalone retirement — the update path", .serialized)
    struct StandaloneRetirementUpdatePathTests {
        // MARK: - What an offline-mode build left behind

        /// `UserDefaults.standard` as an offline-mode build wrote it. The mode
        /// keys took the raw values of the removed `SyncMode` / `OnboardingMode`
        /// enums; the disclaimer key held the acknowledged copy version.
        static let previousBuildDefaults: [String: String] = [
            "hl.syncMode": "standalone",
            "hl.onboarding.mode": "standalone",
            "hl.disclaimer.standaloneAckVersion": "2026-06-18"
        ]

        /// The SwiftData store of the offline records, under Application Support.
        static let previousBuildStoreFolder = "HealthLog/Standalone"
        static let previousBuildStoreFiles = ["standalone.sqlite", "standalone.sqlite-shm", "standalone.sqlite-wal"]

        // MARK: - 1. The first launch after the update

        /// The old build answered this state with the standalone shell. The new
        /// one has no such phase: a stored mode without a token is a signed-out
        /// install, which mounts the onboarding at its first step.
        @Test("a stored offline mode starts at the server sign-in, not in a shell")
        func storedModeStartsAtSignIn() async throws {
            let defaults = try Self.isolatedDefaults()
            Self.plantPreviousBuildDefaults(in: defaults)
            let store = Self.makeAuthStore(defaults: defaults)

            await store.bootstrap()

            #expect(store.phase == .unauthenticated)
            #expect(!store.phase.isUnlockEligible, "no shell, so no biometric lock in front of it")
            #expect(!RootView.needsServerAddressGate(phase: store.phase, hasServerAddress: false))
            #expect(OnboardingFlow.initialStep == .welcome)
            #expect(OnboardingFlow.resolveStep(.welcome, hasServerAddress: false, phase: store.phase) == .welcome)
            var clock = AppLockClock()
            let locksNow = clock.authPhaseChanged(to: store.phase, lockEnabled: true)
            #expect(!locksNow)
        }

        /// The launch drops the stored mode, so a second launch reads exactly
        /// what the first one did and nothing re-routes it.
        @Test("the stored mode is dropped on launch and the second launch matches the first")
        func secondLaunchMatchesTheFirst() async throws {
            let base = try Self.isolatedApplicationSupport()
            defer { try? FileManager.default.removeItem(at: base) }
            let defaults = try Self.isolatedDefaults()
            Self.plantPreviousBuildDefaults(in: defaults)
            defaults.set("dark", forKey: "hl.settings.appearance")

            StandaloneRetirement.retireStoredMode(in: defaults, applicationSupport: base)
            let first = Self.makeAuthStore(defaults: defaults)
            await first.bootstrap()
            let afterFirst = Self.snapshot(defaults)

            StandaloneRetirement.retireStoredMode(in: defaults, applicationSupport: base)
            let second = Self.makeAuthStore(defaults: defaults)
            await second.bootstrap()

            for key in Self.previousBuildDefaults.keys {
                #expect(defaults.object(forKey: key) == nil, "\(key) survived the launch")
            }
            #expect(defaults.string(forKey: "hl.settings.appearance") == "dark", "an unrelated setting was touched")
            #expect(first.phase == .unauthenticated)
            #expect(second.phase == first.phase)
            #expect(Self.snapshot(defaults) == afterFirst)
        }

        /// The composition root is what runs the drop on a real launch.
        @Test("building the app container drops the stored mode")
        func containerDropsTheStoredMode() {
            let defaults = UserDefaults.standard
            Self.plantPreviousBuildDefaults(in: defaults)
            defer {
                Self.previousBuildDefaults.keys.forEach(defaults.removeObject(forKey:))
                defaults.removeObject(forKey: Self.leftoverDataKey)
            }

            _ = Self.makeContainer()

            for key in Self.previousBuildDefaults.keys {
                #expect(defaults.object(forKey: key) == nil, "\(key) survived the container")
            }
        }

        // MARK: - 2. The offline records

        /// The update itself deletes nothing: the records stay where the old
        /// build left them until the user removes local data.
        @Test("the update keeps the offline records on disk")
        func updateKeepsTheRecords() throws {
            let base = try Self.isolatedApplicationSupport()
            defer { try? FileManager.default.removeItem(at: base) }
            let folder = try Self.plantPreviousBuildStore(in: base)

            try StandaloneRetirement.retireStoredMode(in: Self.isolatedDefaults(), applicationSupport: base)

            for name in Self.previousBuildStoreFiles {
                #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path))
            }
        }

        /// What account deletion and a server switch removed before, they remove
        /// now: the whole store with its siblings, and nothing next to it.
        @Test("removing local data deletes the offline records and nothing beside them")
        func removalDeletesOnlyTheRecords() throws {
            let base = try Self.isolatedApplicationSupport()
            defer { try? FileManager.default.removeItem(at: base) }
            let folder = try Self.plantPreviousBuildStore(in: base)
            let neighbour = base.appendingPathComponent("HealthLog/GLP1", isDirectory: true)
            try FileManager.default.createDirectory(at: neighbour, withIntermediateDirectories: true)

            let defaults = try Self.isolatedDefaults()
            try StandaloneRetirement.removeLocalStore(defaults: defaults, applicationSupport: base)
            try StandaloneRetirement.removeLocalStore(defaults: defaults, applicationSupport: base)

            #expect(!FileManager.default.fileExists(atPath: folder.path))
            #expect(FileManager.default.fileExists(atPath: neighbour.path))
        }

        // MARK: - 2a. The note on Welcome

        /// The mode was still on and its records are there: the install keeps a
        /// marker past the dropped mode keys, Welcome shows the note, and a
        /// second launch keeps both.
        @Test("a stored mode with its records sets the marker and shows the note")
        func modeWithRecordsShowsTheNote() throws {
            let base = try Self.isolatedApplicationSupport()
            defer { try? FileManager.default.removeItem(at: base) }
            _ = try Self.plantPreviousBuildStore(in: base)
            let defaults = try Self.isolatedDefaults()
            Self.plantPreviousBuildDefaults(in: defaults)

            StandaloneRetirement.retireStoredMode(in: defaults, applicationSupport: base)
            let first = Self.noteState(defaults, base)
            StandaloneRetirement.retireStoredMode(in: defaults, applicationSupport: base)

            #expect(defaults.bool(forKey: Self.leftoverDataKey))
            #expect(first.shows)
            #expect(Self.noteState(defaults, base) == first, "the second launch differs from the first")
            for key in Self.previousBuildDefaults.keys {
                #expect(defaults.object(forKey: key) == nil, "\(key) survived the launch")
            }
        }

        /// The onboarding key alone is enough: it was not cleared on logout.
        @Test("the onboarding mode key alone also marks the records")
        func onboardingModeAloneMarksTheRecords() throws {
            let base = try Self.isolatedApplicationSupport()
            defer { try? FileManager.default.removeItem(at: base) }
            _ = try Self.plantPreviousBuildStore(in: base)
            let defaults = try Self.isolatedDefaults()
            defaults.set("standalone", forKey: "hl.onboarding.mode")

            StandaloneRetirement.retireStoredMode(in: defaults, applicationSupport: base)

            #expect(Self.noteState(defaults, base).shows)
        }

        /// An install that moved to a server kept the file (the adopt upload
        /// left the mirror in place) but its keys read `paired` / `server`. It
        /// must never see the note.
        @Test("the records without a stored mode set no marker and show no note")
        func recordsWithoutModeShowNothing() throws {
            let base = try Self.isolatedApplicationSupport()
            defer { try? FileManager.default.removeItem(at: base) }
            _ = try Self.plantPreviousBuildStore(in: base)
            let defaults = try Self.isolatedDefaults()
            defaults.set("paired", forKey: "hl.syncMode")
            defaults.set("server", forKey: "hl.onboarding.mode")

            StandaloneRetirement.retireStoredMode(in: defaults, applicationSupport: base)

            #expect(Self.noteState(defaults, base) == NoteState(marker: false, shows: false))
        }

        @Test("a stored mode without its records shows no note")
        func modeWithoutRecordsShowsNothing() throws {
            let base = try Self.isolatedApplicationSupport()
            defer { try? FileManager.default.removeItem(at: base) }
            let defaults = try Self.isolatedDefaults()
            Self.plantPreviousBuildDefaults(in: defaults)

            StandaloneRetirement.retireStoredMode(in: defaults, applicationSupport: base)

            #expect(!Self.noteState(defaults, base).shows)
        }

        @Test("a fresh install has no marker and no note")
        func freshInstallShowsNothing() throws {
            let base = try Self.isolatedApplicationSupport()
            defer { try? FileManager.default.removeItem(at: base) }
            let defaults = try Self.isolatedDefaults()

            StandaloneRetirement.retireStoredMode(in: defaults, applicationSupport: base)

            #expect(Self.noteState(defaults, base) == NoteState(marker: false, shows: false))
        }

        /// Account deletion and a server switch remove the records and the note.
        @Test("account deletion and server switch remove the marker with the records", arguments: [
            LogoutReason.accountDeleted, .switchServer
        ])
        func cascadeRemovesMarkerAndRecords(reason: LogoutReason) async throws {
            let base = try Self.isolatedApplicationSupport()
            defer { try? FileManager.default.removeItem(at: base) }
            let folder = try Self.plantPreviousBuildStore(in: base)
            let defaults = try Self.isolatedDefaults()
            Self.plantPreviousBuildDefaults(in: defaults)
            StandaloneRetirement.retireStoredMode(in: defaults, applicationSupport: base)
            #expect(Self.noteState(defaults, base).shows)
            let container = Self.makeContainer()
            container.legacyStandaloneStoreBase = base
            container.legacyStandaloneDefaults = defaults

            await container.performFullLocalLogout(reason: reason)

            #expect(!FileManager.default.fileExists(atPath: folder.path))
            #expect(Self.noteState(defaults, base) == NoteState(marker: false, shows: false))
        }

        /// A device that ran the mode while signed in: the token wins, the old
        /// keys go, the marker is set for the records, and the second launch
        /// is the same.
        @Test("a token with the stored mode starts signed in and keeps the note")
        func tokenWithStoredModeStartsSignedIn() async throws {
            let base = try Self.isolatedApplicationSupport()
            defer { try? FileManager.default.removeItem(at: base) }
            _ = try Self.plantPreviousBuildStore(in: base)
            let defaults = try Self.isolatedDefaults()
            Self.plantPreviousBuildDefaults(in: defaults)
            let keychain = InMemoryKeychain()
            try keychain.setString("legacy-bearer", forKey: KeychainKey.authToken)
            try keychain.setString("user-legacy", forKey: KeychainKey.userID)

            // Launch order as in `AppContainer.init`: retire, then bootstrap.
            StandaloneRetirement.retireStoredMode(in: defaults, applicationSupport: base)
            let first = Self.makeAuthStore(defaults: defaults, keychain: keychain)
            await first.bootstrap()
            let afterFirst = Self.snapshot(defaults)
            StandaloneRetirement.retireStoredMode(in: defaults, applicationSupport: base)
            let second = Self.makeAuthStore(defaults: defaults, keychain: keychain)
            await second.bootstrap()

            guard case let .authenticated(user) = first.phase else {
                Issue.record("expected .authenticated, got \(first.phase)")
                return
            }
            #expect(user.id == "user-legacy")
            // The bootstrap user carries a fresh `createdAt`, so the phases are
            // compared by the account they admit.
            #expect(AuthStore.sessionOwner(in: second.phase) == "user-legacy")
            #expect(Self.snapshot(defaults) == afterFirst)
            #expect(Self.noteState(defaults, base).shows)
        }

        // MARK: - 3. Persisted values that may hold the old raw value

        /// An offline-mode build recorded its heart-rate sweep gate as
        /// `standalone` in the per-account ledger. The ledger must still decode;
        /// a reset would forget which days the server already holds.
        @Test("a heart-rate ledger with the old gate still decodes")
        func heartRateLedgerToleratesTheOldGate() throws {
            let defaults = try Self.isolatedDefaults()
            let event = Date(timeIntervalSince1970: 1_750_000_000)
            HRBucketSyncLedgerStore.update(userId: "user-legacy", defaults: defaults, now: event) { ledger in
                ledger.bucketDays = [HRBucketSyncLedger.day(of: event)]
                ledger.record(.noAuthToken, at: event)
            }
            let key = HRBucketSyncLedgerStore.key(for: "user-legacy")
            let written = try #require(defaults.data(forKey: key))
            let legacyJSON = try #require(String(data: written, encoding: .utf8))
                .replacingOccurrences(of: "\"noAuthToken\"", with: "\"standalone\"")
            #expect(legacyJSON.contains("\"standalone\""))
            defaults.set(Data(legacyJSON.utf8), forKey: key)

            let ledger = HRBucketSyncLedgerStore.load(userId: "user-legacy", defaults: defaults)

            #expect(ledger.bucketDays == [HRBucketSyncLedger.day(of: event)])
            #expect(ledger.lastEvent?.gate == .noAuthToken)
            #expect(ledger.lastSuppression?.gate == .noAuthToken)
        }

        @Test("the old gate decodes as no token, an unknown gate still fails")
        func gateDecodingIsTolerantOnlyForTheOldValue() throws {
            let decoder = JSONDecoder()
            #expect(try decoder.decode(HRBucketGate.self, from: Data(#""standalone""#.utf8)) == .noAuthToken)
            #expect(try decoder.decode(HRBucketGate.self, from: Data(#""uploaded""#.utf8)) == .uploaded)
            #expect(throws: DecodingError.self) {
                try decoder.decode(HRBucketGate.self, from: Data(#""somethingElse""#.utf8))
            }
            let roundTrip = try decoder.decode(HRBucketGate.self, from: JSONEncoder().encode(HRBucketGate.noAuthToken))
            #expect(roundTrip == .noAuthToken)
        }

        /// Coach transcripts written without a signed-in user are partitioned
        /// under this literal. Renaming it would orphan them.
        @Test("the signed-out coach partition keeps its persisted literal")
        func coachPartitionLiteralIsUnchanged() {
            #expect(CoachChatMessage.signedOutUserID == "__standalone__")
        }

        // MARK: - Fixtures

        /// The marker key as the production code writes it.
        static let leftoverDataKey = "hl.standaloneRetirement.leftoverData"

        struct NoteState: Equatable {
            let marker: Bool
            let shows: Bool
        }

        static func noteState(_ defaults: UserDefaults, _ base: URL) -> NoteState {
            NoteState(
                marker: defaults.bool(forKey: leftoverDataKey),
                shows: StandaloneRetirement.showsLeftoverDataNotice(defaults: defaults, applicationSupport: base)
            )
        }

        static func isolatedDefaults() throws -> UserDefaults {
            let suite = "hl.tests.standalone-retirement.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            return defaults
        }

        static func plantPreviousBuildDefaults(in defaults: UserDefaults) {
            for (key, value) in previousBuildDefaults {
                defaults.set(value, forKey: key)
            }
        }

        static func snapshot(_ defaults: UserDefaults) -> [String: String] {
            let keys = Array(previousBuildDefaults.keys) + ["hl.settings.appearance", leftoverDataKey]
            return keys.reduce(into: [:]) { result, key in
                result[key] = defaults.string(forKey: key) ?? "<absent>"
            }
        }

        /// A directory of this run's own that stands in for Application Support.
        /// Removed by the test that made it.
        static func isolatedApplicationSupport() throws -> URL {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("hl-standalone-retirement-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            return base
        }

        static func plantPreviousBuildStore(in base: URL) throws -> URL {
            let folder = base.appendingPathComponent(previousBuildStoreFolder, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in previousBuildStoreFiles {
                try Data("offline record".utf8).write(to: folder.appendingPathComponent(name))
            }
            return folder
        }

        /// No token in the Keychain by default, as on an offline-mode install
        /// that never signed in.
        static func makeAuthStore(defaults: UserDefaults, keychain: InMemoryKeychain = InMemoryKeychain()) -> AuthStore {
            let api = APIClient(environment: AppEnvironment.loadFromBundle(), keychain: keychain)
            let auth = AuthService(api: api, keychain: keychain, passkey: TestPasskeyService())
            return AuthStore(auth: auth, keychain: keychain, defaults: defaults)
        }

        static func makeContainer() -> AppContainer {
            AppContainer(
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
        }
    }

#endif
