#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// **A5 (1.4, R3 S4)** — which deletions go to the server, in what shape,
    /// and what becomes of one that cannot go at once.
    @Suite("Apple Health deletion forwarder (A5)", .serialized, .mockURLSession)
    struct HealthKitDeletionForwarderTests {
        /// The server's fold and sum lists (v1.43.10), as the HealthKit types
        /// the app reads them from: `CUMULATIVE_HK_TYPES`
        /// (`apple-health-mapping.ts`), `DENSE_INTRADAY_RETENTION_TYPES`
        /// (`dense-intraday-retention.ts`) and `HIGH_FREQUENCY_MEAN_TYPES`
        /// (`apple-health-mapping.ts`).
        static let serverFoldedOrSummed: Set<String> = Set(Self.foldedOrSummed.map(\.rawValue))
            .union(["HKQuantityTypeIdentifierTimeInDaylight"])

        private static let foldedOrSummed: [HKQuantityTypeIdentifier] = [
            // Summed: day and hour totals.
            .stepCount, .activeEnergyBurned, .flightsClimbed, .distanceWalkingRunning,
            // Dense: hourly after 90 days.
            .heartRate, .heartRateVariabilitySDNN, .oxygenSaturation,
            // Means: daily after 36 hours.
            .respiratoryRate, .environmentalAudioExposure, .headphoneAudioExposure, .walkingSpeed, .walkingStepLength,
            .walkingAsymmetryPercentage, .walkingDoubleSupportPercentage, .appleWalkingSteadiness,
            .walkingHeartRateAverage, .stairAscentSpeed, .stairDescentSpeed
        ]

        @Test("only hand-kept readings the server keeps raw are forwarded, and the app collects and sends each of them")
        func forwardedTypesAreRawOnTheServer() {
            let forwarded = HealthSampleDeletionForwarder.forwardedTypes
            #expect(forwarded.isDisjoint(with: Self.serverFoldedOrSummed))
            #expect(forwarded.isDisjoint(with: HealthKitCumulativeTypeConfig.cumulativeIdentifiers))
            #expect(forwarded.isSubset(of: HealthLogSampleTypeRegistry.baseIdentifiers))
            #expect(forwarded.allSatisfy { HealthKitWireConverter.preferredUnit(for: $0) != nil }, "each is sent one row per sample")
            // A6 — waist circumference (read since B5) is the ninth.
            #expect(forwarded.contains(HKQuantityTypeIdentifier.waistCircumference.rawValue))
            #expect(forwarded.count == 9)
        }

        @Test("a large deletion goes out in batches of at most 500, the route's own bound")
        func chunksAtTheServerBound() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let server = RecordingDeletionServer()
            let ids = (0 ..< 1201).map { "W-\($0)" }

            let held = await HealthSampleDeletionForwarder(server: server, queue: nil)
                .forward(ids, ofType: DeletionFixture.weight, requiring: lease)

            #expect(held == nil)
            #expect(server.sent.map(\.count) == [500, 500, 201])
            #expect(server.sent.flatMap { $0 } == ids)
        }

        @Test("offline, every batch waits once in the outbox, also when the page is read again")
        func offlineBatchesWaitOnce() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let outbox = try DeletionFixture.outbox()
            let forwarder = HealthSampleDeletionForwarder(server: RecordingDeletionServer(failing: .offline), queue: outbox)
            let ids = (0 ..< 501).map { "G-\($0)" }
            let glucose = HKQuantityTypeIdentifier.bloodGlucose.rawValue

            let first = await forwarder.forward(ids, ofType: glucose, requiring: lease)
            let again = await forwarder.forward(ids, ofType: glucose, requiring: lease)

            #expect(first == nil)
            #expect(again == nil)
            let rows = await outbox.snapshot
            #expect(rows.map(\.kind) == [.deleteHealthKitSamples, .deleteHealthKitSamples])
            let payloads = try rows.map { try JSONDecoder.hlDefault.decode(
                OutboxQueue.Payloads.DeleteHealthKitSamples.self,
                from: $0.payload
            ) }
            #expect(payloads.map(\.externalIds.count) == [500, 1])
            #expect(rows.allSatisfy { $0.ownerUserID == lease.ownerID })
        }

        @Test("a cancelled send holds the page and keeps nothing")
        func cancelledSendHolds() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let outbox = try DeletionFixture.outbox()

            let held = await HealthSampleDeletionForwarder(server: RecordingDeletionServer(failing: .canceled), queue: outbox)
                .forward(["W-1"], ofType: DeletionFixture.weight, requiring: lease)

            #expect(held == .cancelled)
            #expect(await outbox.snapshot.isEmpty)
        }

        @Test("only the weight goes out when a page of folded types and a weight report deletions")
        func onlyTheRawTypeIsSent() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let server = RecordingDeletionServer()
            let forwarder = HealthSampleDeletionForwarder(server: server, queue: nil)

            for type in Self.serverFoldedOrSummed.sorted() {
                #expect(await forwarder.forward(["F-\(type)"], ofType: type, requiring: lease) == nil)
            }
            #expect(await forwarder.forward(["W-ok"], ofType: DeletionFixture.weight, requiring: lease) == nil)

            #expect(server.sent == [["W-ok"]])
        }

        @Test("a replayed deletion the server refuses is dropped, not dead-lettered: it carries nothing to lose")
        func replayRefusalDropsTheRow() async throws {
            let wire = DeletionWire()
            wire.install()
            wire.answer(.refused)
            let api = DeletionFixture.api()
            let outbox = try DeletionFixture.outbox()
            try await outbox.enqueueHealthKitDeletion(
                ["W-7"],
                idempotencyKey: "a5-\(UUID().uuidString)",
                requiringCurrentOwner: DeletionFixture.owner
            )

            await DeletionFixture.replay(outbox: outbox, api: api).runOnce()

            #expect(wire.all.map(\.externalIds) == [["W-7"]])
            #expect(await outbox.snapshot.isEmpty)
            #expect(await outbox.deadLetterCount == 0)
        }
    }
#endif
