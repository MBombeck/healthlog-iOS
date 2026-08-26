// v0.13 W5 — locks the standalone offline medication-definition store end-to-end.
//
// The load-bearing acceptances:
//  1. LocalStore med CRUD round-trips (create → list → update → archive) and the
//     Sendable snapshot crosses the actor boundary intact (schedule survives).
//  2. Standalone `list()` returns the created meds; create→take produces an
//     intake that reads back (no vanishing write).
//  3. Standalone compliance computes a REAL recurrence-based denominator
//     (NOT a flat 100% from taken==scheduled).
//  4. NO `/api/*` fires in standalone for list / create / compliance(medicationID:).
//  5. Adopt-on-pair uploads a standalone med + its intakes (idempotent) and
//     KEEPS the local mirror.
//
// Refs: .planning/v013-standalone/research/RESEARCH-standalone-persistence-truth.md
//       (H1/M1/M2) + DECISIONS.md D3.

// swiftlint:disable force_unwrapping force_try

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @MainActor
    @Suite("Standalone medications (W5)", .serialized)
    struct StandaloneMedicationsTests {
        private struct EmptyHK: StandaloneHealthKitReadServing {
            func standaloneRecentSamples(kind _: MetricKind, days _: Int, limit _: Int) async -> [SeriesPoint] {
                []
            }

            func standaloneDailySeries(kind _: MetricKind, days _: Int) async -> [SeriesPoint] {
                []
            }
        }

        private final class CallRecorder: @unchecked Sendable {
            nonisolated(unsafe) var hits = 0
            nonisolated(unsafe) var paths: [String] = []
            var firedNetwork: Bool {
                hits > 0
            }
        }

        private func makeAPI(recorder: CallRecorder) -> APIClient {
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            MockURLProtocol.handler = { req in
                recorder.hits += 1
                recorder.paths.append(req.url?.path ?? "")
                throw URLError(.notConnectedToInternet, userInfo: ["path": req.url?.path ?? ""])
            }
            return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        }

        private func makeLocal() throws -> LocalRepository {
            try LocalRepository(store: LocalStore(modelContainer: LocalStore.makeInMemory()))
        }

        private func makeGate(local: LocalRepository, standalone: Bool) -> StandaloneGate {
            StandaloneGate(local: local, healthKit: EmptyHK(), isStandalone: { standalone })
        }

        private func makeRepo(local: LocalRepository, standalone: Bool, recorder: CallRecorder) throws -> MedicationsRepository {
            try MedicationsRepository(
                api: makeAPI(recorder: recorder),
                outbox: OutboxQueue(inMemory: true),
                standalone: makeGate(local: local, standalone: standalone)
            )
        }

        /// A simple daily schedule at 08:00 (the engine's most common cadence).
        private func dailySchedule(at time: String = "08:00") -> MedicationScheduleDTO {
            MedicationScheduleDTO(windowStart: time, timesOfDay: [time], rrule: "FREQ=DAILY")
        }

        private func createBody(
            name: String = "Lisinopril",
            dose: String = "5mg",
            schedules: [MedicationScheduleDTO]? = nil
        ) -> MedicationsRepository.MedicationCreate {
            MedicationsRepository.MedicationCreate(
                name: name,
                dose: dose,
                schedules: schedules ?? [dailySchedule()],
                deliveryForm: "ORAL"
            )
        }

        // MARK: - 1. LocalStore med CRUD round-trip + snapshot crossing

        @Test("LocalStore med CRUD: create → list → update → archive round-trips")
        func medStoreCRUD() async throws {
            let local = try makeLocal()
            let schedJSON = try JSONEncoder().encode([dailySchedule()])
            let snap = LocalMedicationSnapshot(
                externalId: "loc-1",
                name: "Lisinopril",
                dose: "5mg",
                deliveryForm: "ORAL",
                schedulesJSON: schedJSON,
                createdAt: .now
            )
            let saved = try await local.addMedication(snap)
            #expect(saved.externalId == "loc-1")

            // list returns it + the schedule decodes (snapshot crossed intact).
            let listed = try await local.medications()
            #expect(listed.count == 1)
            #expect(listed.first?.name == "Lisinopril")
            #expect(listed.first?.schedules.first?.windowStart == "08:00")

            // update (rename + dose).
            let updated = LocalMedicationSnapshot(
                externalId: "loc-1",
                name: "Lisinopril forte",
                dose: "10mg",
                deliveryForm: "ORAL",
                schedulesJSON: schedJSON,
                createdAt: saved.createdAt
            )
            try await local.updateMedication(updated)
            let afterUpdate = try await local.medication(externalId: "loc-1")
            #expect(afterUpdate?.name == "Lisinopril forte")
            #expect(afterUpdate?.dose == "10mg")

            // archive → drops off the active list, stays in includeArchived.
            try await local.archiveMedication(externalId: "loc-1", archivedAt: .now)
            #expect(try await local.medications().isEmpty)
            let all = try await local.medications(includeArchived: true)
            #expect(all.count == 1)
            #expect(all.first?.archived == true)
        }

        // MARK: - 2. Standalone list() + create + take read-back, no network

        @Test("Standalone list() returns created meds; create+take reads back, no /api/*")
        func standaloneCreateTakeReadBack() async throws {
            let recorder = CallRecorder()
            let local = try makeLocal()
            let repo = try makeRepo(local: local, standalone: true, recorder: recorder)

            // create lands a definition in the mirror (no network).
            let created = try await repo.create(createBody())
            #expect(created.name == "Lisinopril")
            #expect(!created.schedule.entries.isEmpty)

            // list() now surfaces it.
            let meds = try await repo.list()
            #expect(meds.contains { $0.id == created.id && $0.name == "Lisinopril" })

            // take a dose against the created med → reads back in today.
            let intake = try await repo.recordStandaloneIntake(
                medicationId: created.id, scheduledAt: .now, status: .taken
            )
            #expect(intake.status == .taken)
            let today = try await repo.todayIntakes()
            #expect(today.contains { $0.medicationId == created.id && $0.status == .taken })

            #expect(!recorder.firedNetwork, "standalone create/list/take must fire ZERO /api/* calls")
        }

        // MARK: - 3. Real recurrence-based compliance (not flat 100%)

        @Test("Standalone compliance computes a real denominator over local defs")
        func standaloneRealCompliance() async throws {
            let recorder = CallRecorder()
            let local = try makeLocal()
            let repo = try makeRepo(local: local, standalone: true, recorder: recorder)

            // A daily med spanning the whole window, but only ONE dose logged.
            let created = try await repo.create(createBody())
            _ = try await repo.recordStandaloneIntake(
                medicationId: created.id, scheduledAt: .now, status: .taken
            )

            let comp = try await repo.standaloneCompliance(days: 7)
            // The daily schedule emits ~7 scheduled doses; only 1 taken ⇒ the
            // aggregate rate must be well BELOW 100% (not the old taken==scheduled).
            let totalScheduled = comp.reduce(0) { $0 + $1.scheduled }
            let totalTaken = comp.reduce(0) { $0 + $1.taken }
            #expect(totalTaken == 1)
            #expect(totalScheduled >= 6, "a daily 7-day schedule should expect ≥6 doses, got \(totalScheduled)")
            #expect(totalScheduled > totalTaken, "denominator must exceed taken (real cadence, not flat 100%)")

            // per-medication card compliance also reflects the cadence.
            let payload = try await repo.compliance(medicationID: created.id)
            #expect(payload.compliance7.totalExpected >= 6)
            #expect(payload.compliance7.taken == 1)
            #expect(payload.compliance7.rate < 100)

            #expect(!recorder.firedNetwork)
        }

        // MARK: - 4. No /api/* on the gated paths

        @Test("Standalone compliance(medicationID:) fires ZERO /api/* (M1 gate)")
        func cardComplianceNoNetwork() async throws {
            let recorder = CallRecorder()
            let local = try makeLocal()
            let repo = try makeRepo(local: local, standalone: true, recorder: recorder)
            let created = try await repo.create(createBody())
            _ = try await repo.compliance(medicationID: created.id)
            #expect(!recorder.firedNetwork, "compliance(medicationID:) must be gated in standalone")
            #expect(!recorder.paths.contains { $0.contains("/compliance") })
        }

        @Test("Paired compliance(medicationID:) DOES hit the network (gate inert)")
        func cardCompliancePairedHitsNetwork() async throws {
            let recorder = CallRecorder()
            let local = try makeLocal()
            let repo = try makeRepo(local: local, standalone: false, recorder: recorder)
            _ = try? await repo.compliance(medicationID: "srv-1")
            #expect(recorder.firedNetwork, "paired card-compliance must reach /api/medications/<id>/compliance")
        }

        // MARK: - 5. Update / archive round-trip through the repo

        @Test("Standalone repo update + delete(archive) round-trip, no network")
        func standaloneUpdateArchiveRepo() async throws {
            let recorder = CallRecorder()
            let local = try makeLocal()
            let repo = try makeRepo(local: local, standalone: true, recorder: recorder)
            let created = try await repo.create(createBody())

            let updated = try await repo.update(id: created.id, patch: .init(dose: "10mg"))
            #expect(updated.dose == "10mg")
            // Schedule preserved (nil schedules in the patch is RMW-safe).
            #expect(!updated.schedule.entries.isEmpty)

            try await repo.delete(id: created.id)
            #expect(try await repo.list().isEmpty)
            // Archived definition still resolvable for adopt-on-pair.
            #expect(try await local.medication(externalId: created.id)?.archived == true)

            #expect(!recorder.firedNetwork)
        }

        // MARK: - 6. Adopt-on-pair uploads med + intakes, keeps mirror

        @Test("Adopt-on-pair uploads a standalone med + its intakes, keeps the local mirror")
        func adoptOnPairUploadsAndKeepsMirror() async throws {
            let recorder = CallRecorder()
            let local = try makeLocal()
            // Build a standalone med + a logged intake against it.
            let stdRepo = try makeRepo(local: local, standalone: true, recorder: recorder)
            let created = try await stdRepo.create(createBody())
            _ = try await stdRepo.recordStandaloneIntake(
                medicationId: created.id, scheduledAt: .now, status: .taken
            )

            // Now pair: drive the adopt service against a recording protocol stub
            // (the W4 pattern) wired to the LOCAL-store-backed definition provider.
            let stub = AdoptUploadStubAPI()
            let provider = LocalMedicationDefinitionProvider(local: local)
            let uploader = StandaloneAdoptUploadService(api: stub, medicationProvider: provider)

            let bundle = try await local.allForBackfill()
            #expect(bundle.medications.count == 1)
            #expect(bundle.intakes.count == 1)

            let progress = try await uploader.run(bundle: bundle)
            #expect(progress.total >= 1)
            #expect(progress.completed == progress.total)

            // The medication create + the intake bulk endpoints both fired.
            #expect(stub.hitPaths.contains("/api/medications"))
            #expect(stub.hitPaths.contains("/api/medications/intake/bulk"))

            // Idempotent re-run is safe (the externalId carries the dedup key).
            let progress2 = try await uploader.run(bundle: bundle)
            #expect(progress2.completed == progress2.total)

            // The local mirror is KEPT after upload (offline cache + idempotency anchor).
            #expect(try await local.medications().count == 1)
            #expect(try await local.intakes().count == 1)
        }

        // MARK: - 7. v0.14 DATA — standalone rolling med shows due (regression)

        /// **v0.14 DATA regression — "nothing due" in standalone.**
        ///
        /// A v0.13 W5 regression: `toDomainMedication()` hardcoded
        /// `lastTakenAt: nil`, so `MedicationRecurrenceEngine` projected a rolling
        /// med's next slot off `createdAt` → tomorrow → zero occurrences today →
        /// the Dashboard/Medications/widget falsely showed "nothing due". The fix
        /// threads the local mirror's latest *taken* intake into
        /// `standaloneList()` so the engine anchors on the real last dose.
        ///
        /// Setup: a rolling med (interval 1 day) with the last dose taken
        /// YESTERDAY ⇒ the next slot is TODAY ⇒ `deriveTodayIntakes` must
        /// synthesise exactly one pending placeholder for today.
        @Test("Standalone rolling med taken yesterday shows due today (no false empty)")
        func standaloneRollingMedDueToday() async throws {
            let recorder = CallRecorder()
            let local = try makeLocal()
            let repo = try makeRepo(local: local, standalone: true, recorder: recorder)

            // A daily-rolling med: next dose is one day after the last taken dose.
            let rolling = MedicationScheduleDTO(
                windowStart: "08:00",
                timesOfDay: ["08:00"],
                rollingIntervalDays: 1
            )
            let created = try await repo.create(createBody(schedules: [rolling]))

            // Take a dose YESTERDAY so the rolling anchor lands the next slot today.
            let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: .now))
            _ = try await repo.recordStandaloneIntake(
                medicationId: created.id,
                scheduledAt: yesterday,
                status: .taken,
                takenAt: yesterday
            )

            // list() must now carry the real lastTakenAt anchor (was nil pre-fix).
            let meds = try await repo.list()
            let med = try #require(meds.first { $0.id == created.id })
            #expect(med.lastTakenAt != nil, "list() must thread the mirror's latest taken intake")

            // The due-derive must synthesise a pending placeholder for TODAY.
            let derived = MedicationsStore.deriveTodayIntakes(
                serverIntakes: [],
                medications: meds,
                now: .now,
                calendar: .current
            )
            #expect(
                derived.contains { $0.medicationId == created.id && $0.status == .pending },
                "a rolling med taken yesterday (interval 1) must read as DUE today, not empty"
            )
            #expect(!recorder.firedNetwork)
        }

        // MARK: - 8. v0.14 DATA — latestTakenByMedication helper

        @Test("latestTakenByMedication picks the newest taken, ignores skipped")
        func latestTakenByMedicationHelper() {
            let now = Date.now
            let older = now.addingTimeInterval(-7200)
            let newer = now.addingTimeInterval(-60)
            let snaps = [
                LocalIntakeSnapshot(externalId: "i1", medicationId: "m1", takenAt: older, status: "taken", createdAt: now),
                LocalIntakeSnapshot(externalId: "i2", medicationId: "m1", takenAt: newer, status: "taken", createdAt: now),
                // A later-timestamped SKIPPED row must NOT win the anchor.
                LocalIntakeSnapshot(externalId: "i3", medicationId: "m1", takenAt: now, status: "skipped", createdAt: now),
                LocalIntakeSnapshot(externalId: "i4", medicationId: "m2", takenAt: older, status: "taken", createdAt: now)
            ]
            let map = MedicationsRepository.latestTakenByMedication(snaps)
            #expect(map["m1"] == newer, "newest TAKEN wins; the later skipped row is ignored")
            #expect(map["m2"] == older)
        }
    }

    // MARK: - Adopt upload protocol stub (W4 pattern)

    /// Succeeding `APIClientProtocol` stub: records which endpoints fire and
    /// returns the minimal wire envelopes the adopt service decodes.
    private final class AdoptUploadStubAPI: APIClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var _hitPaths: [String] = []
        var hitPaths: [String] {
            lock.withLock { _hitPaths }
        }

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            lock.withLock { _hitPaths.append(request.path) }
            switch request.path {
            case "/api/medications":
                let json = #"{"id":"server-med-1","name":"Lisinopril","dose":"5mg","active":true}"#
                let wire = try JSONDecoder().decode(MedicationWireDTO.self, from: Data(json.utf8))
                guard let typed = wire as? T else { throw HLError.unknown("stub T mismatch med") }
                return typed
            case "/api/measurements/batch":
                let resp = HealthKitBatchResponseDTO(
                    processed: 1, inserted: 1, duplicates: 0, skipped: [], entries: []
                )
                guard let typed = resp as? T else { throw HLError.unknown("stub T mismatch batch") }
                return typed
            case "/api/mood-entries/bulk", "/api/medications/intake/bulk":
                let resp = BulkUpsertResponseDTO(processed: 1, inserted: 1, updated: 0, duplicates: 0)
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
    }

#endif
