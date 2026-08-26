import Foundation
@testable import HealthLog
import Testing
#if canImport(HealthKit)
    import HealthKit
#endif

// swiftlint:disable force_unwrapping

#if canImport(HealthKit)

    /// **Phase C2 + W-HK-RELIABILITY G-7** — pins the importer's pure
    /// `buildWrites` transform: the echo guard (skip only OUR own echo —
    /// externalUUID **and** authored by this app's HK source), the same-date
    /// merge into one canonical `source:"APPLE_HEALTH"` row, and the date-stable
    /// externalId. `HKCategorySample` constructs without a live store, so this
    /// needs no auth.
    ///
    /// **G-7 note:** a unit-test-constructed `HKCategorySample` is *unsaved*, so
    /// its authoring source is NOT `HKSource.default()` — HealthKit only stamps
    /// the owning source on a store *save*. The test process therefore cannot
    /// forge an own-source echo; under G-7 a UUID-carrying test sample counts as
    /// THIRD-PARTY (different source) and is correctly imported. The own-echo
    /// skip path is unit-tested at the predicate level in
    /// ``HealthKitSampleOwnershipTests``.
    @Suite("Cycle — HealthKit importer buildWrites", .serialized)
    struct CycleHealthKitImporterTests {
        /// `buildWrites` is a pure transform that never touches the network, so a
        /// real `APIClient` (mock session) + in-memory outbox is enough to
        /// construct the repo the importer holds.
        private func makeImporter() throws -> CycleHealthKitImporter {
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.14.8",
                buildNumber: "1"
            )
            let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
            let repo = try CycleRepository(api: api, outbox: OutboxQueue(inMemory: true))
            return CycleHealthKitImporter(
                store: HKHealthStore(),
                repo: repo,
                userID: "test-user",
                defaults: UserDefaults(suiteName: "cycle-hk-importer-tests")!
            )
        }

        private func flowSample(value: Int, on date: Date, externalUUID: String? = nil) -> HKCategorySample {
            let type = HKObjectType.categoryType(
                forIdentifier: HKCategoryTypeIdentifier(rawValue: CycleHealthKitMapping.menstrualFlow)
            )!
            // `HKMetadataKeyMenstrualCycleStart` is REQUIRED by HealthKit on every
            // menstrual-flow sample (`_validateForCreation` raises otherwise);
            // `externalUUID` must be a real UUID string when present.
            var metadata: [String: Any] = [HKMetadataKeyMenstrualCycleStart: false]
            if let externalUUID { metadata[HKMetadataKeyExternalUUID] = externalUUID }
            return HKCategorySample(type: type, value: value, start: date, end: date, metadata: metadata)
        }

        @Test("foreign flow sample becomes an APPLE_HEALTH-source day-log write")
        func foreignSampleMapped() async throws {
            let importer = try makeImporter()
            let day = Date(timeIntervalSince1970: 1_700_000_000)
            let writes = await importer.buildWrites(
                from: [flowSample(value: 4, on: day)],
                identifier: CycleHealthKitMapping.menstrualFlow
            )
            #expect(writes.count == 1)
            #expect(writes.first?.source == "APPLE_HEALTH")
            #expect(writes.first?.flow == .heavy)
            #expect(writes.first?.externalId?.hasPrefix("cycle-hk:") == true)
        }

        @Test("G-7: a UUID-carrying THIRD-PARTY sample is imported (not silently dropped)")
        func thirdPartyUUIDSampleIsImported() async throws {
            // Pre-G-7 this asserted `writes.isEmpty` ("any externalUUID ⇒
            // skip"). That was the bug: a third-party sample carrying an
            // externalUUID was silently dropped. A test-constructed sample is
            // unsaved ⇒ foreign source ⇒ now correctly imported. The own-echo
            // skip (our source) is covered by HealthKitSampleOwnershipTests.
            let importer = try makeImporter()
            let day = Date(timeIntervalSince1970: 1_700_000_000)
            let writes = await importer.buildWrites(
                from: [flowSample(value: 3, on: day, externalUUID: "11111111-1111-1111-1111-111111111111")],
                identifier: CycleHealthKitMapping.menstrualFlow
            )
            #expect(writes.count == 1)
            #expect(writes.first?.source == "APPLE_HEALTH")
            #expect(writes.first?.flow == .medium)
        }

        @Test("same-date samples merge into one canonical row")
        func sameDateMerge() async throws {
            let importer = try makeImporter()
            let day = Date(timeIntervalSince1970: 1_700_000_000)
            // Both are foreign (test-constructed ⇒ not our source), even the one
            // carrying an externalUUID — so both flow in and merge into one
            // canonical day-log row. Last-write-wins on flow (value 4 = heavy).
            let first = flowSample(value: 2, on: day)
            let second = flowSample(value: 4, on: day, externalUUID: "22222222-2222-2222-2222-222222222222")
            let writes = await importer.buildWrites(
                from: [first, second],
                identifier: CycleHealthKitMapping.menstrualFlow
            )
            #expect(writes.count == 1)
            #expect(writes.first?.flow == .heavy)
        }
    }

#endif
