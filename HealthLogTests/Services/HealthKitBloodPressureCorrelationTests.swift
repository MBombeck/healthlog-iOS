#if canImport(HealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// **T4 / public #15** — "the measurement of blood pressure isn't synced to
    /// Apple Health". Every build up to 290 saved a manual blood pressure as two
    /// LOOSE quantity samples (systolic, diastolic). Apple Health presents blood
    /// pressure only as an `HKCorrelation` of type `.bloodPressure`, so the
    /// reading never showed up as one. The create-time write and the
    /// server→Health mirror now save one correlation per reading; the child
    /// samples keep the metadata the dedup probe, the echo filter and the
    /// tombstones read.
    @Suite("Blood pressure reaches Apple Health as one correlation (T4, #15)")
    struct HealthKitBloodPressureCorrelationTests {
        private static let instant = Date(timeIntervalSince1970: 1_759_560_180)
        private static let mmHg = HKUnit.millimeterOfMercury()

        private let reading = HealthLog.Measurement(
            id: "srv-1",
            kind: .bloodPressure,
            recordedAt: instant,
            value: .bloodPressure(systolic: 128, diastolic: 84),
            source: .manual,
            bloodPressureDiastolicId: "srv-2"
        )

        private func objects(for measurement: HealthLog.Measurement) -> [HKObject] {
            let metadata = HealthKitServerMirrorPlanner.metadata(for: measurement)
            return HealthKitService.healthObjects(
                for: measurement,
                samples: HealthKitService.quantitySamples(for: measurement, metadata: metadata),
                metadata: metadata
            )
        }

        @Test("a blood pressure is saved as exactly one bloodPressure correlation holding both values")
        func bloodPressureIsOneCorrelation() throws {
            let saved = objects(for: reading)

            #expect(saved.count == 1)
            let correlation = try #require(saved.first as? HKCorrelation)
            #expect(correlation.correlationType == HKCorrelationType(.bloodPressure))
            #expect(correlation.startDate == Self.instant)
            #expect(correlation.endDate == Self.instant)
            #expect(correlation.metadata?[HKMetadataKeyExternalUUID] as? String == "srv-1")

            let systolic = correlation.objects(for: HKQuantityType(.bloodPressureSystolic))
                .compactMap { $0 as? HKQuantitySample }
            let diastolic = correlation.objects(for: HKQuantityType(.bloodPressureDiastolic))
                .compactMap { $0 as? HKQuantitySample }
            #expect(systolic.map { $0.quantity.doubleValue(for: Self.mmHg) } == [128])
            #expect(diastolic.map { $0.quantity.doubleValue(for: Self.mmHg) } == [84])
            // The children keep the id the dedup probe and the echo filter read.
            #expect((systolic + diastolic).allSatisfy {
                $0.metadata?[HKMetadataKeyExternalUUID] as? String == "srv-1"
            })
        }

        @Test("a single-value kind is saved as its sample, unchanged")
        func scalarIsUnchanged() {
            let weight = HealthLog.Measurement(
                id: "srv-w", kind: .weight, recordedAt: Self.instant, value: .scalar(81.2), source: .manual
            )
            let saved = objects(for: weight)
            #expect(saved.count == 1)
            #expect(saved.first is HKQuantitySample)
        }

        @Test("the server→Health mirror plan saves the same single correlation for a BP row")
        func mirrorPlanSavesCorrelation() async {
            let probe = HealthKitServerMirrorProbe(
                isShareAuthorized: { _ in true },
                existsWithExternalIDs: { _, _ in false },
                ownSamplesNear: { _, _ in [] }
            )
            let plan = await HealthKitServerMirrorPlanner.plan([reading], excluding: [], probe: probe)

            // Dedup still reasons over the two samples …
            #expect(plan.samples.count == 2)
            // … but what is saved is one correlation.
            #expect(plan.objects.count == 1)
            #expect((plan.objects.first as? HKCorrelation)?.correlationType == HKCorrelationType(.bloodPressure))
            #expect(plan.linkageIDs == ["srv-1", "srv-2"])
        }
    }
#endif
