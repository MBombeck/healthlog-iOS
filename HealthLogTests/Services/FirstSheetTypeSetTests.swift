// Diese Suite liest App-Target-Symbole (`HealthKitService`, die beiden
// Sync-Schalter), die in der SPM-Library nicht enthalten sind. Der
// SPM-Test-Build überspringt die Datei.
#if !SWIFT_PACKAGE

    import Foundation
    #if canImport(HealthKit)
        import HealthKit
    #endif
    @testable import HealthLog
    import Testing

    /// **Phase 16 Plan 03 — decision E2: EKG und Stimmung wandern in das erste
    /// HealthKit-Sheet.**
    ///
    /// The operator's own wording, chosen against the planning recommendation on
    /// 2026-08-22, and it carries two conditions that this suite is here to keep
    /// standing long after the plan that wrote them:
    ///
    /// 1. **Medications are not in it.** The Apple-medication type is
    ///    iOS-26-only and needs `requestPerObjectReadAuthorization`; a second
    ///    authorization call for it raises an uncatchable ObjC exception and the
    ///    process SIGABRTs. `medicationTypeIsFencedOutOfEveryDefaultSet` is the
    ///    fence, and it is permanent — it was green before E2, it is green
    ///    after, and it must never be deleted because "the sets look
    ///    inconsistent".
    /// 2. **An existing installation is not re-prompted.** Enlarging a default
    ///    set is a defaults change, and this repository's standing rule is that
    ///    a defaults change needs an update-path test. A fresh install would
    ///    pass every clause below while every device already in the field stayed
    ///    on the old permissions — which is exactly what happened when
    ///    `workoutType()` joined `defaultReadTypes` in b171 and needed a
    ///    one-shot re-auth migration to repair.
    ///
    /// Source contracts read comment-stripped source — a doc comment naming a
    /// symbol is not the symbol.
    @MainActor
    @Suite("Phase 16 first HealthKit sheet — E2 membership, the SIGABRT fence, the update path")
    struct FirstSheetTypeSetTests {
        #if canImport(HealthKit)

            // MARK: - RED — the membership E2 asks for

            @Test("ECG and State of Mind are members of the first sheet's type sets")
            func ecgAndMoodAreInTheFirstSheet() {
                let read = HealthKitService.defaultReadTypes.map(\.identifier)
                let write = HealthKitService.defaultWriteTypes.map(\.identifier)

                var violations: [String] = []
                if !read.contains(Self.ecgIdentifier) {
                    violations.append("the ECG read type is not in the first sheet")
                }
                if !read.contains(Self.stateOfMindIdentifier) {
                    violations.append("the State-of-Mind read type is not in the first sheet")
                }
                // Mood is read AND write: the app writes moods the user records
                // back into Apple Health, so a read-only membership would ship a
                // sync that silently no-ops on every write.
                if !write.contains(Self.stateOfMindIdentifier) {
                    violations.append("the State-of-Mind write type is not in the first sheet")
                }
                // Once, not twice: a set holds one of each, and the sheet Apple
                // renders is derived from these two sets alone.
                if read.filter({ $0 == Self.ecgIdentifier }).count > 1 {
                    violations.append("the ECG type is listed more than once")
                }

                #expect(violations.isEmpty, "EXPECTED_RED: both types are still settings-only opt-ins")
            }

            @Test("completing the onboarding grant turns the two device-local syncs on")
            func onboardingGrantActivatesSync() throws {
                var violations: [String] = []

                // The plan decides which of the two a grant may activate. Mood
                // is device-local end to end; the ECG upload's only destination
                // is `POST /api/insights/ecg`, so on a standalone install there
                // is nowhere to send a waveform — which is why the settings row
                // hides there too.
                let step = try Self.strippedSource(Self.permissionStepPath)
                if !step.contains("adoptFirstSheetGrant") {
                    violations.append("the onboarding grant activates nothing — J1 ships half-fixed")
                }
                if !step.contains("FirstSheetSyncAdoption") {
                    violations.append("no rule says which syncs a grant may activate")
                }

                // And the activation must not be a second authorization call.
                // Two sheets in a row for types the first one already asked for
                // is the shape E2 exists to remove.
                let ecgSource = try Self.strippedSource(Self.ecgStorePath)
                let moodSource = try Self.strippedSource(Self.moodStorePath)
                for (name, source) in [("EcgHealthSyncStore", ecgSource), ("MoodHealthSyncStore", moodSource)] {
                    guard let adopt = Self.member(named: "func adoptFirstSheetGrant", in: source) else {
                        violations.append("\(name) has no way to adopt a grant it did not ask for")
                        continue
                    }
                    if adopt.contains("requestMoodAuthorization") || adopt.contains("requestEcgAuthorizationIfNeeded") {
                        violations.append("\(name) asks for authorization it was just granted")
                    }
                }

                #expect(
                    violations.isEmpty,
                    "EXPECTED_RED: granting in onboarding does not activate the sync stores"
                )
            }

            // MARK: - GREEN — the adoption, driven

            @Test("adopting a first-sheet grant turns the sync on without asking again")
            func adoptingAGrantRaisesNoSecondSheet() async throws {
                let defaults = try Self.isolatedDefaults()
                let writer = SpyFirstSheetWriter()
                let sync = SpyFirstSheetEcgSync()
                let ecg = EcgHealthSyncStore(healthKit: writer, sync: sync, defaults: defaults)
                let mood = try MoodHealthSyncStore(
                    healthKit: writer,
                    moodRepo: Self.inertMoodRepository(),
                    keychain: InMemoryKeychain(),
                    defaults: defaults
                )

                await ecg.adoptFirstSheetGrant()
                await mood.adoptFirstSheetGrant()

                #expect(ecg.enabled, "EKG ist dabei und aktiv — J1")
                #expect(mood.enabled, "Stimmung ist dabei und aktiv — J1")
                #expect(defaults.bool(forKey: EcgHealthSyncStore.prefKey), "and the choice survives relaunch")
                #expect(defaults.bool(forKey: MoodHealthSyncStore.prefKey))
                #expect(
                    writer.authorizationRequests == 0,
                    """
                    Adoption must raise no second system sheet: the first one already asked for both types. \
                    A second dialog for a decision the user just made is the sequential-sheet shape E2 \
                    chose against.
                    """
                )
                #expect(sync.triggerCount == 1, "and the first sweep runs, so history arrives without a trip to Settings")
                #expect(writer.moodImportStarts == 1, "and moods logged elsewhere start arriving")

                // Idempotent, and never a way to turn something off.
                await ecg.adoptFirstSheetGrant()
                #expect(ecg.enabled)
                #expect(sync.triggerCount == 1, "a repeated adoption does not re-sweep")
            }

            @Test("the adoption plan sends an ECG only where an ECG can go")
            func adoptionPlanRespectsTheUploadTarget() {
                let paired = FirstSheetSyncAdoption.plan(hasAuthenticatedServer: true)
                #expect(paired.mood, "mood sync is device-local end to end")
                #expect(paired.ecg, "and a paired install has POST /api/insights/ecg to send to")

                let standalone = FirstSheetSyncAdoption.plan(hasAuthenticatedServer: false)
                #expect(standalone.mood, "a standalone install runs the mood sync exactly as a paired one does")
                #expect(
                    !standalone.ecg,
                    """
                    A standalone install has nowhere to send a waveform, and the settings row hides for the \
                    same reason. Switching the sync on there would leave a hidden toggle reading ON.
                    """
                )
            }

            // MARK: - The SIGABRT fence (green before E2, green after, permanent)

            /// **Do not delete this test to make the type sets look consistent.**
            ///
            /// The operator's E2 answer was "EKG und Stimmung" and named
            /// medications as excluded, for a reason that is in the source:
            /// `AppleHealthMedicationReader.requestAuthorization()` documents
            /// that the medication types need `requestPerObjectReadAuthorization`
            /// and that passing them anywhere else "is an invalid argument that
            /// raises an uncatchable ObjC NSException → SIGABRT". The default
            /// sets are handed to `requestAuthorization(toShare:read:)`. A
            /// medication type in either of them is a crash on the first launch
            /// of the first user who has one.
            @Test("no default type set contains an Apple-medication type — the SIGABRT fence")
            func medicationTypeIsFencedOutOfEveryDefaultSet() {
                let identifiers = HealthKitService.defaultReadTypes.map(\.identifier)
                    + HealthKitService.defaultWriteTypes.map(\.identifier)
                    + HealthKitService.eventReadTypes.map(\.identifier)

                // Matched on the substring rather than on the iOS-26 symbols, so
                // the fence holds when this suite runs on an older runtime —
                // an `#available` guard here would make the test pass by not
                // asking, which is the one failure mode a permanent fence
                // cannot afford.
                let offenders = identifiers.filter { $0.localizedCaseInsensitiveContains("medication") }

                #expect(
                    offenders.isEmpty,
                    """
                    E2 excluded medications from the first sheet: the type is iOS-26-only and a second \
                    authorization call SIGABRTs (documented in AppleHealthMedicationReader.swift — \
                    per-object read authorization is the ONLY legal path for HKUserAnnotatedMedicationType, \
                    and any other call raises an uncatchable ObjC NSException). Do not add it here; the \
                    settings toggle is the only authorization path. Found: \(offenders)
                    """
                )
            }

            /// The other half of the fence: exactly one authorization call site
            /// for the medication type exists in the whole app, and it is the
            /// settings toggle's. A guard on set membership alone would not stop
            /// someone adding a second call directly.
            @Test("exactly one authorization path for the medication type exists")
            func onlyOneMedicationAuthorizationPathExists() throws {
                let sources = try Self.productionSources()
                let callSites = sources.filter { _, source in
                    source.contains("requestPerObjectReadAuthorization")
                }.map(\.0).sorted()

                #expect(
                    callSites == [Self.medicationReaderPath],
                    """
                    The medication type may be authorized from exactly one place — the reader behind the \
                    iOS-26 settings toggle. A second call site is the documented SIGABRT. Found: \(callSites)
                    """
                )
            }

            // MARK: - The update path (green target, red only if the change breaks it)

            /// **The repository's standing rule, applied to the trap it was
            /// written for.** A fresh install passes every clause above; an
            /// installation already in the field is the case that can regress,
            /// and the only one that can regress silently.
            @Test("an existing installation keeps its toggles and is not re-prompted on mere launch")
            func updatePathKeepsAnExistingInstallationWhereItIs() async throws {
                // The pre-change state: this device answered the OLD, smaller
                // sheet, and left both opt-ins off — the shipped default.
                let defaults = try Self.isolatedDefaults()
                let writer = SpyFirstSheetWriter()
                let sync = SpyFirstSheetEcgSync()
                let ecg = EcgHealthSyncStore(healthKit: writer, sync: sync, defaults: defaults)
                let mood = try MoodHealthSyncStore(
                    healthKit: writer,
                    moodRepo: Self.inertMoodRepository(),
                    keychain: InMemoryKeychain(),
                    defaults: defaults
                )
                #expect(!ecg.enabled, "the pre-change state is both switches off")
                #expect(!mood.enabled)

                // Mere launch. `RootView` runs exactly this pair on the
                // transition into `.authenticated`; nothing else about an app
                // update touches either store.
                await ecg.activateIfEnabled()
                await mood.activateIfEnabled()

                #expect(!ecg.enabled, "an app update must not flip a switch the user left off")
                #expect(!mood.enabled)
                #expect(!defaults.bool(forKey: EcgHealthSyncStore.prefKey))
                #expect(
                    writer.authorizationRequests == 0,
                    """
                    An app update must not fire an authorization request. The enlarged set reaches an \
                    existing installation only through its next explicit action — the settings toggle, \
                    or the Settings reconnect row.
                    """
                )
                #expect(sync.triggerCount == 0, "and no sweep starts behind their back")
            }

            /// The visible consequence of the enlarged WRITE set for an
            /// installation already in the field, pinned in both directions.
            ///
            /// `HKReadinessStore.state` is computed from WRITE-type statuses
            /// alone, so a device that granted the old set moves to
            /// `.partiallyGranted` once State of Mind joins it. That is honest,
            /// and it is the route decided in 16-CONTEXT: the enlarged set
            /// reaches an existing user through their next explicit
            /// authorization action, which is the Settings reconnect row this
            /// state makes visible again.
            ///
            /// What must NOT come back is the dashboard banner. K10 is the
            /// phase telling a user Apple Health is not connected; shipping a
            /// change that re-raises that banner on every existing device would
            /// undo this phase with its own other half.
            @Test("the enlarged write set surfaces as a reconnect offer, never as the K10 banner")
            func enlargedWriteSetDoesNotResurrectTheDashboardBanner() throws {
                // An installation that granted everything the OLD sheet asked
                // for, now measured against the new set: one type undecided.
                //
                // The State-of-Mind row is written in explicitly rather than
                // read out of `defaultWriteTypes`, so this pins the MECHANISM —
                // "a write type this device never answered shows as missing and
                // must not raise the banner" — before, during and after the type
                // actually joins. A control that only becomes meaningful once
                // the change lands cannot say whether the change broke it.
                var statuses: [String: HKReadinessStore.AuthStatus] = [:]
                for identifier in HealthKitService.defaultWriteTypes.map(\.identifier) {
                    statuses[identifier] = .sharingAuthorized
                }
                statuses[Self.stateOfMindIdentifier] = .notDetermined
                let state = HKReadinessStore.computeState(statuses: statuses, hasRequestedAuthorization: true)
                guard case let .partiallyGranted(missing) = state else {
                    Issue.record("expected .partiallyGranted for an existing installation, got \(state)")
                    return
                }
                #expect(
                    missing == [Self.stateOfMindIdentifier],
                    "exactly the newly-asked type is missing — nothing else moved"
                )

                // And the banner stays down: `isConnected` beats the write-auth
                // proxy for anyone who has been through the sheet and did not
                // decline everything.
                let readiness = try Self.readinessStore(hasRequestedAuthorization: true)
                #expect(
                    readiness.isConnected,
                    "an existing installation must not be told Apple Health is disconnected — that is K10"
                )
            }

            // MARK: - Identifiers

            static let ecgIdentifier = HKObjectType.electrocardiogramType().identifier
            static let stateOfMindIdentifier = HKObjectType.stateOfMindType().identifier

        #endif

        // MARK: - Helpers

        private static let permissionStepPath = "HealthLog/Screens/Onboarding/HealthKitPermissionStep.swift"
        private static let ecgStorePath = "HealthLog/Stores/EcgHealthSyncStore.swift"
        private static let moodStorePath = "HealthLog/Stores/MoodHealthSyncStore.swift"
        private static let medicationReaderPath = "HealthLog/Services/HealthKit/AppleHealthMedicationReader.swift"

        /// A repository the update-path case never reaches: the whole claim is
        /// that a mere launch touches nothing, so this exists to satisfy the
        /// store's initialiser and to fail loudly if that ever stops being true.
        private static func inertMoodRepository() throws -> MoodRepository {
            let environment = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local"),
                cfAccessClientID: nil,
                cfAccessClientToken: nil,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            return try MoodRepository(
                api: APIClient(environment: environment, keychain: InMemoryKeychain()),
                outbox: OutboxQueue(inMemory: true)
            )
        }

        private static func isolatedDefaults() throws -> UserDefaults {
            let name = "test.firstSheet.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: name))
            defaults.removePersistentDomain(forName: name)
            return defaults
        }

        private static func readinessStore(hasRequestedAuthorization: Bool) throws -> HKReadinessStore {
            let name = "test.firstSheet.readiness.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: name))
            defaults.removePersistentDomain(forName: name)
            let keychain = InMemoryKeychain()
            try keychain.setString("owner-a", forKey: KeychainKey.userID)
            let store = HKReadinessStore(
                healthKit: nil,
                backgroundSync: StubBackgroundSyncCoordinator(),
                keychain: keychain,
                defaults: defaults
            )
            if hasRequestedAuthorization { store.markAuthorizationRequested() }
            return store
        }

        /// The body of a declaration, from its line to the matching close brace.
        static func member(named declaration: String, in source: String) -> String? {
            guard let start = source.range(of: declaration) else { return nil }
            var depth = 0
            var opened = false
            var body = ""
            for character in source[start.lowerBound...] {
                body.append(character)
                if character == "{" {
                    depth += 1
                    opened = true
                } else if character == "}" {
                    depth -= 1
                    if opened, depth == 0 { return body }
                }
            }
            return opened ? body : nil
        }

        // MARK: - Source access

        private static let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        static func productionSources() throws -> [(String, String)] {
            let base = root.appendingPathComponent("HealthLog")
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
                return []
            }
            var sources: [(String, String)] = []
            for case let file as URL in walker where file.pathExtension == "swift" {
                let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                sources.append((relative, strippingComments(text)))
            }
            return sources
        }

        static func strippedSource(_ relativePath: String) throws -> String {
            let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            return strippingComments(text)
        }

        static func strippingComments(_ source: String) -> String {
            stripLineComments(from: stripBlockComments(from: source))
        }

        private static func stripBlockComments(from source: String) -> String {
            var out = ""
            var rest = Substring(source)
            while let open = rest.range(of: "/*") {
                out += rest[..<open.lowerBound]
                guard let close = rest.range(of: "*/", range: open.upperBound ..< rest.endIndex) else { return out }
                rest = rest[close.upperBound...]
            }
            return out + rest
        }

        private static func stripLineComments(from source: String) -> String {
            source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                var quoted = false
                var previous: Character = " "
                for (offset, character) in line.enumerated() {
                    if character == "\"", previous != "\\" { quoted.toggle() }
                    if !quoted, character == "/", previous == "/" { return String(line.prefix(offset - 1)) }
                    previous = character
                }
                return String(line)
            }.joined(separator: "\n")
        }
    }

    // MARK: - Test doubles

    /// Counts every authorization request of any kind. The update path's whole
    /// claim is that this stays at zero on a launch, so it must not be able to
    /// miss one by only counting the flavour the test expected.
    private final class SpyFirstSheetWriter: AnyHealthKitWriter, @unchecked Sendable {
        private let lock = NSLock()
        private var _authorizationRequests = 0
        private var _moodImportStarts = 0

        var authorizationRequests: Int {
            lock.withLock { _authorizationRequests }
        }

        var moodImportStarts: Int {
            lock.withLock { _moodImportStarts }
        }

        func requestMoodAuthorization() async throws {
            lock.withLock { _authorizationRequests += 1 }
        }

        func requestEcgAuthorizationIfNeeded() async throws {
            lock.withLock { _authorizationRequests += 1 }
        }

        func requestCycleAuthorizationIfNeeded() async throws {
            lock.withLock { _authorizationRequests += 1 }
        }

        func requestNutrientAuthorizationIfNeeded() async throws {
            lock.withLock { _authorizationRequests += 1 }
        }

        func startMoodImport(repo _: MoodRepository, userID _: String?) async {
            lock.withLock { _moodImportStarts += 1 }
        }

        func write(_: HealthLog.Measurement) async throws {}
        func writeMood(_: MoodEntry) async throws {}
        func deleteMood(id _: String) async throws {}
        func stopMoodImport() async {}
        func resetMoodImport() async {}
        func activateBackgroundDeliveries() async throws {}
        func runBackgroundSyncPass() async {}
        func attachUploader(_: MeasurementBatchUploader) async {}
        func attachDeletionReconciler(_: MeasurementDeletionReconciler) async {}
        func setInitialBackfillCutoff(_: Date?) async {}
        func attachFeatureFlags(_: (any FeatureFlagsServicing)?) async {}
        func stopWorkoutImportObserver() async {}
        func resetWorkoutImportObserver() async {}
    }

    private final class SpyFirstSheetEcgSync: EcgSyncing, @unchecked Sendable {
        private let lock = NSLock()
        private var _triggerCount = 0
        var triggerCount: Int {
            lock.withLock { _triggerCount }
        }

        func triggerEcgSync() async {
            lock.withLock { _triggerCount += 1 }
        }
    }

#endif
