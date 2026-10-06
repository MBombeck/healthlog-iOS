// Uses app-target symbols (`MeasurementsStore`, `MockHealthKitWriter`) that the
// SPM library does not carry; the SPM test build skips the file.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// **T3 / public #15** — a manually captured blood pressure (iPhone sheet,
    /// Watch quick capture, Siri) reached the server as the systolic row only.
    ///
    /// The pair goes out as two `POST /api/measurements`. Both carried the same
    /// `Idempotency-Key`, and the server's replay cache is keyed on
    /// `(user, key, method, path)` — never on the body
    /// (`HealthLog` `src/lib/idempotency.ts`). The diastolic POST therefore hit
    /// the systolic POST's cell and got the systolic response replayed: no
    /// handler run, no diastolic row, and nothing on the client noticed.
    ///
    /// The stub below answers exactly like that cache, so the suite fails on
    /// any request shape the real server would collapse.
    @Suite("BP-pair create — one idempotency cell per half (T3, #15)")
    @MainActor
    struct BPPairCreateIdempotencyTests {
        /// The server's write side for `POST /api/measurements`, reduced to what
        /// decides the outcome: the idempotency replay cache, then the insert.
        private final class IdempotentMeasurementsServer: @unchecked Sendable {
            struct Row: Equatable {
                let id: String
                let type: String
                let value: Double
            }

            private let lock = NSLock()
            private var cache: [String: MeasurementWireDTO] = [:]
            private var stored: [Row] = []
            /// Every row the list routes answer with, seeded ones included.
            private var wires: [MeasurementWireDTO] = []
            private var keys: [String] = []
            private var failures: [Int: HLError] = [:]

            var rows: [Row] {
                lock.withLock { stored }
            }

            var sentKeys: [String] {
                lock.withLock { keys }
            }

            /// The `number`-th request (1-based) never reaches the handler —
            /// the connection is lost before the server sees it.
            func failRequest(number: Int, with error: HLError) {
                lock.withLock { failures[number] = error }
            }

            /// A row that is already on the server (e.g. imported from Apple Health).
            func seed(_ wire: MeasurementWireDTO) {
                lock.withLock { wires.append(wire) }
            }

            private struct CreateTime: Decodable {
                let measuredAt: Date
            }

            func handle(_ request: any Sendable) throws -> any Sendable {
                if let list = request as? APIRequest<MeasurementListWireResponse> {
                    // `GET /api/measurements?type=…` — the BP pair page.
                    let type = list.query.first { $0.0 == "type" }?.1
                    return lock.withLock {
                        MeasurementListWireResponse(measurements: wires.filter { type == nil || $0.type.rawValue == type })
                    }
                }
                guard let req = request as? APIRequest<MeasurementWireDTO>, req.method == .post else {
                    throw HLError.unknown("unexpected request \(type(of: request))")
                }
                guard let body = req.body,
                      let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let type = json["type"] as? String,
                      let value = json["value"] as? Double else { throw HLError.unknown("unreadable create body") }
                let measuredAt = (try? JSONDecoder.hlDefault.decode(CreateTime.self, from: body).measuredAt)
                    ?? Date(timeIntervalSince1970: 1_759_250_940)
                return try lock.withLock { () throws -> MeasurementWireDTO in
                    keys.append(req.idempotencyKey.raw)
                    if let failure = failures[keys.count] { throw failure }
                    let cell = "\(req.idempotencyKey.raw)|POST|\(req.path)"
                    if let replay = cache[cell] { return replay }
                    let row = Row(id: "srv-\(stored.count + 1)", type: type, value: value)
                    stored.append(row)
                    let wire = MeasurementWireDTO(
                        id: row.id,
                        type: ServerMeasurementType(rawValue: type) ?? .weight,
                        value: value,
                        measuredAt: measuredAt,
                        source: .manual
                    )
                    cache[cell] = wire
                    wires.append(wire)
                    return wire
                }
            }
        }

        private func makeRepo() async throws -> (MeasurementsRepository, IdempotentMeasurementsServer) {
            let server = IdempotentMeasurementsServer()
            let api = StubAPIClient()
            await api.setHandler { try server.handle($0) }
            return try (MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true)), server)
        }

        private let reading = HealthLog.Measurement(
            id: "local-bp",
            kind: .bloodPressure,
            recordedAt: Date(timeIntervalSince1970: 1_759_250_940),
            value: .bloodPressure(systolic: 128, diastolic: 84),
            source: .manual
        )

        @Test("a BP create stores BOTH halves on the server, each exactly once")
        func createStoresBothHalves() async throws {
            let (repo, server) = try await makeRepo()

            let saved = try await repo.create(reading)

            #expect(server.rows.map(\.type) == ["BLOOD_PRESSURE_SYS", "BLOOD_PRESSURE_DIA"])
            #expect(server.rows.map(\.value) == [128, 84])
            #expect(Set(server.sentKeys).count == 2)
            // The returned pair names two distinct server rows.
            #expect(saved.id == "srv-1")
            #expect(saved.bloodPressureDiastolicId == "srv-2")
        }

        @Test("replaying the same create (outbox after a lost response) writes nothing new")
        func replayIsIdempotent() async throws {
            let (repo, server) = try await makeRepo()
            let key = IdempotencyKey().raw

            _ = try await repo.replay(reading, idempotencyKey: key)
            let again = try await repo.replay(reading, idempotencyKey: key)

            #expect(server.rows.count == 2)
            #expect(again.id == "srv-1")
            #expect(again.bloodPressureDiastolicId == "srv-2")
        }

        @Test("systolic saved, diastolic lost offline: the outbox replay adds the diastolic only")
        func partialFailureReplayCompletesThePair() async throws {
            let (repo, server) = try await makeRepo()
            // The SYS POST lands; the DIA POST dies before the server sees it.
            server.failRequest(number: 2, with: .offline)

            await #expect(throws: HLError.self) {
                _ = try await repo.create(reading)
            }
            #expect(server.rows.map(\.type) == ["BLOOD_PRESSURE_SYS"])

            // The outbox replays under the key `create` persisted.
            let key = try #require(server.sentKeys.first)
            let replayed = try await repo.replay(reading, idempotencyKey: key)

            #expect(server.rows.map(\.type) == ["BLOOD_PRESSURE_SYS", "BLOOD_PRESSURE_DIA"])
            #expect(server.rows.map(\.value) == [128, 84])
            #expect(replayed.id == "srv-1")
            #expect(replayed.bloodPressureDiastolicId == "srv-2")
        }

        @Test("Watch / sheet capture: both halves reach the server, Health gets one pair")
        func captureStoresPairAndMirrorsOnce() async throws {
            let (repo, server) = try await makeRepo()
            let hk = MockHealthKitWriter()
            let store = MeasurementsStore(repo: repo, healthKit: hk, isStandalone: { false })

            // The path `AppContainer+Watch` routes a wrist capture through.
            let outcome = await store.captureReturningOutcome(
                kind: .bloodPressure,
                value: .bloodPressure(systolic: 128, diastolic: 84),
                note: nil
            )

            #expect(outcome == .success)
            #expect(server.rows.map(\.type) == ["BLOOD_PRESSURE_SYS", "BLOOD_PRESSURE_DIA"])
            #expect(hk.writtenMeasurements.count == 1)
            let written = try #require(hk.writtenMeasurements.first)
            #expect(written.value == .bloodPressure(systolic: 128, diastolic: 84))
            #expect(written.serverMirrorLinkageIDs == ["srv-1", "srv-2"])
        }

        @Test("T4 — after a capture the new pair is the BP page's latest reading (\"Letzte Messung\")")
        func captureBecomesLatestReading() async throws {
            let (repo, server) = try await makeRepo()
            // The reporter's earlier reading, typed in Apple Health at 08:43.
            let earlier = Date.now.addingTimeInterval(-3600)
            server.seed(MeasurementWireDTO(
                id: "hk-sys", type: .bloodPressureSystolic, value: 131, measuredAt: earlier, source: .appleHealth
            ))
            server.seed(MeasurementWireDTO(
                id: "hk-dia", type: .bloodPressureDiastolic, value: 93, measuredAt: earlier, source: .appleHealth
            ))
            let store = MeasurementsStore(repo: repo, healthKit: MockHealthKitWriter(), isStandalone: { false })

            let outcome = await store.captureReturningOutcome(
                kind: .bloodPressure,
                value: .bloodPressure(systolic: 128, diastolic: 84),
                note: nil
            )
            #expect(outcome == .success)

            // The page and the rule `ChartDetailStore.applyRecentPage` derives
            // the Insights "Letzte Messung" from (`latestRawMeasurement`).
            let page = try await repo.recent(kind: .bloodPressure, limit: 50)
            let latest = page.filter(\.isDisplayableLatest).max { $0.recordedAt < $1.recordedAt }
            #expect(latest?.value == .bloodPressure(systolic: 128, diastolic: 84))
            #expect(latest?.source == .manual)
        }

        @Test("non-BP creates keep sending the caller's key unchanged")
        func scalarKeyUnchanged() async throws {
            let (repo, server) = try await makeRepo()
            let key = IdempotencyKey().raw
            _ = try await repo.replay(
                HealthLog.Measurement(
                    id: "local-w",
                    kind: .weight,
                    recordedAt: reading.recordedAt,
                    value: .scalar(81.2),
                    source: .manual
                ),
                idempotencyKey: key
            )
            #expect(server.sentKeys == [key])
        }
    }

#endif
