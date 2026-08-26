#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftData
    import Testing

    @MainActor
    @Suite("Authenticated medications boundary")
    struct AuthenticatedMedicationsBoundaryTests {
        private actor SuspendedMedicationList {
            private var continuation: CheckedContinuation<[MedicationWireDTO], Never>?
            private var entryWaiters: [CheckedContinuation<Void, Never>] = []

            func response() async -> [MedicationWireDTO] {
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

            func release(_ rows: [MedicationWireDTO]) {
                continuation?.resume(returning: rows)
                continuation = nil
            }
        }

        private final class OnlineReachability: ReachabilityProviding, @unchecked Sendable {
            var isOnlineStream: AsyncStream<Bool> {
                get async {
                    AsyncStream { continuation in
                        continuation.yield(true)
                        continuation.finish()
                    }
                }
            }

            func isCurrentlyOnline() async -> Bool {
                true
            }
        }

        @Test("lateAccountAFanoutCannotPublishOrCallbackIntoB")
        func lateAccountAFanoutCannotPublishOrCallbackIntoB() async throws {
            let suspendedList = SuspendedMedicationList()
            let api = StubAPIClient()
            await api.setHandler { request in
                switch request {
                case is APIRequest<[MedicationWireDTO]>:
                    return await suspendedList.response()
                case is APIRequest<[MedicationIntake]>:
                    return [MedicationIntake]()
                case is APIRequest<[ComplianceDay]>:
                    return [ComplianceDay]()
                case is APIRequest<MedicationListLayout>:
                    return MedicationListLayout.default
                case is APIRequest<[MedicationComplianceSummaryEntry]>:
                    return [MedicationComplianceSummaryEntry]()
                case is APIRequest<MedicationCompliancePayload>:
                    return Self.compliancePayload(rate: 91)
                default:
                    throw HLError.unknown("unexpected medications boundary request")
                }
            }

            let outbox = try OutboxQueue(inMemory: true)
            let medicationsRepo = MedicationsRepository(api: api, outbox: outbox)
            let measurementsRepo = MeasurementsRepository(api: api, outbox: outbox)
            let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
            let swr = SWRCoordinator(cache: cache, reachability: OnlineReachability())
            let keychain = InMemoryKeychain()
            try keychain.setString("account-a", forKey: KeychainKey.userID)
            let registry = AuthenticatedSessionLeaseRegistry()
            _ = try #require(registry.activate(ownerID: "account-a"))
            let stores = AppContainer.makeMeasurementsAndMedications(
                measurementsRepo: measurementsRepo,
                medicationsRepo: medicationsRepo,
                healthKit: nil,
                undo: UndoCoordinator(),
                celebration: CelebrationCoordinator(),
                personalRecordsSnapshotBox: PersonalRecordsSnapshotBox(),
                swr: swr,
                keychain: keychain,
                authenticatedSessionRegistry: registry
            )
            let store = stores.medications

            let accountALoad = Task { @MainActor in
                await store.load(force: true)
            }
            await suspendedList.waitUntilRequested()

            registry.invalidate()
            try keychain.setString("account-b", forKey: KeychainKey.userID)
            _ = try #require(registry.activate(ownerID: "account-b"))
            store.clearOnLogout()
            let accountB = Self.medication(id: "account-b-med", name: "Account B")
            store._testForceSet(medications: [accountB])
            store._testForceSet(
                cardSnapshot: .init(rate7: 44, rate30: 55),
                for: accountB.id
            )

            var medicationCallbacks = 0
            var listSettledCallbacks = 0
            store.onMedicationsDidChange = { _ in medicationCallbacks += 1 }
            store.onMedicationsListSettled = { _ in listSettledCallbacks += 1 }

            await suspendedList.release([Self.wire(id: "account-a-med", name: "Account A")])
            await accountALoad.value

            let accountBRemainsIsolated = store.medications == [accountB]
                && store.complianceCardSnapshots[accountB.id]?.rate7 == 44
                && store.complianceCardSnapshots["account-a-med"] == nil
                && medicationCallbacks == 0
                && listSettledCallbacks == 0
                && !store.isLoading
                && store.error == nil
            #expect(
                accountBRemainsIsolated,
                "EXPECTED_RED: late A medication fanout affected B"
            )
        }

        private static func wire(id: String, name: String) -> MedicationWireDTO {
            MedicationWireDTO(
                id: id,
                name: name,
                dose: "1 mg",
                schedules: [MedicationScheduleDTO(windowStart: "08:00")]
            )
        }

        private static func medication(id: String, name: String) -> Medication {
            Medication(
                id: id,
                name: name,
                dose: "1 mg",
                schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])
            )
        }

        private nonisolated static func compliancePayload(rate: Int) -> MedicationCompliancePayload {
            let window = ComplianceWindowResult(
                totalExpected: 1,
                taken: 1,
                skipped: 0,
                missed: 0,
                rate: rate,
                streak: 1
            )
            return MedicationCompliancePayload(compliance7: window, compliance30: window)
        }
    }

#endif
