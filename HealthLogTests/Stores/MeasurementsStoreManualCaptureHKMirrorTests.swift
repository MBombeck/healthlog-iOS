// Diese Suite testet App-Target-Symbole (`MeasurementsStore` + `MockHealthKitWriter`),
// die in der SPM-Library nicht enthalten sind. SPM-Test-Build überspringt die Datei.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// A manual capture the server accepted is mirrored to HealthKit once; the
    /// anti-duplicate `externalUUID` behaviour lives in the writer.
    @Suite("MeasurementsStore — manual capture mirrors to HealthKit")
    @MainActor
    struct MeasurementsStoreManualCaptureHKMirrorTests {
        @Test("A manual capture mirrors to the HK writer exactly once")
        func captureMirrors() async throws {
            let hk = MockHealthKitWriter()
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
            let store = MeasurementsStore(repo: repo, healthKit: hk)

            let ok = await store.capture(kind: .weight, value: .scalar(81.0), note: nil)

            #expect(ok)
            #expect(hk.writeCallCount == 1)
        }
    }

#endif
