#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @MainActor
    @Suite("Authenticated measurements boundary")
    struct AuthenticatedMeasurementsBoundaryTests {
        private actor SuspendedRecentPage {
            private var continuation: CheckedContinuation<MeasurementListWireResponse, Never>?
            private var entryWaiters: [CheckedContinuation<Void, Never>] = []

            func response() async -> MeasurementListWireResponse {
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

            func release(_ response: MeasurementListWireResponse) {
                continuation?.resume(returning: response)
                continuation = nil
            }
        }

        @Test
        func lateAccountAResponseCannotPublishIntoB() async throws {
            let page = SuspendedRecentPage()
            let api = StubAPIClient()
            await api.setHandler { request in
                if request is APIRequest<MeasurementSeries> {
                    return MeasurementSeries(
                        kind: .steps,
                        points: [],
                        stats: SeriesStats(mean: 0, min: 0, max: 0, stdDev: 0, count: 0)
                    )
                }
                return await page.response()
            }
            let repo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
            let registry = AuthenticatedSessionLeaseRegistry()
            _ = try #require(registry.activate(ownerID: "account-a"))
            let store = MeasurementsStore(
                repo: repo,
                userIDProvider: { "account-a" }
            )
            store.bindAuthenticatedSessionRegistry(registry)

            let load = Task { await store.load(limit: 1) }
            await page.waitUntilRequested()

            store.clearOnLogout()
            registry.invalidate()
            _ = try #require(registry.activate(ownerID: "account-b"))
            await page.release(
                MeasurementListWireResponse(measurements: [
                    MeasurementWireDTO(
                        id: "late-a",
                        type: .weight,
                        value: 80,
                        measuredAt: Date(timeIntervalSince1970: 1_700_000_000)
                    )
                ])
            )
            await load.value

            #expect(
                store.recent.isEmpty && store.error == nil && !store.isLoading,
                "EXPECTED_RED: late A measurement published into B"
            )
        }
    }

#endif
