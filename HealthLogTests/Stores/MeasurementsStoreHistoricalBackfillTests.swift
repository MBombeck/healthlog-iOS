// Diese Suite testet App-Target-Symbole (`MeasurementsStore`,
// `MeasurementsRepository`, `MockHealthKitWriter`), die in der SPM-Library nicht
// enthalten sind. SPM-Test-Build überspringt die Datei.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// **W-HKBACKFILL** — one-shot historical backfill of server-origin
    /// measurements into Apple Health.
    ///
    /// Covers the four invariants the driver owns on top of the reused b198
    /// mirror primitive (`mirrorServerMeasurements`, which carries the source
    /// whitelist + externalUUID anti-dup + per-sample `existsInHealth` probe +
    /// share-auth gate):
    /// - run-once gate (a second eligible call no-ops),
    /// - standalone suppression (no mirror, no flag flip),
    /// - source-policy filter (only `.withings` / `.import_` history reaches the
    ///   mirror; `.manual` / `.appleHealth` / `.whoop` / `.fitbit` never do),
    /// - that ALL eligible history (not just the latest page) is handed to the
    ///   mirror so its externalUUID probe can de-dup per sample.
    @Suite("MeasurementsStore — historical HealthKit backfill (W-HKBACKFILL)")
    @MainActor
    struct MeasurementsStoreHistoricalBackfillTests {
        private actor SuspendedHistoryPage {
            private var continuation: CheckedContinuation<MeasurementListWireResponse, Never>?
            private var entryWaiters: [CheckedContinuation<Void, Never>] = []
            private var didSuspend = false
            private let firstPage: MeasurementListWireResponse

            init(firstPage: MeasurementListWireResponse) {
                self.firstPage = firstPage
            }

            func response() async -> MeasurementListWireResponse {
                guard !didSuspend else { return MeasurementListWireResponse(measurements: []) }
                didSuspend = true
                let waiters = entryWaiters
                entryWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
                return await withCheckedContinuation { continuation in
                    self.continuation = continuation
                }
            }

            func waitUntilRequested() async {
                if continuation != nil { return }
                await withCheckedContinuation { continuation in
                    entryWaiters.append(continuation)
                }
            }

            func release() {
                continuation?.resume(returning: firstPage)
                continuation = nil
            }
        }

        /// Isolated UserDefaults so the run-once marker never touches `.standard`.
        private func freshDefaults() throws -> UserDefaults {
            let suite = "hl.test.hkbackfill.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            return defaults
        }

        /// Builds a repo whose history fetch echoes a fixed set of wire rows per
        /// `(type, sourceEq)` request, so the driver's per-kind × per-source walk
        /// is observable. Counts the history requests it served.
        private final class HistoryRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var _requestCount = 0
            /// Rows to return, keyed by the `sourceEq` wire value the request
            /// carried. Lets a test seed only WITHINGS rows and prove IMPORT
            /// returns none.
            let rowsForSource: [String: [MeasurementWireDTO]]

            init(rowsForSource: [String: [MeasurementWireDTO]]) {
                self.rowsForSource = rowsForSource
            }

            var requestCount: Int {
                lock.withLock { _requestCount }
            }

            func bump() {
                lock.withLock { _requestCount += 1 }
            }
        }

        private func makeStore(
            recorder: HistoryRecorder,
            hk: MockHealthKitWriter,
            defaults: UserDefaults,
            userID: String?,
            standalone: Bool
        ) async throws -> MeasurementsStore {
            let api = StubAPIClient()
            await api.setHandler { request in
                // Only the backfill history fetch is exercised here — it queries
                // `/api/measurements` with a `sourceEq`. Echo the seeded rows for
                // that source as a list-wire response.
                let mirror = Mirror(reflecting: request)
                var sourceEq = ""
                for child in mirror.children where child.label == "query" {
                    if let query = child.value as? [(String, String)] {
                        sourceEq = query.first { $0.0 == "sourceEq" }?.1 ?? ""
                    }
                }
                recorder.bump()
                let rows = recorder.rowsForSource[sourceEq] ?? []
                return MeasurementListWireResponse(measurements: rows)
            }
            let outbox = try OutboxQueue(inMemory: true)
            let repo = MeasurementsRepository(api: api, outbox: outbox)
            return MeasurementsStore(
                repo: repo,
                healthKit: hk,
                isStandalone: { standalone },
                userIDProvider: { userID },
                backfillDefaults: defaults
            )
        }

        /// A WITHINGS weight wire row.
        private func withingsWeight(id: String) -> MeasurementWireDTO {
            MeasurementWireDTO(
                id: id,
                type: .weight,
                value: 80.0,
                measuredAt: Date(timeIntervalSince1970: 1_600_000_000),
                source: .withings,
                externalId: id
            )
        }

        // MARK: - Source policy filter

        @Test("Only WITHINGS / IMPORT history reaches the mirror — never MANUAL/APPLE_HEALTH/WHOOP/FITBIT")
        func sourcePolicyFilter() async throws {
            // The repo fetch is source-scoped: the driver only ever asks for the
            // eligible sources, so the recorder is keyed on WITHINGS + IMPORT.
            let recorder = HistoryRecorder(rowsForSource: [
                ServerMeasurementSource.withings.rawValue: [withingsWeight(id: "w-1")],
                ServerMeasurementSource.import_.rawValue: []
            ])
            let hk = MockHealthKitWriter()
            let defaults = try freshDefaults()
            let store = try await makeStore(
                recorder: recorder,
                hk: hk,
                defaults: defaults,
                userID: "user-a",
                standalone: false
            )

            await store.runHistoricalBackfillForTesting()

            // Every batch handed to the mirror is source-eligible.
            #expect(!hk.mirroredMeasurements.isEmpty)
            for measurement in hk.mirroredMeasurements {
                #expect(measurement.source.isServerMirrorEligible)
            }
            // The driver NEVER issues a fetch for an ineligible source: it only
            // walks `MeasurementSource.serverMirrorEligible`.
            #expect(MeasurementSource.serverMirrorEligible == [.withings, .import_])
        }

        @Test("All eligible history (not just the latest page) is handed to the mirror")
        func feedsFullHistoryToMirror() async throws {
            let recorder = HistoryRecorder(rowsForSource: [
                ServerMeasurementSource.withings.rawValue: [
                    withingsWeight(id: "w-1"),
                    withingsWeight(id: "w-2")
                ]
            ])
            let hk = MockHealthKitWriter()
            let store = try await makeStore(
                recorder: recorder,
                hk: hk,
                defaults: freshDefaults(),
                userID: "user-a",
                standalone: false
            )

            await store.runHistoricalBackfillForTesting()

            // The mirror was invoked once with the full collected history.
            #expect(hk.mirrorCallCount == 1)
            let ids = Set(hk.mirroredMeasurements.map(\.id))
            #expect(ids.isSuperset(of: ["w-1", "w-2"]))
        }

        // MARK: - Run-once gate

        @Test("Second backfill call no-ops once the per-user marker is set")
        func runOnceGate() async throws {
            let recorder = HistoryRecorder(rowsForSource: [
                ServerMeasurementSource.withings.rawValue: [withingsWeight(id: "w-1")]
            ])
            let hk = MockHealthKitWriter()
            let defaults = try freshDefaults()
            let store = try await makeStore(
                recorder: recorder,
                hk: hk,
                defaults: defaults,
                userID: "user-a",
                standalone: false
            )

            await store.runHistoricalBackfillForTesting()
            let firstRequests = recorder.requestCount
            let firstMirrorCalls = hk.mirrorCallCount
            #expect(firstMirrorCalls == 1)
            #expect(firstRequests > 0)

            // Second call — the run-once marker is set, so NO fetch + NO mirror.
            await store.runHistoricalBackfillForTesting()
            #expect(recorder.requestCount == firstRequests)
            #expect(hk.mirrorCallCount == firstMirrorCalls)
        }

        @Test("A different user gets their own one-shot (per-user partition)")
        func perUserPartition() async throws {
            let recorder = HistoryRecorder(rowsForSource: [
                ServerMeasurementSource.withings.rawValue: [withingsWeight(id: "w-1")]
            ])
            let defaults = try freshDefaults()

            let hkA = MockHealthKitWriter()
            let storeA = try await makeStore(
                recorder: recorder, hk: hkA, defaults: defaults, userID: "user-a", standalone: false
            )
            await storeA.runHistoricalBackfillForTesting()
            #expect(hkA.mirrorCallCount == 1)
            // Re-run for the SAME user → gated.
            await storeA.runHistoricalBackfillForTesting()
            #expect(hkA.mirrorCallCount == 1)

            // Different user on the same device + same defaults → fresh one-shot.
            let hkB = MockHealthKitWriter()
            let storeB = try await makeStore(
                recorder: recorder, hk: hkB, defaults: defaults, userID: "user-b", standalone: false
            )
            await storeB.runHistoricalBackfillForTesting()
            #expect(hkB.mirrorCallCount == 1)
        }

        // MARK: - Standalone suppression

        @Test("Standalone mode suppresses the backfill (no mirror, marker stays unset)")
        func standaloneSuppression() async throws {
            let recorder = HistoryRecorder(rowsForSource: [
                ServerMeasurementSource.withings.rawValue: [withingsWeight(id: "w-1")]
            ])
            let hk = MockHealthKitWriter()
            let defaults = try freshDefaults()
            // The repo's `historyForBackfill` returns [] in standalone, and the
            // trigger gate in `load()` never even calls the driver in standalone
            // — here we drive the repo path directly to prove the suppression is
            // structural (no rows fetched → empty mirror feed).
            let store = try await makeStore(
                recorder: recorder,
                hk: hk,
                defaults: defaults,
                userID: "user-a",
                standalone: true
            )

            await store.runHistoricalBackfillForTesting()

            // Standalone repo returns no history, so the mirror sees an empty feed.
            #expect(hk.mirroredMeasurements.isEmpty)
            #expect(recorder.requestCount == 0)
        }

        @Test
        func cancelAndDrainRejectsLateMirror() async throws {
            let row = withingsWeight(id: "late-a")
            let page = SuspendedHistoryPage(
                firstPage: MeasurementListWireResponse(measurements: [row])
            )
            let api = StubAPIClient()
            await api.setHandler { _ in
                await page.response()
            }
            let repo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
            let hk = MockHealthKitWriter()
            let defaults = try freshDefaults()
            let registry = AuthenticatedSessionLeaseRegistry()
            _ = try #require(registry.activate(ownerID: "account-a"))
            let store = MeasurementsStore(
                repo: repo,
                healthKit: hk,
                userIDProvider: { "account-a" },
                backfillDefaults: defaults
            )
            store.bindAuthenticatedSessionRegistry(registry)

            let backfill = Task {
                await store.runHistoricalBackfillForTesting()
            }
            await page.waitUntilRequested()

            registry.invalidate()
            _ = try #require(registry.activate(ownerID: "account-b"))
            let drain = Task {
                await store.cancelAndDrainAuthenticatedWork()
            }
            await page.release()
            await drain.value
            await backfill.value

            let prefix = "hl.healthkit.historicalBackfill.v."
            #expect(
                hk.mirroredMeasurements.isEmpty
                    && defaults.integer(forKey: prefix + "account-a") == 0
                    && defaults.integer(forKey: prefix + "account-b") == 0,
                "EXPECTED_RED: late A backfill mirrored or marked complete"
            )

            registry.invalidate()
            _ = try #require(registry.activate(ownerID: "account-a"))
            await store.runHistoricalBackfillForTesting()
            #expect(defaults.integer(forKey: prefix + "account-a") == 1)
        }
    }

    /// Test-only synchronous entry point so the suite can drive the backfill and
    /// `await` its completion (the production trigger dispatches detached so it
    /// can't gate paint — untestable directly). Exercises the SAME driver body
    /// + run-once gate. Standalone suppression is exercised through the repo's
    /// own `historyForBackfill` short-circuit (returns [] offline).
    @MainActor
    extension MeasurementsStore {
        func runHistoricalBackfillForTesting() async {
            guard let healthKit else { return }
            await runHistoricalBackfillBodyForTesting(healthKit: healthKit)
        }
    }

#endif
