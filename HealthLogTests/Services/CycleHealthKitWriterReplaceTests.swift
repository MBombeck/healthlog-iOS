import Foundation
@testable import HealthLog
import Testing
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    /// **#115 B6 — editing a cycle day replaces its Apple-Health mirror.**
    ///
    /// The server upserts a day under the same row id, and the writer stamps
    /// that id into `HKMetadataKeyExternalUUID`. Before this fix every save only
    /// appended: an edit wrote a second full set of samples for the day, so
    /// Apple Health showed the flow twice. The writer now removes its own
    /// previous samples for the row before it saves the new ones, and never
    /// touches a sample it did not write.
    @Suite("#115 B6 — cycle HK mirror replaces on edit")
    struct CycleHealthKitWriterReplaceTests {
        private static let rowID = "44444444-4444-4444-4444-444444444444"

        /// In-memory stand-in for HealthKit: keeps saved samples, honours the
        /// ownership filter the live store applies, records the call order.
        actor FakeStore: CycleHealthSampleStore {
            private(set) var stored: [HKSample] = []
            private(set) var calls: [String] = []

            func seed(_ samples: [HKSample]) {
                stored += samples
            }

            func ownMirrorSamples(dayLogID: String) async throws -> [HKSample] {
                calls.append("fetch")
                return stored.filter {
                    CycleHealthKitWriter.isOwnMirror(metadata: $0.metadata, isFromThisApp: false, dayLogID: dayLogID)
                }
            }

            func delete(_ samples: [HKSample]) async throws {
                calls.append("delete")
                let gone = Set(samples.map(\.uuid))
                stored.removeAll { gone.contains($0.uuid) }
            }

            func save(_ samples: [HKCategorySample]) async throws {
                calls.append("save")
                stored += samples
            }
        }

        private func dayLog(flow: String?, symptoms: [[String: Any]] = []) throws -> CycleDayLogDTO {
            var obj: [String: Any] = [
                "id": Self.rowID,
                "date": "2026-09-20",
                "source": "MANUAL",
                "syncVersion": 1,
                "intermenstrualBleeding": false,
                "sexualActivity": false,
                "symptoms": symptoms
            ]
            if let flow { obj["flow"] = flow }
            return try JSONDecoder().decode(CycleDayLogDTO.self, from: JSONSerialization.data(withJSONObject: obj))
        }

        private func flowCount(_ samples: [HKSample]) -> Int {
            samples.count(where: { ($0 as? HKCategorySample)?.categoryType.identifier == CycleHealthKitMapping.menstrualFlow })
        }

        @Test("saving the same day twice leaves one flow sample, carrying the edited value")
        func editReplacesPreviousMirror() async throws {
            let store = FakeStore()
            let writer = CycleHealthKitWriter(sampleStore: store)

            try await writer.write(dayLog(flow: "LIGHT"), isCycleStart: true)
            try await writer.write(dayLog(flow: "HEAVY"), isCycleStart: true)

            let stored = await store.stored
            #expect(flowCount(stored) == 1)
            let flow = try #require(stored.first as? HKCategorySample)
            #expect(flow.value == 4) // HKCategoryValueVaginalBleedingHeavy
            #expect(await store.calls == ["fetch", "save", "fetch", "delete", "save"])
        }

        @Test("clearing the flow removes the previous flow sample")
        func clearedFlowRemovesMirror() async throws {
            let store = FakeStore()
            let writer = CycleHealthKitWriter(sampleStore: store)

            try await writer.write(dayLog(flow: "MEDIUM"), isCycleStart: false)
            try await writer.write(dayLog(flow: "NONE"), isCycleStart: false)

            #expect(await store.stored.isEmpty)
        }

        @Test("a foreign sample with the same external UUID but no app marker stays")
        func foreignSampleIsNotTouched() async throws {
            let type = try #require(HKObjectType.categoryType(forIdentifier: .menstrualFlow))
            let noon = Date(timeIntervalSince1970: 1_790_000_000)
            let foreign = HKCategorySample(
                type: type,
                value: 2,
                start: noon,
                end: noon,
                metadata: [HKMetadataKeyExternalUUID: Self.rowID, HKMetadataKeyMenstrualCycleStart: false]
            )
            let store = FakeStore()
            await store.seed([foreign])
            let writer = CycleHealthKitWriter(sampleStore: store)

            try await writer.write(dayLog(flow: "LIGHT"), isCycleStart: false)

            let ids = await store.stored.map(\.uuid)
            #expect(ids.contains(foreign.uuid))
            #expect(ids.count == 2)
        }

        @Test("ownership: marker or this app's source, and always the same row id")
        func ownershipPredicate() {
            let marker = [HealthKitSampleOwnership.appOriginMetadataKey: HealthKitSampleOwnership.appOriginMetadataValue]
            let own = marker.merging([HKMetadataKeyExternalUUID: Self.rowID]) { $1 }
            #expect(CycleHealthKitWriter.isOwnMirror(metadata: own, isFromThisApp: false, dayLogID: Self.rowID))
            // An older mirror without the marker, authored by this app.
            #expect(CycleHealthKitWriter.isOwnMirror(
                metadata: [HKMetadataKeyExternalUUID: Self.rowID], isFromThisApp: true, dayLogID: Self.rowID
            ))
            #expect(!CycleHealthKitWriter.isOwnMirror(
                metadata: [HKMetadataKeyExternalUUID: Self.rowID], isFromThisApp: false, dayLogID: Self.rowID
            ))
            // Another day's row is never ours to replace here.
            #expect(!CycleHealthKitWriter.isOwnMirror(metadata: own, isFromThisApp: true, dayLogID: "other"))
            #expect(!CycleHealthKitWriter.isOwnMirror(metadata: nil, isFromThisApp: true, dayLogID: Self.rowID))
        }
    }

#endif
