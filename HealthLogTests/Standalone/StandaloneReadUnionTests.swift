// v0.11 W2 — locks the standalone read-union + offline-write seam end-to-end.
//
// The load-bearing acceptances:
//  1. In standalone a logged measurement / mood / intake is READ BACK by its
//     repository (no more "vanishing writes").
//  2. The dashboard summary aggregates from the local mirror (tile moves).
//  3. **NO `/api/*` request fires** in standalone — a recording stub
//     URLSession fails + records on ANY network call, and the count stays 0.
//  4. Paired (gate inert): the SAME repos take the server path — the recording
//     stub DOES see the call (proving the paired path is untouched).
//
// Refs: .planning/v0110-marathon/v0.11-STANDALONE-WAVE-PLAN.md §W2.

// swiftlint:disable force_unwrapping force_try

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @MainActor
    @Suite("Standalone read-union (W2)", .serialized)
    struct StandaloneReadUnionTests {
        /// HK adapter stub — returns no HK samples so the assertions isolate the
        /// mirror contribution. (HK can't be exercised in the unit host anyway.)
        private struct EmptyHK: StandaloneHealthKitReadServing {
            func standaloneRecentSamples(kind _: MetricKind, days _: Int, limit _: Int) async -> [SeriesPoint] {
                []
            }

            func standaloneDailySeries(kind _: MetricKind, days _: Int) async -> [SeriesPoint] {
                []
            }
        }

        /// Records every URLProtocol hit + fails it, so any `/api/*` call both
        /// (a) bumps the counter and (b) surfaces as an error — a standalone read
        /// that accidentally fell through to the network would be loud.
        private final class CallRecorder: @unchecked Sendable {
            nonisolated(unsafe) var hits = 0
            /// True iff ANY `/api/*` request was attempted.
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
                // Any network hit in standalone is a bug — fail loudly.
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

        // MARK: - Measurement write → read-back, no network

        @Test("Standalone measurement: write reads back AND no /api/* fires")
        func measurementRoundTripNoNetwork() async throws {
            let recorder = CallRecorder()
            let api = makeAPI(recorder: recorder)
            let local = try makeLocal()
            let gate = makeGate(local: local, standalone: true)
            let repo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true), standalone: gate)

            let created = try await repo.create(
                Measurement(id: "x", kind: .weight, recordedAt: .now, value: .scalar(80.5))
            )
            let recent = try await repo.recent(limit: 50)
            #expect(recent.contains { $0.id == created.id })
            #expect(recent.contains { $0.primaryValue == 80.5 })

            let perKind = try await repo.recent(kind: .weight, limit: 400)
            #expect(perKind.contains { $0.primaryValue == 80.5 })

            #expect(!recorder.firedNetwork, "standalone measurement path must fire ZERO /api/* calls")
        }

        @Test("Standalone measurement series renders from the mirror, no network")
        func measurementSeriesNoNetwork() async throws {
            let recorder = CallRecorder()
            let api = makeAPI(recorder: recorder)
            let local = try makeLocal()
            let repo = try MeasurementsRepository(
                api: api, outbox: OutboxQueue(inMemory: true), standalone: makeGate(local: local, standalone: true)
            )
            _ = try await repo.create(Measurement(id: "a", kind: .weight, recordedAt: .now, value: .scalar(81)))
            let series = try await repo.series(kind: .weight, days: 30)
            #expect(series.points.contains { $0.value == 81 })
            #expect(!recorder.firedNetwork)
        }

        // MARK: - Mood write → read-back, no network

        @Test("Standalone mood: write reads back AND no /api/* fires")
        func moodRoundTripNoNetwork() async throws {
            let recorder = CallRecorder()
            let api = makeAPI(recorder: recorder)
            let local = try makeLocal()
            let repo = try MoodRepository(
                api: api, outbox: OutboxQueue(inMemory: true), standalone: makeGate(local: local, standalone: true)
            )
            let logged = try await repo.log(score: 4, tags: ["calm"], note: "ok", recordedAt: .now)
            let entries = try await repo.recent(days: 365)
            #expect(entries.contains { $0.id == logged.id })
            #expect(entries.contains { $0.score == 4 })
            #expect(!recorder.firedNetwork, "standalone mood path must fire ZERO /api/* calls")
        }

        // MARK: - Intake write → read-back, no network

        @Test("Standalone intake: write reads back via standaloneTodayIntakes, no network")
        func intakeRoundTripNoNetwork() async throws {
            let recorder = CallRecorder()
            let api = makeAPI(recorder: recorder)
            let local = try makeLocal()
            let repo = try MedicationsRepository(
                api: api, outbox: OutboxQueue(inMemory: true), standalone: makeGate(local: local, standalone: true)
            )
            let intake = try await repo.recordStandaloneIntake(
                medicationId: "med-1", scheduledAt: .now, status: .taken
            )
            #expect(intake.status == .taken)
            let today = try await repo.standaloneTodayIntakes()
            #expect(today.contains { $0.medicationId == "med-1" && $0.status == .taken })
            #expect(!recorder.firedNetwork)
        }

        // MARK: - Medications load reads (G1/G2/G3): list / today / compliance

        @Test("Standalone meds load reads (list/today/compliance) fire ZERO /api/*")
        func medsLoadReadsNoNetwork() async throws {
            let recorder = CallRecorder()
            let api = makeAPI(recorder: recorder)
            let local = try makeLocal()
            let repo = try MedicationsRepository(
                api: api, outbox: OutboxQueue(inMemory: true), standalone: makeGate(local: local, standalone: true)
            )
            // Confirm a dose first so the read-back has something to surface.
            _ = try await repo.recordStandaloneIntake(medicationId: "med-1", scheduledAt: .now, status: .taken)

            // G1: list() — no local med-definition catalogue ⇒ empty, no /api/medications.
            let meds = try await repo.list()
            #expect(meds.isEmpty)
            // G2: todayIntakes() — read-back of the confirmed dose (vanishing-write fix).
            let today = try await repo.todayIntakes()
            #expect(today.contains { $0.medicationId == "med-1" && $0.status == .taken })
            // G3: compliance() — derived on-device; today's confirmed dose shows.
            let comp = try await repo.compliance(days: 84)
            #expect(comp.contains { $0.taken >= 1 })

            #expect(!recorder.firedNetwork, "standalone meds load must fire ZERO /api/* calls")
        }

        @Test("Standalone on-device compliance: 100% rate for a logged day, windowed")
        func onDeviceComplianceRate() async throws {
            let recorder = CallRecorder()
            let api = makeAPI(recorder: recorder)
            let local = try makeLocal()
            let repo = try MedicationsRepository(
                api: api, outbox: OutboxQueue(inMemory: true), standalone: makeGate(local: local, standalone: true)
            )
            _ = try await repo.recordStandaloneIntake(medicationId: "med-1", scheduledAt: .now, status: .taken)
            _ = try await repo.recordStandaloneIntake(medicationId: "med-2", scheduledAt: .now, status: .taken)
            let comp = try await repo.standaloneCompliance(days: 84)
            // Both doses land on today's bucket; scheduled == taken ⇒ rate 1.0.
            let today = comp.first { Calendar.current.isDateInToday($0.date) }
            #expect(today?.taken == 2)
            #expect(today?.scheduled == 2)
            #expect(today?.rate == 1.0)
            #expect(!recorder.firedNetwork)
        }

        @Test("Paired meds (gate inert): list() DOES hit the network")
        func pairedMedsStillHitsNetwork() async throws {
            let recorder = CallRecorder()
            let api = makeAPI(recorder: recorder)
            let local = try makeLocal()
            let repo = try MedicationsRepository(
                api: api, outbox: OutboxQueue(inMemory: true), standalone: makeGate(local: local, standalone: false)
            )
            _ = try? await repo.list()
            #expect(recorder.firedNetwork, "paired meds path must still reach /api/medications")
        }

        // MARK: - Dashboard aggregates from the mirror, no network

        @Test("Standalone dashboard summary aggregates the mirror, no network")
        func dashboardSummaryNoNetwork() async throws {
            let recorder = CallRecorder()
            let api = makeAPI(recorder: recorder)
            let local = try makeLocal()
            _ = try await local.addMeasurement(kind: "weight", value: 79.2, unit: "kg", recordedAt: .now)
            let dash = DashboardRepository(api: api, standalone: makeGate(local: local, standalone: true))
            let summary = try await dash.summary()
            #expect(summary.metrics.contains { $0.kind == .weight && $0.latestValue == 79.2 })
            #expect(!recorder.firedNetwork, "standalone dashboard summary must fire ZERO /api/* calls")
        }

        // MARK: - Paired invariant: the SAME repo takes the server path

        @Test("Paired (gate inert): measurement read DOES hit the network")
        func pairedStillHitsNetwork() async throws {
            let recorder = CallRecorder()
            let api = makeAPI(recorder: recorder)
            let local = try makeLocal()
            // Gate present but isStandalone == false → server path.
            let repo = try MeasurementsRepository(
                api: api, outbox: OutboxQueue(inMemory: true), standalone: makeGate(local: local, standalone: false)
            )
            // The recording stub fails the call; we only care that it was MADE
            // (proving the paired branch is unchanged + the gate is inert).
            _ = try? await repo.recent(limit: 50)
            #expect(recorder.firedNetwork, "paired path must still reach the server (gate inert when not standalone)")
        }
    }

#endif
