// App-target symbols (`MeasurementsStore`, `MockHealthKitWriter`); the SPM test
// build skips the file.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// **MIRROR (1.5, #152, server #1272)** — the historical mirror pass v3.
    ///
    /// Against a server known to be 1.46.0 or later the pass pages
    /// `?type=…&appleHealthMirror=true` per mirror-writable kind instead of one
    /// fetch per source. (b) A 1.4.1 install (v2 stored) runs it exactly once
    /// after the update; an older or unknown server keeps the 1.4 walk.
    @Suite("Historical mirror pass v3 (#152)", .timeLimit(.minutes(1)))
    @MainActor
    struct MeasurementsStoreMirrorBackfillV3Tests {
        private static let markerKey = "hl.healthkit.historicalBackfill.v.user-a"

        /// Every `/api/measurements` query the pass sent, answered by `respond`.
        private final class QueryLog: @unchecked Sendable {
            private let lock = NSLock()
            private var _queries: [[String: String]] = []
            let respond: @Sendable ([String: String]) -> MeasurementListWireResponse

            init(respond: @escaping @Sendable ([String: String]) -> MeasurementListWireResponse) {
                self.respond = respond
            }

            var queries: [[String: String]] {
                lock.withLock { _queries }
            }

            func answer(_ query: [(String, String)]) -> MeasurementListWireResponse {
                let dict = Dictionary(query, uniquingKeysWith: { _, last in last })
                lock.withLock { _queries.append(dict) }
                return respond(dict)
            }
        }

        private func freshDefaults() throws -> UserDefaults {
            let suite = "hl.test.mirror-v3.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            return defaults
        }

        private func serverDefaults(version: String?) throws -> UserDefaults {
            let defaults = try freshDefaults()
            if let version {
                KnownServerVersion.record(ServerVersionInfo(version: version), defaults: defaults)
            }
            return defaults
        }

        private func makeStore(
            log: QueryLog,
            hk: MockHealthKitWriter,
            backfill: UserDefaults,
            serverVersion: UserDefaults
        ) async throws -> MeasurementsStore {
            let api = StubAPIClient()
            await api.setHandler { request in
                guard let request = request as? APIRequest<MeasurementListWireResponse> else {
                    return MeasurementListWireResponse(measurements: [])
                }
                return log.answer(request.query)
            }
            let repo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
            return MeasurementsStore(
                repo: repo,
                healthKit: hk,
                isStandalone: { false },
                userIDProvider: { "user-a" },
                backfillDefaults: backfill,
                serverVersionDefaults: serverVersion
            )
        }

        private nonisolated static func row(
            _ id: String,
            _ type: ServerMeasurementType,
            source: ServerMeasurementSource,
            flag: Bool?
        ) -> MeasurementWireDTO {
            var row = MeasurementWireDTO(
                id: id,
                type: type,
                value: 80,
                measuredAt: Date(timeIntervalSince1970: 1_761_000_000),
                source: source
            )
            row.appleHealthMirror = flag
            return row
        }

        // MARK: - (b) The update path

        @Test("(b) a 1.4.1 install (v2 stored) against server 1.46 runs v3 once, then never again")
        func updatePathRunsV3Once() async throws {
            let log = QueryLog { query in
                guard query["type"] == "WEIGHT" else { return MeasurementListWireResponse(measurements: []) }
                return MeasurementListWireResponse(measurements: [
                    Self.row("ext-1", .weight, source: .external, flag: true)
                ])
            }
            let hk = MockHealthKitWriter()
            let backfill = try freshDefaults()
            backfill.set(2, forKey: Self.markerKey)
            let store = try await makeStore(
                log: log,
                hk: hk,
                backfill: backfill,
                serverVersion: serverDefaults(version: "1.46.2")
            )

            await store.runHistoricalBackfillForTesting()

            #expect(backfill.integer(forKey: Self.markerKey) == 3)
            #expect(!log.queries.isEmpty)
            #expect(log.queries.allSatisfy { $0["appleHealthMirror"] == "true" && $0["sourceEq"] == nil })
            #expect(log.queries.allSatisfy { $0["offset"] != nil && $0["type"] != nil })
            // One walk per writable kind; blood pressure pages both halves.
            let types = Set(log.queries.compactMap { $0["type"] })
            #expect(types.contains("BLOOD_PRESSURE_SYS") && types.contains("BLOOD_PRESSURE_DIA"))
            #expect(types.count == MetricKind.serverMirrorWritableKinds.count + 1)
            // The opted-in EXTERNAL reading reaches the mirror, with its flag.
            #expect(hk.mirroredMeasurements.map(\.id) == ["ext-1"])
            #expect(hk.mirroredMeasurements.first?.appleHealthMirror == true)

            let sent = log.queries.count
            await store.runHistoricalBackfillForTesting()
            #expect(log.queries.count == sent, "v3 must not run a second time")
            #expect(hk.mirrorCallCount == 1)
        }

        @Test("(b) against an older or unknown server a completed v2 is not repeated", arguments: ["1.45.9", nil])
        func olderServerKeepsV2(version: String?) async throws {
            let log = QueryLog { _ in MeasurementListWireResponse(measurements: []) }
            let hk = MockHealthKitWriter()
            let backfill = try freshDefaults()
            backfill.set(2, forKey: Self.markerKey)
            let store = try await makeStore(
                log: log,
                hk: hk,
                backfill: backfill,
                serverVersion: serverDefaults(version: version)
            )

            await store.runHistoricalBackfillForTesting()

            #expect(log.queries.isEmpty)
            #expect(hk.mirrorCallCount == 0)
            #expect(backfill.integer(forKey: Self.markerKey) == 2)
        }

        @Test("a fresh install against an older server walks per source, as in 1.4, and never sends the flag")
        func freshInstallOlderServerWalksPerSource() async throws {
            let log = QueryLog { _ in MeasurementListWireResponse(measurements: []) }
            let hk = MockHealthKitWriter()
            let backfill = try freshDefaults()
            let store = try await makeStore(
                log: log,
                hk: hk,
                backfill: backfill,
                serverVersion: serverDefaults(version: "1.45.9")
            )

            await store.runHistoricalBackfillForTesting()

            #expect(!log.queries.isEmpty)
            #expect(log.queries.allSatisfy { $0["sourceEq"] != nil && $0["appleHealthMirror"] == nil })
            #expect(backfill.integer(forKey: Self.markerKey) == 2)
        }

        @Test("v3 pages with offset until the server's total is reached")
        func v3PagesUntilTheTotal() async throws {
            let log = QueryLog { query in
                guard query["type"] == "WEIGHT" else { return MeasurementListWireResponse(measurements: []) }
                let offset = Int(query["offset"] ?? "0") ?? 0
                let rows = offset == 0
                    ? (0 ..< 1000).map { Self.row("w-\($0)", .weight, source: .withings, flag: true) }
                    : [Self.row("w-last", .weight, source: .withings, flag: true)]
                return MeasurementListWireResponse(
                    measurements: rows,
                    meta: .init(total: 1001, limit: 1000, offset: offset)
                )
            }
            let hk = MockHealthKitWriter()
            let store = try await makeStore(
                log: log,
                hk: hk,
                backfill: freshDefaults(),
                serverVersion: serverDefaults(version: "1.46.0")
            )

            await store.runHistoricalBackfillForTesting()

            let weightOffsets = log.queries.filter { $0["type"] == "WEIGHT" }.compactMap { $0["offset"] }
            #expect(weightOffsets == ["0", "1000"])
            #expect(hk.mirroredMeasurements.count == 1001)
        }

        @Test("an unknown direction leaves v3 due")
        func undecidedPassStaysDue() async throws {
            let log = QueryLog { _ in MeasurementListWireResponse(measurements: []) }
            let hk = MockHealthKitWriter()
            hk.mirrorDecides = false
            let backfill = try freshDefaults()
            backfill.set(2, forKey: Self.markerKey)
            let store = try await makeStore(
                log: log,
                hk: hk,
                backfill: backfill,
                serverVersion: serverDefaults(version: "1.46.2")
            )

            await store.runHistoricalBackfillForTesting()

            #expect(backfill.integer(forKey: Self.markerKey) == 2)
        }
    }

#endif
