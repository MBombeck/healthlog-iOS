import Foundation
import Testing
#if !SWIFT_PACKAGE

    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif
    @testable import HealthLog

    // v0.11 W4 — adopt-on-pair upload tests. Drive `StandaloneAdoptUploadService`
    // over a recording stub `APIClient`, asserting: every local row uploads via
    // the right batch endpoint, externalId is preserved, the med-id remap is
    // correct (local→server), chunking boundaries hold, and a re-run is
    // idempotent (same externalIds re-sent — the server dedups).
    //
    // App-target only (`#if !SWIFT_PACKAGE`) — the service + `LocalBackfillBundle`
    // live in the iOS-only `Standalone/` module, not `HealthLogCore`.

    // swiftlint:disable force_unwrapping force_try

    // MARK: - Recording stub API

    /// Records every request's path + decoded body so the assertions can inspect
    /// what was sent. Returns an all-`inserted` envelope for batch routes and a
    /// fresh medication wire DTO (server-assigned id) for `POST /api/medications`.
    private final class RecordingAdoptAPI: APIClientProtocol, @unchecked Sendable {
        struct Recorded {
            let path: String
            let method: HTTPMethod
            let body: Data?
        }

        private let lock = NSLock()
        private var _calls: [Recorded] = []
        /// Maps each created medication to a deterministic server id so tests can
        /// assert the local→server remap. Key = the create body's `name`.
        private var _medSeq = 0
        /// v0.13 WR — a med the stub "server" already holds, returned on GET
        /// `/api/medications` so the client-side `(name, dose)` dedup can match.
        struct ServerMed {
            let id: String
            let name: String
            let dose: String
        }

        /// v0.13 WR — the server's existing meds, returned on GET `/api/medications`
        /// so the client-side `(name, dose)` dedup can match a re-run's defs.
        private var _serverMeds: [ServerMed] = []
        /// v0.13 WR — per-path attempt counters for the fail injector.
        private var _attemptsByPath: [String: Int] = [:]
        /// v0.13 WR — optional fault injection: returns `true` to FAIL the call
        /// to `path` on its `attempt`-th occurrence (1-based). The call is still
        /// recorded before throwing, mirroring a real partial-failure chunk.
        var failInjector: (@Sendable (_ path: String, _ attempt: Int) -> Bool)?

        var calls: [Recorded] {
            lock.withLock { _calls }
        }

        func calls(toPath path: String) -> [Recorded] {
            calls.filter { $0.path == path }
        }

        /// POST-only calls to a path (so the dedup pre-check GET doesn't inflate
        /// the create count in assertions).
        func posts(toPath path: String) -> [Recorded] {
            calls.filter { $0.path == path && $0.method == .post }
        }

        static func decoder() -> JSONDecoder {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            return d
        }

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            let attempt = lock.withLock { () -> Int in
                _calls.append(Recorded(path: request.path, method: request.method, body: request.body))
                let n = (_attemptsByPath[request.path] ?? 0) + 1
                _attemptsByPath[request.path] = n
                return n
            }
            if failInjector?(request.path, attempt) == true {
                throw HLError.unknown("injected failure: \(request.path) attempt \(attempt)")
            }

            switch request.path {
            case "/api/medications" where request.method == .get:
                // v0.13 WR — the dedup pre-check. Return the meds created so far
                // as a `[MedicationWireDTO]` so a re-run matches by (name, dose).
                let meds = lock.withLock { _serverMeds }
                let json = "[" + meds.map {
                    #"{"id":"\#($0.id)","name":"\#($0.name)","dose":"\#($0.dose)","active":true}"#
                }.joined(separator: ",") + "]"
                let wires = try Self.decoder().decode([MedicationWireDTO].self, from: Data(json.utf8))
                guard let typed = wires as? T else { throw HLError.unknown("stub T mismatch med-list") }
                return typed

            case "/api/medications":
                // POST — create. Return a wire DTO with a deterministic server id
                // derived from the create order so the remap is assertable, and
                // record it so a later GET (re-run dedup) can match it.
                let create = try Self.decoder().decode(MedicationsRepository.MedicationCreate.self, from: request.body!)
                let id = lock.withLock { () -> String in
                    _medSeq += 1
                    let newID = "server-med-\(_medSeq)"
                    _serverMeds.append(ServerMed(id: newID, name: create.name, dose: create.dose))
                    return newID
                }
                let json = #"{"id":"\#(id)","name":"\#(create.name)","dose":"\#(create.dose)","active":true}"#
                let wire = try Self.decoder().decode(MedicationWireDTO.self, from: Data(json.utf8))
                guard let typed = wire as? T else { throw HLError.unknown("stub T mismatch med") }
                return typed

            case "/api/measurements/batch":
                let payload = try Self.decoder().decode(HealthKitBatchPayload.self, from: request.body!)
                let entries = payload.entries.enumerated().map { idx, _ in
                    HealthKitBatchResponseDTO.EntryResult(index: idx, status: .inserted)
                }
                let resp = HealthKitBatchResponseDTO(
                    processed: payload.entries.count,
                    inserted: payload.entries.count,
                    duplicates: 0,
                    skipped: [],
                    entries: entries
                )
                guard let typed = resp as? T else { throw HLError.unknown("stub T mismatch batch") }
                return typed

            case "/api/mood-entries/bulk", "/api/medications/intake/bulk":
                // Both return the shared bulk envelope.
                let count = try Self.bulkEntryCount(path: request.path, body: request.body!)
                let resp = BulkUpsertResponseDTO(
                    processed: count, inserted: count, updated: 0, duplicates: 0
                )
                guard let typed = resp as? T else { throw HLError.unknown("stub T mismatch bulk") }
                return typed

            default:
                throw HLError.unknown("unexpected path \(request.path)")
            }
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {}
        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.unknown("not implemented")
        }

        static func bulkEntryCount(path: String, body: Data) throws -> Int {
            if path == "/api/mood-entries/bulk" {
                return try decoder().decode(BulkMoodPayload.self, from: body).entries.count
            }
            return try decoder().decode(BulkIntakePayload.self, from: body).entries.count
        }
    }

    /// Provider that resolves any local med id to a minimal create body.
    private struct AlwaysProvider: AdoptMedicationDefinitionProviding {
        func medicationDefinition(forLocalId localId: String) async -> MedicationsRepository.MedicationCreate? {
            MedicationsRepository.MedicationCreate(name: "Med-\(localId)", dose: "1")
        }
    }

    /// Provider that resolves nothing — exercises the "no definition → skip" path.
    private struct NeverProvider: AdoptMedicationDefinitionProviding {
        func medicationDefinition(forLocalId _: String) async -> MedicationsRepository.MedicationCreate? {
            nil
        }
    }

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func measurement(_ kind: String, _ value: Double, ext: String) -> LocalMeasurementSnapshot {
        LocalMeasurementSnapshot(
            externalId: ext, kind: kind, value: value, unit: "", recordedAt: fixedDate, createdAt: fixedDate
        )
    }

    private func mood(_ score: Int, ext: String) -> LocalMoodSnapshot {
        LocalMoodSnapshot(externalId: ext, score: score, recordedAt: fixedDate, createdAt: fixedDate)
    }

    private func intake(med: String, status: String, ext: String) -> LocalIntakeSnapshot {
        LocalIntakeSnapshot(
            externalId: ext, medicationId: med, takenAt: fixedDate, status: status, createdAt: fixedDate
        )
    }

    // MARK: - Full upload

    @Suite("StandaloneAdoptUploadService — full upload")
    struct AdoptUploadFullTests {
        @Test("Uploads measurements + moods + intakes via their batch endpoints; externalId preserved")
        func uploadsAll() async throws {
            let api = RecordingAdoptAPI()
            let svc = StandaloneAdoptUploadService(api: api, medicationProvider: AlwaysProvider())
            let bundle = LocalBackfillBundle(
                measurements: [
                    measurement("weight", 80, ext: "m-1"),
                    measurement("pulse", 60, ext: "m-2")
                ],
                moods: [mood(4, ext: "mo-1")],
                intakes: [intake(med: "local-med-A", status: "taken", ext: "i-1")]
            )

            let progress = try await svc.run(bundle: bundle)

            // 2 measurements + 1 mood + 1 intake = 4 rows.
            #expect(progress.total == 4)
            #expect(progress.completed == 4)
            #expect(progress.fraction == 1)

            // One measurements/batch call carrying both externalIds.
            let batch = api.calls(toPath: "/api/measurements/batch")
            #expect(batch.count == 1)
            let batchBody = try RecordingAdoptAPI.decoder().decode(HealthKitBatchPayload.self, from: #require(batch[0].body))
            #expect(Set(batchBody.entries.map(\.externalId)) == ["m-1", "m-2"])
            // Manual rows are tagged MANUAL via the projection's wire entry.
            #expect(batchBody.entries.allSatisfy { $0.hkIdentifier.hasPrefix("HKQuantityTypeIdentifier") })

            // One mood bulk carrying the mood externalId.
            let moodCalls = api.calls(toPath: "/api/mood-entries/bulk")
            #expect(moodCalls.count == 1)
            let moodBody = try RecordingAdoptAPI.decoder().decode(BulkMoodPayload.self, from: #require(moodCalls[0].body))
            #expect(moodBody.entries.map(\.externalId) == ["mo-1"])
            #expect(moodBody.entries[0].mood == "GUT") // score 4 → GUT

            // One medication created, then one intake bulk referencing the server id.
            #expect(api.posts(toPath: "/api/medications").count == 1)
            let intakeCalls = api.calls(toPath: "/api/medications/intake/bulk")
            #expect(intakeCalls.count == 1)
            let intakeBody = try RecordingAdoptAPI.decoder().decode(BulkIntakePayload.self, from: #require(intakeCalls[0].body))
            #expect(intakeBody.entries.count == 1)
            // Remapped to the server id, NOT the local id.
            #expect(intakeBody.entries[0].medicationId == "server-med-1")
            // The local externalId rides through as the per-entry idempotency key.
            #expect(intakeBody.entries[0].idempotencyKey == "i-1")
        }

        @Test("Empty bundle → no requests, vacuously done")
        func emptyBundle() async throws {
            let api = RecordingAdoptAPI()
            let svc = StandaloneAdoptUploadService(api: api, medicationProvider: AlwaysProvider())
            let progress = try await svc.run(bundle: LocalBackfillBundle(measurements: [], moods: [], intakes: []))
            #expect(progress.total == 0)
            #expect(progress.fraction == 1)
            #expect(api.calls.isEmpty)
        }
    }

    // MARK: - Med-id remap

    @Suite("StandaloneAdoptUploadService — medication remap")
    struct AdoptUploadRemapTests {
        @Test("Distinct local meds each create one server med; intakes remap correctly")
        func distinctMedsRemap() async throws {
            let api = RecordingAdoptAPI()
            let svc = StandaloneAdoptUploadService(api: api, medicationProvider: AlwaysProvider())
            let bundle = LocalBackfillBundle(
                measurements: [],
                moods: [],
                intakes: [
                    intake(med: "local-A", status: "taken", ext: "iA-1"),
                    intake(med: "local-A", status: "skipped", ext: "iA-2"),
                    intake(med: "local-B", status: "taken", ext: "iB-1")
                ]
            )

            _ = try await svc.run(bundle: bundle)

            // Two distinct local meds → two medication creates.
            #expect(api.posts(toPath: "/api/medications").count == 2)

            let intakeCalls = api.calls(toPath: "/api/medications/intake/bulk")
            #expect(intakeCalls.count == 1)
            let body = try RecordingAdoptAPI.decoder().decode(BulkIntakePayload.self, from: #require(intakeCalls[0].body))
            #expect(body.entries.count == 3)
            // Every server id is one of the two created ids; the two local-A
            // intakes share one server id, local-B has the other.
            let serverIds = Set(body.entries.map(\.medicationId))
            #expect(serverIds == ["server-med-1", "server-med-2"])
            // The skip carries `skipped == true` + no takenAt.
            let skip = try #require(body.entries.first { $0.idempotencyKey == "iA-2" })
            #expect(skip.skipped)
            #expect(skip.takenAt == nil)
            // The taken carries takenAt + skipped false.
            let taken = try #require(body.entries.first { $0.idempotencyKey == "iA-1" })
            #expect(!taken.skipped)
            #expect(taken.takenAt != nil)
        }

        @Test("Unresolvable medication → its intakes are skipped, not fabricated")
        func unresolvableMedSkipped() async throws {
            let api = RecordingAdoptAPI()
            let svc = StandaloneAdoptUploadService(api: api, medicationProvider: NeverProvider())
            let bundle = LocalBackfillBundle(
                measurements: [],
                moods: [],
                intakes: [intake(med: "local-X", status: "taken", ext: "iX-1")]
            )
            let progress = try await svc.run(bundle: bundle)
            // No medication created, no intake bulk fired, nothing counted.
            #expect(api.posts(toPath: "/api/medications").isEmpty)
            #expect(api.calls(toPath: "/api/medications/intake/bulk").isEmpty)
            #expect(progress.total == 0)
        }
    }

    // MARK: - Chunking

    @Suite("StandaloneAdoptUploadService — chunking")
    struct AdoptUploadChunkTests {
        @Test("Measurements above the chunk size page into multiple batch POSTs")
        func measurementsChunk() async throws {
            let api = RecordingAdoptAPI()
            let svc = StandaloneAdoptUploadService(api: api, medicationProvider: AlwaysProvider())
            // 450 weight rows → 3 chunks of 200/200/50 (chunkSize = 200).
            let rows = (0 ..< 450).map { measurement("weight", Double($0), ext: "w-\($0)") }
            let bundle = LocalBackfillBundle(measurements: rows, moods: [], intakes: [])

            _ = try await svc.run(bundle: bundle)

            let batch = api.calls(toPath: "/api/measurements/batch")
            #expect(batch.count == 3)
            let sizes = try batch.map {
                try RecordingAdoptAPI.decoder().decode(HealthKitBatchPayload.self, from: $0.body!).entries.count
            }
            #expect(sizes == [200, 200, 50])
        }

        @Test("Blood-pressure fans out to two batch legs sharing the externalId")
        func bpFanOut() async throws {
            let api = RecordingAdoptAPI()
            let svc = StandaloneAdoptUploadService(api: api, medicationProvider: AlwaysProvider())
            let bp = LocalMeasurementSnapshot(
                externalId: "bp-1", kind: "bloodPressure", value: 0, unit: "mmHg",
                systolic: 120, diastolic: 80, recordedAt: fixedDate, createdAt: fixedDate
            )
            _ = try await svc.run(bundle: LocalBackfillBundle(measurements: [bp], moods: [], intakes: []))

            let batch = api.calls(toPath: "/api/measurements/batch")
            #expect(batch.count == 1)
            let body = try RecordingAdoptAPI.decoder().decode(HealthKitBatchPayload.self, from: #require(batch[0].body))
            // Two legs, same externalId, distinct HK identifiers.
            #expect(body.entries.count == 2)
            #expect(body.entries.allSatisfy { $0.externalId == "bp-1" })
            #expect(Set(body.entries.map(\.hkIdentifier)) == [
                "HKQuantityTypeIdentifierBloodPressureSystolic",
                "HKQuantityTypeIdentifierBloodPressureDiastolic"
            ])
            #expect(body.entries.contains { $0.value == 120 })
            #expect(body.entries.contains { $0.value == 80 })
        }
    }

    // MARK: - AuthStore hook (standalone→paired detection)

    @MainActor
    @Suite("AuthStore adopt-on-pair hook")
    struct AuthStoreAdoptHookTests {
        private final class NoopPasskey: PasskeyServiceProtocol, @unchecked Sendable {
            func register(
                challenge _: String, rpId _: String, rpName _: String,
                userID _: String, userName _: String, displayName _: String,
                anchor _: ASPresentationAnchorProvider
            ) async throws -> PasskeyRegistration {
                throw HLError.unknown("noop")
            }

            func assert(
                challenge _: String, rpId _: String, allowCredentialIDs _: [String],
                anchor _: ASPresentationAnchorProvider
            ) async throws -> PasskeyAssertion {
                throw HLError.unknown("noop")
            }
        }

        /// Box the hook can flip from its `@Sendable` closure (it runs in a
        /// detached Task on the main actor).
        private final class FireBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _fired = false
            var fired: Bool {
                lock.withLock { _fired }
            }

            func markFired() {
                lock.withLock { _fired = true }
            }
        }

        /// Counts hook invocations (re-run proof for the retry test).
        private final class AttemptBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _count = 0
            var count: Int {
                lock.withLock { _count }
            }

            func next() -> Int {
                lock.withLock { _count += 1
                    return _count
                }
            }
        }

        private func makeStore(initialMode: SyncMode) -> (AuthStore, SyncModeStore) {
            let keychain = InMemoryKeychain()
            let suite = "hl.tests.adopt.hook.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            defaults.set(initialMode.rawValue, forKey: SyncModeStore.storageKey)
            let sync = SyncModeStore(defaults: defaults)
            let env = AppEnvironment.loadFromBundle()
            let api = APIClient(environment: env, keychain: keychain)
            let auth = AuthService(api: api, keychain: keychain, passkey: NoopPasskey())
            return (AuthStore(auth: auth, keychain: keychain, syncMode: sync), sync)
        }

        private func user() -> User {
            User(id: "u1", email: nil, username: nil, displayName: "T", createdAt: .now)
        }

        @Test("standalone→paired transition fires the upload hook")
        func standaloneToPairedFires() async throws {
            let (store, sync) = makeStore(initialMode: .standalone)
            let box = FireBox()
            store.adoptUploadHook = { _ in
                box.markFired()
                return .success(AdoptUploadProgress(completed: 1, total: 1))
            }
            // The standalone user begins pairing — sets the intent flag.
            sync.setOnboardingChoice(.standalone) // ensure live mode reads standalone
            store.beginServerPairing()
            // Re-pick server + log in → terminal `.authenticated` consumes the flag.
            store.setPhaseForTesting(.authenticating(user()))
            store.completeOnboarding()
            // The hook runs in a detached Task; let it land.
            try await Task.sleep(nanoseconds: 200_000_000)
            #expect(box.fired)
            // The state surfaced a terminal `.done`.
            if case .done = store.adoptUploadState {} else {
                Issue.record("expected .done, got \(store.adoptUploadState)")
            }
        }

        /// v0.13 WR — a failed adopt re-arms `pendingAdoptUpload`, so a manual
        /// `retryAdoptUpload()` re-fires the hook. The first run fails (→ `.failed`),
        /// the retry succeeds (→ `.done`). Proves the recovery path exists.
        @Test("failed adopt re-arms; manual retry re-runs to .done")
        func failedAdoptRetrySucceeds() async throws {
            let (store, sync) = makeStore(initialMode: .standalone)
            let attempts = AttemptBox()
            store.adoptUploadHook = { _ in
                let n = attempts.next()
                if n == 1 {
                    return .failure(AdoptUploadError.chunkFailed(phase: "intakes", completed: 1, total: 2))
                }
                return .success(AdoptUploadProgress(completed: 2, total: 2))
            }
            sync.setOnboardingChoice(.standalone)
            store.beginServerPairing()
            store.setPhaseForTesting(.authenticating(user()))
            store.completeOnboarding()
            try await Task.sleep(nanoseconds: 200_000_000)
            // First run failed.
            if case .failed = store.adoptUploadState {} else {
                Issue.record("expected .failed after first run, got \(store.adoptUploadState)")
            }

            // Manual retry (behind the failed banner) re-runs the (idempotent) upload.
            store.retryAdoptUpload()
            try await Task.sleep(nanoseconds: 200_000_000)
            #expect(attempts.count == 2)
            if case .done = store.adoptUploadState {} else {
                Issue.record("expected .done after retry, got \(store.adoptUploadState)")
            }
        }

        @Test("normal paired login (no prior standalone) does NOT fire the hook")
        func pairedFromStartDoesNotFire() async throws {
            let (store, _) = makeStore(initialMode: .paired)
            let box = FireBox()
            store.adoptUploadHook = { _ in
                box.markFired()
                return .success(AdoptUploadProgress(completed: 0, total: 0))
            }
            // A paired-from-start login never calls `beginServerPairing()`.
            store.setPhaseForTesting(.authenticating(user()))
            store.completeOnboarding()
            try await Task.sleep(nanoseconds: 200_000_000)
            #expect(!box.fired)
            #expect(store.adoptUploadState == .idle)
        }
    }

    // MARK: - Idempotency (re-run)

    @Suite("StandaloneAdoptUploadService — idempotent re-run")
    struct AdoptUploadIdempotencyTests {
        @Test("A re-run re-sends the SAME externalIds (server dedups → no dupes)")
        func rerunSameExternalIds() async throws {
            let api = RecordingAdoptAPI()
            let svc = StandaloneAdoptUploadService(api: api, medicationProvider: AlwaysProvider())
            let bundle = LocalBackfillBundle(
                measurements: [measurement("weight", 80, ext: "m-1")],
                moods: [mood(3, ext: "mo-1")],
                intakes: [intake(med: "local-A", status: "taken", ext: "i-1")]
            )

            _ = try await svc.run(bundle: bundle)
            _ = try await svc.run(bundle: bundle)

            // Two measurement batches (one per run), both carrying the same id.
            let batches = api.calls(toPath: "/api/measurements/batch")
            #expect(batches.count == 2)
            for call in batches {
                let body = try RecordingAdoptAPI.decoder().decode(HealthKitBatchPayload.self, from: #require(call.body))
                #expect(body.entries.map(\.externalId) == ["m-1"])
            }

            // Both intake bulks reuse the same idempotencyKey (server dedup hint).
            let intakes = api.calls(toPath: "/api/medications/intake/bulk")
            #expect(intakes.count == 2)
            for call in intakes {
                let body = try RecordingAdoptAPI.decoder().decode(BulkIntakePayload.self, from: #require(call.body))
                #expect(body.entries.map(\.idempotencyKey) == ["i-1"])
            }
        }

        /// v0.13 WR — headline fix: run 2's GET pre-check matches run 1's med by
        /// (name, dose) → no 2nd POST, yet the intake remaps to the same id.
        @Test("Re-run dedups medications client-side — exactly one create across two runs")
        func rerunDoesNotDuplicateMeds() async throws {
            let api = RecordingAdoptAPI()
            let svc = StandaloneAdoptUploadService(api: api, medicationProvider: AlwaysProvider())
            let bundle = LocalBackfillBundle(
                measurements: [],
                moods: [],
                intakes: [intake(med: "local-A", status: "taken", ext: "i-1")]
            )

            _ = try await svc.run(bundle: bundle)
            _ = try await svc.run(bundle: bundle)

            // Exactly ONE medication CREATE across both runs (the re-run matched
            // the existing server med instead of duplicating it).
            #expect(api.posts(toPath: "/api/medications").count == 1)

            // Both intake bulks still remap to the SAME (single) server med id.
            let intakes = api.calls(toPath: "/api/medications/intake/bulk")
            #expect(intakes.count == 2)
            for call in intakes {
                let body = try RecordingAdoptAPI.decoder().decode(BulkIntakePayload.self, from: #require(call.body))
                #expect(body.entries.map(\.medicationId) == ["server-med-1"])
            }
        }

        /// v0.13 WR — partial failure (intake chunk fails after the med create),
        /// then retry: must reuse the med (no duplicate) and complete the intakes.
        @Test("Partial failure then retry: med created once, intakes complete on retry")
        func partialFailureThenRetryNoDuplicate() async throws {
            let api = RecordingAdoptAPI()
            // Fail the FIRST intake-bulk call (after the med was created), succeed
            // thereafter — a partial-failure chunk the caller will retry.
            api.failInjector = { path, attempt in
                path == "/api/medications/intake/bulk" && attempt == 1
            }
            let svc = StandaloneAdoptUploadService(api: api, medicationProvider: AlwaysProvider())
            let bundle = LocalBackfillBundle(
                measurements: [],
                moods: [],
                intakes: [intake(med: "local-A", status: "taken", ext: "i-1")]
            )

            // First run: med is created, then the intake chunk throws.
            await #expect(throws: AdoptUploadError.self) {
                _ = try await svc.run(bundle: bundle)
            }
            #expect(api.posts(toPath: "/api/medications").count == 1)

            // Retry (caller re-runs the same bundle from the intact local mirror):
            // the GET pre-check matches the existing med, so NO second create; the
            // intake now succeeds.
            _ = try await svc.run(bundle: bundle)

            // Still exactly one create across both runs.
            #expect(api.posts(toPath: "/api/medications").count == 1)
            // The intake completed on the retry, remapped to the single server id.
            let intakes = api.calls(toPath: "/api/medications/intake/bulk")
            #expect(intakes.count == 2) // one failed attempt + one success
            let lastBody = try RecordingAdoptAPI.decoder().decode(
                BulkIntakePayload.self, from: #require(intakes.last?.body)
            )
            #expect(lastBody.entries.map(\.medicationId) == ["server-med-1"])
            #expect(lastBody.entries.map(\.idempotencyKey) == ["i-1"])
        }
    }

#endif
