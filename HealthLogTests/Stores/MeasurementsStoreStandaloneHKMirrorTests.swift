// Diese Suite testet App-Target-Symbole (`MeasurementsStore` + `MockHealthKitWriter`),
// die in der SPM-Library nicht enthalten sind. SPM-Test-Build überspringt die Datei.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// v0.14 RISK-1 — dedup option (B): the HK mirror-write for a MANUAL
    /// measurement is suppressed when the app is in standalone/offline mode.
    ///
    /// Rationale: in standalone mode a manual entry is uploaded as `MANUAL` on the
    /// later pair. If we ALSO wrote it to HealthKit, the HK observer would
    /// re-ingest it as `APPLE_HEALTH` on pair → a duplicate of the same physical
    /// reading. Suppressing the mirror at the source keeps exactly one row. The
    /// paired path must keep mirroring (unchanged anti-duplicate `externalUUID`
    /// behaviour).
    @Suite("MeasurementsStore — standalone HK-mirror suppression (dedup B)")
    @MainActor
    struct MeasurementsStoreStandaloneHKMirrorTests {
        /// Builds a store whose repo `create()` succeeds (returns the server wire)
        /// so `capture()` reaches the HK-mirror branch. The `isStandalone`
        /// predicate is injected verbatim so the test controls the mode.
        private func makeStore(
            hk: MockHealthKitWriter,
            standalone: @escaping @Sendable () -> Bool
        ) async throws -> MeasurementsStore {
            let api = StubAPIClient()
            // Echo the create back as a server-saved wire row so the optimistic
            // create resolves successfully and the mirror branch runs.
            await api.setHandler { _ in
                MeasurementWireDTO(
                    id: "server-1",
                    type: .weight,
                    value: 81.0,
                    measuredAt: .now,
                    source: .manual
                )
            }
            let outbox = try OutboxQueue(inMemory: true)
            let repo = MeasurementsRepository(api: api, outbox: outbox)
            return MeasurementsStore(
                repo: repo,
                healthKit: hk,
                isStandalone: standalone
            )
        }

        @Test("Manual capture in STANDALONE mode does NOT hit the HK writer")
        func standaloneSuppressesMirror() async throws {
            let hk = MockHealthKitWriter()
            let store = try await makeStore(hk: hk) { true }

            let ok = await store.capture(kind: .weight, value: .scalar(81.0), note: nil)

            #expect(ok)
            // The mirror-write is suppressed — the MANUAL upload is the only write.
            #expect(hk.writeCallCount == 0)
        }

        @Test("Manual capture while PAIRED DOES mirror to the HK writer (unchanged)")
        func pairedStillMirrors() async throws {
            let hk = MockHealthKitWriter()
            let store = try await makeStore(hk: hk) { false }

            let ok = await store.capture(kind: .weight, value: .scalar(81.0), note: nil)

            #expect(ok)
            // Paired path is unchanged — exactly one mirror-write.
            #expect(hk.writeCallCount == 1)
        }

        @Test("Absent standalone predicate keeps the legacy paired mirror behaviour")
        func nilPredicateMirrors() async throws {
            let hk = MockHealthKitWriter()
            let api = StubAPIClient()
            await api.setHandler { _ in
                MeasurementWireDTO(
                    id: "server-2",
                    type: .weight,
                    value: 81.0,
                    measuredAt: .now,
                    source: .manual
                )
            }
            let outbox = try OutboxQueue(inMemory: true)
            let repo = MeasurementsRepository(api: api, outbox: outbox)
            // No `isStandalone` argument → the store defaults to the paired mirror.
            let store = MeasurementsStore(repo: repo, healthKit: hk)

            let ok = await store.capture(kind: .weight, value: .scalar(81.0), note: nil)

            #expect(ok)
            #expect(hk.writeCallCount == 1)
        }
    }

#endif
