import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif
@testable import HealthLog
import os
import Testing

// swiftlint:disable force_unwrapping file_length type_body_length

#if canImport(HealthKit)

    /// The data-correctness findings on the ingest-v2 paths: chunked outbox
    /// rows, refused symptoms in the skip register, module pauses, deletions
    /// that wait while their route is closed, deletions after a commit only,
    /// the mood source pair behind its flag, and the macro zero correction.
    @Suite("Apple Health ingest v2: data correctness", .serialized, .mockURLSession)
    struct AppleHealthIngestV2RoundTwoTests {
        static let owner = "account-a"
        static let fixtureBearer = ["bearer", "a"].joined(separator: "-")

        private static let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.7.0",
            buildNumber: "1"
        )

        struct Admitted {
            let registry: AuthenticatedSessionLeaseRegistry
            let lease: HealthSyncAuthenticatedLease
        }

        actor Queue: HealthSyncBatchRetryEnqueuing {
            var symptomPages: [[AppleHealthSymptomEntryDTO]] = []
            var deletions: [(AppleHealthDeleteDomain, [String])] = []
            var pruned: [Set<String>] = []

            func enqueueHealthKitRetry(
                _: [HealthKitBatchEntryDTO],
                idempotencyKey _: String,
                requiringCurrentOwner _: String
            ) async throws {}

            func enqueueAppleHealthSymptoms(
                _ entries: [AppleHealthSymptomEntryDTO],
                idempotencyKey _: String,
                requiringCurrentOwner _: String
            ) async throws {
                symptomPages.append(entries)
            }

            func enqueueAppleHealthDeletion(
                _ ids: [String],
                domain: AppleHealthDeleteDomain,
                idempotencyKey _: String,
                requiringCurrentOwner _: String
            ) async throws {
                deletions.append((domain, ids))
            }

            func pruneQueuedAppleHealthUploads(
                _: OutboxQueue.Operation.Kind,
                removing ids: Set<String>,
                ownerUserID _: String
            ) async -> Int {
                pruned.append(ids)
                return 0
            }
        }

        struct MoodBody: Sendable {
            let externalId: String?
            let source: String?
        }

        final class Seen: Sendable {
            private let calls = OSAllocatedUnfairLock<[(String, String)]>(initialState: [])
            var all: [(method: String, path: String)] {
                calls.withLock { $0.map { (method: $0.0, path: $0.1) } }
            }

            func note(_ request: URLRequest) {
                calls.withLock { $0.append((request.httpMethod ?? "", request.url?.path ?? "")) }
            }
        }

        private func admit(source: HealthSyncSource = .heartEvent) throws -> Admitted {
            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.owner)
            let lease = try HealthSyncAuthenticatedLease.admit(
                from: registry,
                ownerID: Self.owner,
                source: source,
                bearerProvider: { Self.fixtureBearer }
            )
            return Admitted(registry: registry, lease: lease)
        }

        private func importer(retry: (any HealthSyncBatchRetryEnqueuing)?) -> HeartHealthEventImporter {
            let keychain = InMemoryKeychain()
            try? keychain.setString(Self.fixtureBearer, forKey: KeychainKey.authToken)
            try? keychain.setString(Self.owner, forKey: KeychainKey.userID)
            let api = APIClient(environment: Self.env, keychain: keychain, sessionConfiguration: .mock())
            let uploader = MeasurementBatchUploader(
                api: api,
                throttle: BatchSyncThrottle(maxPerWindow: 600, window: 60.0, jitter: 0 ... 0),
                syncTrigger: SyncTriggerContext(),
                authenticationSnapshot: {
                    MeasurementUploadAuthenticationSnapshot(ownerUserID: Self.owner, bearerToken: Self.fixtureBearer)
                }
            )
            return HeartHealthEventImporter(
                store: HKHealthStore(),
                uploader: uploader,
                userID: Self.owner,
                defaults: UserDefaults(suiteName: "ingest-v2-r2-\(UUID().uuidString)")!,
                admission: nil,
                cursors: nil,
                retry: retry
            )
        }

        private static func respond(_ request: URLRequest, status: Int = 200, _ body: String) -> (HTTPURLResponse, Data) {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }

        private static func symptoms(_ count: Int, prefix: String = "s") -> [AppleHealthSymptomEntryDTO] {
            (0 ..< count).map { index in
                AppleHealthSymptomEntryDTO(
                    code: "FEVER",
                    occurredAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index)),
                    endAt: nil,
                    intensity: 6,
                    externalId: "\(prefix)-\(index)"
                )
            }
        }

        private static func allFailed(_ request: URLRequest) -> String {
            let body = request.httpBody ?? request.httpBodyStream.map(AppleHealthIngestV2WireTests.Wire.drain) ?? Data()
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let count = (object?["entries"] as? [Any])?.count ?? 0
            let entries = (0 ..< count).map { #"{"index":\#($0),"status":"failed"}"# }.joined(separator: ",")
            return #"{"processed":\#(count),"inserted":0,"duplicates":0,"skipped":[],"entries":[\#(entries)]}"#
        }

        // MARK: - 1. Outbox rows of at most 500

        @Test("600 unanswered symptoms wait as two outbox rows, 500 and 100")
        func failedSymptomsParkPerChunk() async throws {
            MockURLProtocol.install { request in Self.respond(request, Self.allFailed(request)) }
            let admitted = try admit()
            let queue = Queue()
            let page = await importer(retry: queue).transmitSymptoms(Self.symptoms(600), requiring: admitted.lease)
            #expect(await queue.symptomPages.map(\.count) == [500, 100])
            #expect(page.durableRetryPersisted)
            #expect(HealthSyncCursorPolicy.installed.decide(page) == .commit)
        }

        // MARK: - 2. Refusals go into the skip register

        @Test("a skipped symptom goes into the skip register with its reason before the cursor moves")
        func skippedSymptomIsRegistered() async throws {
            MockURLProtocol.install { request in
                Self.respond(
                    request,
                    #"{"processed":2,"inserted":1,"duplicates":0,"skipped":[{"index":1,"reason":"unknown_code"}],"#
                        + #""entries":[{"index":0,"status":"inserted"},{"index":1,"status":"skipped","reason":"unknown_code"}]}"#
                )
            }
            let admitted = try admit()
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
            let page = await HealthKitSkippedRowRegister.$bound.withValue(register) {
                await importer(retry: nil).transmitSymptoms(Self.symptoms(2), requiring: admitted.lease)
            }
            #expect(HealthSyncCursorPolicy.installed.decide(page) == .commit)
            let rows = await register.rows(ownerID: Self.owner)
            #expect(rows.map(\.reason) == ["unknown_code"])
            #expect(rows.first?.symptom?.externalId == "s-1")
        }

        @Test("a refusal that cannot be registered holds the page")
        func unregisteredRefusalHolds() async throws {
            MockURLProtocol.install { request in
                Self.respond(
                    request,
                    #"{"processed":1,"inserted":0,"duplicates":0,"skipped":[{"index":0,"reason":"unknown_code"}],"entries":[]}"#
                )
            }
            let admitted = try admit()
            let lossy = HealthKitSkippedRowRegister(storage: SkipRegisterBacking(lossy: true).storage)
            let page = await HealthKitSkippedRowRegister.$bound.withValue(lossy) {
                await importer(retry: nil).transmitSymptoms(Self.symptoms(1), requiring: admitted.lease)
            }
            #expect(HealthSyncCursorPolicy.installed.decide(page) != .commit)
        }

        @Test("a whole-call 422 holds for five sweeps, then the rows are registered, never accepted in silence")
        func wholeRefusalEndsInRegister() async throws {
            MockURLProtocol.install { request in Self.respond(request, status: 422, #"{"data":null,"error":"invalid"}"#) }
            let admitted = try admit()
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
            let symptomImporter = importer(retry: nil)
            var decisions: [HealthSyncCommitDecision] = []
            for _ in 0 ..< HealthKitBatchRejection.maxHeldSweeps {
                let page = await HealthKitSkippedRowRegister.$bound.withValue(register) {
                    await symptomImporter.transmitSymptoms(Self.symptoms(1), requiring: admitted.lease)
                }
                decisions.append(HealthSyncCursorPolicy.installed.decide(page))
            }
            #expect(decisions.dropLast().allSatisfy { $0 != .commit })
            #expect(decisions.last == .commit)
            #expect(await register.rows(ownerID: Self.owner).map(\.reason) == ["refused_4xx:422"])
        }

        // MARK: - 4. Module off pauses

        @Test("403 illness.disabled pauses the symptom page: cursor held, nothing parked or registered")
        func moduleOffPauses() async throws {
            MockURLProtocol.install { request in
                Self.respond(
                    request,
                    status: 403,
                    #"{"data":null,"error":"off","meta":{"errorCode":"illness.disabled","module":"illness"}}"#
                )
            }
            let admitted = try admit()
            let queue = Queue()
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
            let page = await HealthKitSkippedRowRegister.$bound.withValue(register) {
                await importer(retry: queue).transmitSymptoms(Self.symptoms(2), requiring: admitted.lease)
            }
            #expect(HealthSyncCursorPolicy.installed.decide(page) != .commit)
            #expect(await queue.symptomPages.isEmpty)
            #expect(await register.rows(ownerID: Self.owner).isEmpty)

            let held = await AppleHealthDeletionSender(
                send: { _, _ in throw HLError.moduleDisabled("illness") },
                queue: queue
            ).forward(["d-1"], to: .symptoms, requiring: admitted.lease)
            #expect(held != nil)
            #expect(await queue.deletions.isEmpty)
        }

        // MARK: - transmitPage: symptoms, prune, DELETE, offline

        @Test("a symptom page posts, prunes queued copies, then deletes; an offline delete waits in the outbox")
        func symptomPageWithDeletions() async throws {
            let seen = Seen()
            let deleteOffline = OSAllocatedUnfairLock(initialState: false)
            MockURLProtocol.install { request in
                if request.httpMethod == "DELETE", deleteOffline.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
                seen.note(request)
                return request.httpMethod == "DELETE"
                    ? Self.respond(request, #"{"data":{"deletedCount":1}}"#)
                    : Self.respond(
                        request,
                        #"{"processed":1,"inserted":1,"duplicates":0,"skipped":[],"entries":[{"index":0,"status":"inserted"}]}"#
                    )
            }
            let admitted = try admit()
            let queue = Queue()
            let symptomImporter = importer(retry: queue)
            let now = Date()
            let headache = HKCategorySample(
                type: HKCategoryType(.headache),
                value: HKCategoryValueSeverity.mild.rawValue,
                start: now.addingTimeInterval(-3600),
                end: now.addingTimeInterval(-3600)
            )
            let unit = EventSweepUnit(key: EventSweepUnit.symptomsKey, types: [HKCategoryType(.headache)], route: .symptoms)
            let page = EventSweepPage(samples: [headache], deletedIDs: ["gone-1"], newAnchor: nil)

            let outcome = await symptomImporter.transmitPage(page, of: unit, requiring: admitted.lease)
            #expect(HealthSyncCursorPolicy.installed.decide(outcome) == .commit)
            #expect(seen.all.map(\.path) == ["/api/symptoms/events/batch", "/api/symptoms/events/by-external-ids"])
            #expect(await queue.pruned == [["gone-1"]])

            deleteOffline.withLock { $0 = true }
            let offline = await symptomImporter.transmitPage(
                EventSweepPage(samples: [], deletedIDs: ["gone-2"], newAnchor: nil),
                of: unit,
                requiring: admitted.lease
            )
            #expect(HealthSyncCursorPolicy.installed.decide(offline) == .commit)
            #expect(await queue.deletions.map(\.1) == [["gone-2"]])
        }

        // MARK: - 3. Deletions while the route is closed

        @Test("deletions read while the route is closed wait and go out first once it opens")
        func pendingDeletionsWaitForTheRoute() async throws {
            let defaults = try #require(UserDefaults(suiteName: "pending-deletes-\(UUID().uuidString)"))
            let sent = OSAllocatedUnfairLock<[[String]]>(initialState: [])
            let send: @Sendable ([String]) async throws -> Void = { ids in sent.withLock { $0.append(ids) } }
            try await AppleHealthPendingDeletions.deliver(["w-1"], .workout, ownerID: "a", routeOpen: false, defaults: defaults, send: send)
            #expect(sent.withLock { $0 }.isEmpty)
            #expect(AppleHealthPendingDeletions.pending(.workout, ownerID: "a", defaults: defaults) == ["w-1"])

            await #expect(throws: URLError.self) {
                try await AppleHealthPendingDeletions.deliver(["w-2"], .workout, ownerID: "a", routeOpen: true, defaults: defaults) { _ in
                    throw URLError(.notConnectedToInternet)
                }
            }
            #expect(
                AppleHealthPendingDeletions.pending(.workout, ownerID: "a", defaults: defaults) == ["w-1"],
                "a failed send keeps the list"
            )

            try await AppleHealthPendingDeletions.deliver(["w-2"], .workout, ownerID: "a", routeOpen: true, defaults: defaults, send: send)
            #expect(sent.withLock { $0 } == [["w-1", "w-2"]])
            #expect(AppleHealthPendingDeletions.pending(.workout, ownerID: "a", defaults: defaults).isEmpty)
            #expect(AppleHealthPendingDeletions.pending(.ecg, ownerID: "a", defaults: defaults).isEmpty, "per route")
        }

        @Test("ECG: a deletion without the route waits; with it, the next sweep sends it")
        func ecgDeletionWaitsForCapability() async {
            let seen = Seen()
            MockURLProtocol.install { request in
                seen.note(request)
                return Self.respond(request, #"{"data":{"deletedCount":1}}"#)
            }
            let (api, keychain) = EcgSyncTestSupport.makeClient()
            let defaultsProvider = EcgSyncTestSupport.isolatedDefaults()
            let source = DeletingEcgSource(deleted: ["ecg-gone"])
            let withDeletes = EcgSyncCoordinator(
                source: source,
                repo: EcgRepository(api: api),
                keychain: keychain,
                isOptedIn: { true },
                defaultsProvider: defaultsProvider,
                anchorPersistenceOverride: nil,
                admission: nil,
                clock: { Date() }
            )
            await withDeletes.sync()
            #expect(seen.all.isEmpty, "no route yet")
            #expect(AppleHealthPendingDeletions.pending(.ecg, ownerID: "user-123", defaults: defaultsProvider()) == ["ecg-gone"])

            KnownServerVersion.record(ServerVersionInfo(version: "1.48.2"), defaults: defaultsProvider())
            source.deleted = []
            await withDeletes.sync()
            #expect(seen.all.map(\.path) == ["/api/insights/ecg/by-external-ids"])
            #expect(AppleHealthPendingDeletions.pending(.ecg, ownerID: "user-123", defaults: defaultsProvider()).isEmpty)
        }

        // MARK: - Mood

        @Test("State of Mind carries its source pair only behind the flag; deletions only after a committed page")
        func moodSourcePairAndDeleteOrder() async throws {
            let harness = try ModuleGateHarness()
            let bodies = OSAllocatedUnfairLock<[MoodBody]>(initialState: [])
            let seen = Seen()
            MockURLProtocol.install { request in
                seen.note(request)
                let body = request.httpBody ?? request.httpBodyStream.map(AppleHealthIngestV2WireTests.Wire.drain) ?? Data()
                if let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
                    let note = MoodBody(externalId: object["externalId"] as? String, source: object["source"] as? String)
                    bodies.withLock { $0.append(note) }
                }
                return ModuleGateHarness.moodResponse(for: request, moduleOn: true)
            }
            let sample = { (offset: Double) in
                HKStateOfMind(
                    date: Date(timeIntervalSince1970: 1_788_200_000 + offset),
                    kind: .momentaryEmotion,
                    valence: 0.4,
                    labels: [],
                    associations: []
                )
            }
            _ = await harness.importer.consume([sample(0)], requiring: harness.lease)
            #expect(bodies.withLock { $0 }.last?.externalId == nil)

            let defaults = harness.defaults
            KnownServerVersion.record(ServerVersionInfo(version: "1.48.2"), defaults: defaults)
            let flagged = sample(60)
            _ = await harness.importer.consume([flagged], requiring: harness.lease)
            #expect(bodies.withLock { $0 }.last?.externalId == flagged.uuid.uuidString)
            #expect(bodies.withLock { $0 }.last?.source == "APPLE_HEALTH")

            let before = seen.all.count
            let held = HealthSyncPageOutcome(
                postedCount: 1,
                entries: [HealthSyncEntryOutcome(index: 0, stableIdentity: "x", classification: .nonterminal)],
                transportThrew: true,
                durableRetryPersisted: false,
                durableRetryFailed: true,
                leaseIsCurrent: true,
                wasCancelled: false
            )
            #expect(await harness.importer.forwardDeletions(["m-1"], after: held, requiring: harness.lease) == nil)
            #expect(seen.all.count == before, "a held page sends no deletion")

            let committed = HealthSyncPageOutcome(
                postedCount: 0,
                entries: [],
                transportThrew: false,
                durableRetryPersisted: false,
                durableRetryFailed: false,
                leaseIsCurrent: true,
                wasCancelled: false
            )
            #expect(await harness.importer.forwardDeletions(["m-1"], after: committed, requiring: harness.lease) == nil)
            #expect(seen.all.last?.path == "/api/mood-entries/by-external-ids")
        }

        // MARK: - 5. Macro zero correction

        @Test("a deleted single day beside days that still read goes out as 0 once, then is forgotten")
        func macroZeroCorrection() throws {
            let defaults = try #require(UserDefaults(suiteName: "macro-ledger-\(UUID().uuidString)"))
            let ledger = NutrientMacroDayLedger(defaults: defaults, partition: "p")
            ledger.remember(
                [
                    NutrientIntakeEntryDTO(day: "2026-11-18", nutrient: .protein, unit: "g", amount: 50),
                    NutrientIntakeEntryDTO(day: "2026-11-01", nutrient: .protein, unit: "g", amount: 40),
                    NutrientIntakeEntryDTO(day: "2026-11-18", nutrient: .vitaminC, unit: "mg", amount: 80)
                ],
                oldestDay: "2026-10-01"
            )
            let neighbour = NutrientIntakeEntryDTO(day: "2026-11-19", nutrient: .protein, unit: "g", amount: 30)
            let corrected = ledger.withZeroCorrections([neighbour], fromDay: "2026-11-17", toDay: "2026-11-19")
            #expect(corrected == [neighbour, NutrientIntakeEntryDTO(day: "2026-11-18", nutrient: .protein, unit: "g", amount: 0)])
            #expect(!defaults.bool(forKey: NutrientMacroDayLedger.unreadableKey))
            ledger.remember(corrected, oldestDay: "2026-10-01")
            #expect(ledger.withZeroCorrections([neighbour], fromDay: "2026-11-17", toDay: "2026-11-19") == [neighbour])
            #expect(ledger.postedDays == ["protein|2026-11-01", "protein|2026-11-19"])
        }

        @Test("revoked read access (the whole window empty) sends nothing and flags the permissions")
        func macroWindowEmptySendsNothing() throws {
            let defaults = try #require(UserDefaults(suiteName: "macro-ledger-\(UUID().uuidString)"))
            let ledger = NutrientMacroDayLedger(defaults: defaults, partition: "p")
            ledger.remember(
                [
                    NutrientIntakeEntryDTO(day: "2026-11-18", nutrient: .protein, unit: "g", amount: 50),
                    NutrientIntakeEntryDTO(day: "2026-11-19", nutrient: .energy, unit: "kcal", amount: 1800)
                ],
                oldestDay: "2026-10-01"
            )
            #expect(ledger.withZeroCorrections([], fromDay: "2026-11-17", toDay: "2026-11-19").isEmpty)
            #expect(defaults.bool(forKey: NutrientMacroDayLedger.unreadableKey))
            #expect(ledger.postedDays.count == 2, "the totals stay remembered")
        }

        // MARK: - Workout deletions

        @Test("a workout deletion that meets a 5xx holds the anchor; the next sweep sends it again")
        func workoutDeletionHoldsAnchorOn5xx() async throws {
            let suite = "workout-deletes-\(UUID().uuidString)"
            try KnownServerVersion.record(ServerVersionInfo(version: "1.48.2"), defaults: #require(UserDefaults(suiteName: suite)))
            let source = DeletingWorkoutSource(deleted: ["w-gone"])
            let repo = FlakyWorkoutDeleter()
            let registry = WorkoutImportLeaseRegistry()
            let lease = registry.activate(ownerUserID: "user-A", authIsCurrent: { true })
            let importer = WorkoutHealthKitImporter(
                store: HKHealthStore(),
                repo: repo,
                userID: "user-A",
                defaultsBox: WorkoutDefaultsBox(suiteName: suite),
                lifecycleStore: InertWorkoutLifecycleStore(),
                anchoredQuerySource: source,
                lease: lease
            )
            _ = await importer.runBoundedPage(mode: .incrementalOnly)
            #expect(await repo.deleted == [], "the 5xx sent nothing")
            await repo.recover()
            _ = await importer.runBoundedPage(mode: .incrementalOnly)
            _ = await importer.runBoundedPage(mode: .incrementalOnly)
            await importer.stop()
            #expect(await repo.deleted == [["w-gone"], ["w-gone"]])
            let anchors = source.anchorsSeen
            #expect(anchors.count == 3)
            #expect(anchors[0] == false && anchors[1] == false, "the failed page left the anchor where it was")
            #expect(anchors[2], "the delivered page moved it")
        }

        // MARK: - Workout outbox rows

        @Test("a delete prunes a queued workout batch down to the workouts still alive")
        func workoutBatchPruned() async throws {
            let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
            let payload = Data(#"{"workouts":[{"externalId":"w-keep"},{"externalId":"w-gone"}]}"#.utf8)
            try await outbox.enqueue(.init(kind: .uploadWorkoutBatch, payload: payload, idempotencyKey: "wk"))
            let removed = await outbox.pruneQueuedAppleHealthUploads(.uploadWorkoutBatch, removing: ["w-gone"], ownerUserID: Self.owner)
            #expect(removed == 1)
            let rows = await outbox.snapshot
            let object = try #require(JSONSerialization.jsonObject(with: rows[0].payload) as? [String: Any])
            let ids = (object["workouts"] as? [[String: Any]])?.compactMap { $0["externalId"] as? String }
            #expect(ids == ["w-keep"])
        }
    }

    /// A workout source that reports deletions and no workouts, and notes
    /// whether each read started from a saved anchor.
    final class DeletingWorkoutSource: WorkoutAnchoredQueryFetching, @unchecked Sendable {
        private let lock = NSLock()
        private let deleted: [String]
        private var seen: [Bool] = []

        init(deleted: [String]) {
            self.deleted = deleted
        }

        var anchorsSeen: [Bool] {
            lock.withLock { seen }
        }

        func fetch(anchor: HKQueryAnchor?, limit _: Int) async throws -> WorkoutAnchoredQueryPage {
            lock.withLock { seen.append(anchor != nil) }
            return WorkoutAnchoredQueryPage(workouts: [], newAnchor: HKQueryAnchor(fromValue: 42), deletedIDs: deleted)
        }
    }

    /// Answers 503 to deletions until it recovers.
    actor FlakyWorkoutDeleter: WorkoutBatchUploading {
        private var healthy = false
        private(set) var deleted: [[String]] = []

        func recover() {
            healthy = true
        }

        func uploadBatch(_ workouts: [WorkoutIngestDTO], ownerUserID _: String) async throws -> WorkoutBatchResponseDTO {
            WorkoutBatchResponseDTO(processed: workouts.count, inserted: workouts.count, duplicates: 0, entries: [])
        }

        func deleteAppleHealthWorkouts(_ ids: [String], ownerUserID _: String) async throws {
            guard healthy else { throw HLError.server(status: 503, code: nil, message: "unavailable") }
            deleted.append(ids)
        }
    }

    actor InertWorkoutLifecycleStore: WorkoutHealthKitStore {
        func executeWorkoutObserver(onUpdate _: @escaping @Sendable () async -> Void) async {}
        func stopWorkoutObserver() async {}
        func enableWorkoutBackgroundDelivery() async throws {}
        func disableWorkoutBackgroundDelivery() async throws {}
    }

    /// An ECG source that reports deletions and no recordings.
    final class DeletingEcgSource: EcgRecordingSource, @unchecked Sendable {
        private let lock = NSLock()
        private var _deleted: [String]

        init(deleted: [String]) {
            _deleted = deleted
        }

        var deleted: [String] {
            get { lock.withLock { _deleted } }
            set { lock.withLock { _deleted = newValue } }
        }

        func fetchRecordings(since _: Data?) async throws -> EcgSourceFetchResult {
            EcgSourceFetchResult(recordings: [], anchor: Data("anchor-\(UUID().uuidString)".utf8), deletedIDs: deleted)
        }

        func voltages(forRecordingID _: String) async throws -> [Double] {
            []
        }
    }

#endif

// swiftlint:enable force_unwrapping file_length type_body_length
