// Audit B-5 (2026-09-10) — a stored intake status this build cannot name must
// never count as a dose taken.
//
// The standalone mirror stores `LocalIntakeEntry.status` as a bare String. Five
// call sites resolved it with `IntakeStatus(rawValue:) ?? .taken`, so a row a
// downgrade or a data import left behind — a status a LATER build wrote, or one
// an import carried in — was read back as "taken": it raised the compliance
// rate, it anchored the recurrence engine's rolling cadence, and it uploaded to
// the server as a real administration on adopt-on-pair.
//
// These tests plant exactly that row (`FUTURE_STATUS`) in the local store and
// hold the whole standalone read surface to one rule: the row stays visible and
// counts as nothing.

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @MainActor
    @Suite("Audit B-5 — an unknown stored intake status is not taken", .serialized)
    struct StandaloneUnknownIntakeStatusTests {
        /// The raw value under test: shaped like a server enum member this build
        /// has never heard of.
        private static let unknownRaw = "FUTURE_STATUS"

        private struct EmptyHK: StandaloneHealthKitReadServing {
            func standaloneRecentSamples(kind _: MetricKind, days _: Int, limit _: Int) async -> [SeriesPoint] {
                []
            }

            func standaloneDailySeries(kind _: MetricKind, days _: Int) async -> [SeriesPoint] {
                []
            }
        }

        /// Session-owned transport (Plan 09-10) — this suite's own handler, so a
        /// parallel suite can neither answer nor observe its requests. Every
        /// standalone path under test must fire ZERO of them.
        private func makeAPI(session: MockURLProtocolSession) -> APIClient {
            session.install { req in
                throw URLError(.notConnectedToInternet, userInfo: ["path": req.url?.path ?? ""])
            }
            let env = AppEnvironment(
                baseURL: session.baseURL,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: session.configuration)
        }

        private func makeLocal() throws -> LocalRepository {
            try LocalRepository(store: LocalStore(modelContainer: LocalStore.makeInMemory()))
        }

        private func makeRepo(local: LocalRepository, session: MockURLProtocolSession) throws -> MedicationsRepository {
            try MedicationsRepository(
                api: makeAPI(session: session),
                outbox: OutboxQueue(inMemory: true),
                standalone: StandaloneGate(local: local, healthKit: EmptyHK(), isStandalone: { true })
            )
        }

        private func createBody() -> MedicationsRepository.MedicationCreate {
            MedicationsRepository.MedicationCreate(
                name: "Lisinopril",
                dose: "5mg",
                schedules: [MedicationScheduleDTO(windowStart: "08:00", timesOfDay: ["08:00"], rrule: "FREQ=DAILY")],
                deliveryForm: "ORAL"
            )
        }

        // MARK: - Today's list

        @Test("The row survives today's standalone list and reads as unknown, not as taken")
        func todayListKeepsTheRowWithoutClaimingIt() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let local = try makeLocal()
            let repo = try makeRepo(local: local, session: session)
            let created = try await repo.create(createBody())
            _ = try await local.addIntake(
                medicationId: created.id,
                takenAt: .now,
                status: Self.unknownRaw
            )

            let today = try await repo.todayIntakes()
            let row = try #require(today.first { $0.medicationId == created.id })
            // Visible — the whole point of a sentinel over a dropped row.
            #expect(row.status == .unknown)
            #expect(row.status != .taken)
            // A status nobody can read carries no administration instant.
            #expect(row.takenAt == nil)
        }

        // MARK: - Compliance

        @Test("Aggregate standalone compliance does not count the unknown row as taken")
        func aggregateComplianceDoesNotCountIt() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let local = try makeLocal()
            let repo = try makeRepo(local: local, session: session)
            let created = try await repo.create(createBody())
            _ = try await local.addIntake(
                medicationId: created.id,
                takenAt: .now,
                status: Self.unknownRaw
            )

            let days = try await repo.standaloneCompliance(days: 7)
            #expect(days.reduce(0) { $0 + $1.taken } == 0)
            // The schedule still owns the denominator — the unknown row neither
            // adds an expectation nor satisfies one.
            #expect(days.reduce(0) { $0 + $1.scheduled } >= 6)
        }

        @Test("Per-card compliance counts the unknown row as neither taken nor skipped")
        func cardComplianceCountsItAsNeither() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let local = try makeLocal()
            let repo = try makeRepo(local: local, session: session)
            let created = try await repo.create(createBody())
            _ = try await local.addIntake(
                medicationId: created.id,
                takenAt: .now,
                status: Self.unknownRaw
            )

            let payload = try await repo.compliance(medicationID: created.id)
            #expect(payload.compliance7.taken == 0)
            #expect(payload.compliance7.skipped == 0)
            #expect(payload.compliance7.rate < 100)
        }

        // MARK: - Adopt-on-pair upload

        /// Recording stub for the adopt upload: answers the three paths the
        /// service touches and keeps every request body so the assertion can
        /// read what was actually sent.
        private final class RecordingAdoptAPI: APIClientProtocol, @unchecked Sendable {
            private let lock = NSLock()
            private var bodies: [String: [Data]] = [:]

            func bodies(forPath path: String) -> [Data] {
                lock.withLock { bodies[path] ?? [] }
            }

            func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
                lock.withLock { bodies[request.path, default: []].append(request.body ?? Data()) }
                switch request.path {
                case "/api/medications" where request.method == .get:
                    let wires = try JSONDecoder().decode([MedicationWireDTO].self, from: Data("[]".utf8))
                    guard let typed = wires as? T else { throw HLError.unknown("stub T mismatch med-list") }
                    return typed
                case "/api/medications":
                    let json = #"{"id":"server-med-1","name":"Lisinopril","dose":"5mg","active":true}"#
                    let wire = try JSONDecoder().decode(MedicationWireDTO.self, from: Data(json.utf8))
                    guard let typed = wire as? T else { throw HLError.unknown("stub T mismatch med") }
                    return typed
                case "/api/medications/intake/bulk":
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

        /// **Adopt-on-pair is a one-way door.** Whatever this upload writes is
        /// what every later device reads back from the server, so a status this
        /// build cannot name must arrive as what it honestly is — a slot that
        /// exists, with nothing claimed about it. Before B-5 it arrived stamped
        /// with a `takenAt`: a dose the user never confirmed, now a server fact.
        @Test("Adopt uploads the unknown row as a bare slot — no takenAt, no skip")
        func adoptUploadsWithoutAClaim() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let local = try makeLocal()
            let repo = try makeRepo(local: local, session: session)
            let created = try await repo.create(createBody())
            _ = try await local.addIntake(
                medicationId: created.id,
                takenAt: .now,
                status: Self.unknownRaw
            )

            let stub = RecordingAdoptAPI()
            let uploader = StandaloneAdoptUploadService(
                api: stub,
                medicationProvider: LocalMedicationDefinitionProvider(local: local)
            )
            _ = try await uploader.run(bundle: local.allForBackfill())

            let bulks = stub.bodies(forPath: "/api/medications/intake/bulk")
            #expect(bulks.count == 1)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(BulkIntakePayload.self, from: #require(bulks.first))
            let entry = try #require(payload.entries.first)
            // The row is NOT dropped — the dose still reaches the server.
            #expect(entry.medicationId == "server-med-1")
            // …and it claims nothing there: not taken, not skipped.
            #expect(entry.takenAt == nil)
            #expect(entry.skipped == false)
            #expect(entry.injectionSite == nil)
        }

        // MARK: - Pure counting seams

        @Test("The unknown row is not a 'last taken' anchor for the recurrence engine")
        func unknownIsNoRollingAnchor() {
            let anchors = MedicationsRepository.latestTakenByMedication([
                LocalIntakeSnapshot(
                    externalId: "i-unknown",
                    medicationId: "m-1",
                    takenAt: Date(timeIntervalSince1970: 1_757_491_200),
                    status: Self.unknownRaw,
                    createdAt: Date(timeIntervalSince1970: 1_757_491_200)
                )
            ])
            #expect(anchors.isEmpty)
        }

        @Test("A real taken row still anchors and still counts")
        func knownRowsAreUntouched() {
            let taken = Date(timeIntervalSince1970: 1_757_491_200)
            let anchors = MedicationsRepository.latestTakenByMedication([
                LocalIntakeSnapshot(
                    externalId: "i-taken",
                    medicationId: "m-1",
                    takenAt: taken,
                    status: "taken",
                    createdAt: taken
                ),
                LocalIntakeSnapshot(
                    externalId: "i-unknown",
                    medicationId: "m-1",
                    takenAt: taken.addingTimeInterval(3600),
                    status: Self.unknownRaw,
                    createdAt: taken
                )
            ])
            // The newer row is the unknown one — it must not displace the anchor.
            #expect(anchors["m-1"] == taken)
        }
    }

#endif
