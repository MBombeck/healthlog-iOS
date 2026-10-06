// Diese Suite testet App-Target-Symbole (`MeasurementsStore` + `MockHealthKitWriter`),
// die in der SPM-Library nicht enthalten sind. SPM-Test-Build überspringt die Datei.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// **S1 / public #11** — the create-time Apple-Health write must carry the
    /// server id the list (and so the server→Health mirror) will see, or the
    /// mirror writes the same reading a second time now that `.manual` rows are
    /// mirrored.
    ///
    /// Blood pressure is two POSTs (systolic, then diastolic). The list merges
    /// the pair under the SYSTOLIC id; create returned the id of the LAST POST,
    /// so the create-time sample carried the diastolic id and never matched.
    @Suite("Manual capture — Apple-Health linkage id (S1)")
    @MainActor
    struct ManualCaptureHealthLinkageTests {
        private final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func next() -> Int {
                lock.withLock {
                    value += 1
                    return value
                }
            }
        }

        private func bloodPressureAPI() async -> StubAPIClient {
            let api = StubAPIClient()
            let counter = Counter()
            await api.setHandler { _ in
                let call = counter.next()
                return MeasurementWireDTO(
                    id: call == 1 ? "srv-sys-1" : "srv-dia-1",
                    type: call == 1 ? .bloodPressureSystolic : .bloodPressureDiastolic,
                    value: call == 1 ? 116 : 86,
                    measuredAt: Date(timeIntervalSince1970: 1_759_250_940),
                    source: .manual
                )
            }
            return api
        }

        @Test("BP create returns the systolic id (the list's id) with the diastolic peer")
        func bloodPressureCreateReturnsListID() async throws {
            let repo = try await MeasurementsRepository(api: bloodPressureAPI(), outbox: OutboxQueue(inMemory: true))
            let saved = try await repo.create(HealthLog.Measurement(
                id: "local-bp",
                kind: .bloodPressure,
                recordedAt: Date(timeIntervalSince1970: 1_759_250_940),
                value: .bloodPressure(systolic: 116, diastolic: 86),
                source: .manual
            ))
            #expect(saved.id == "srv-sys-1")
            #expect(saved.bloodPressureDiastolicId == "srv-dia-1")
            #expect(saved.serverMirrorLinkageIDs == ["srv-sys-1", "srv-dia-1"])
        }

        @Test("the create-time Health write of a BP capture carries the id the list will carry")
        func captureWritesListID() async throws {
            let hk = MockHealthKitWriter()
            let repo = try await MeasurementsRepository(api: bloodPressureAPI(), outbox: OutboxQueue(inMemory: true))
            let store = MeasurementsStore(repo: repo, healthKit: hk, isStandalone: { false })

            let ok = await store.capture(kind: .bloodPressure, value: .bloodPressure(systolic: 116, diastolic: 86), note: nil)

            #expect(ok)
            #expect(hk.writtenMeasurements.map(\.id) == ["srv-sys-1"])
            // The list merges the same wire pair under this id.
            let listed = MeasurementAggregator.mergeBloodPressure([
                MeasurementWireDTO(
                    id: "srv-sys-1", type: .bloodPressureSystolic, value: 116,
                    measuredAt: Date(timeIntervalSince1970: 1_759_250_940), source: .manual
                ),
                MeasurementWireDTO(
                    id: "srv-dia-1", type: .bloodPressureDiastolic, value: 86,
                    measuredAt: Date(timeIntervalSince1970: 1_759_250_940), source: .manual
                )
            ])
            #expect(listed.map(\.id) == hk.writtenMeasurements.map(\.id))
        }

        @Test("an offline capture writes nothing to Health under its local id")
        func offlineCaptureWritesNothing() async throws {
            let api = StubAPIClient()
            await api.setHandler { _ in throw HLError.offline }
            let hk = MockHealthKitWriter()
            let repo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
            let store = MeasurementsStore(repo: repo, healthKit: hk, isStandalone: { false })

            let outcome = await store.captureReturningOutcome(kind: .weight, value: .scalar(81.2), note: nil)

            #expect(outcome == .queued)
            // No sample under `local-…`: the replayed row reaches Health through
            // the server→Health mirror, under its server id, exactly once.
            #expect(hk.writeCallCount == 0)
        }
    }

#endif
