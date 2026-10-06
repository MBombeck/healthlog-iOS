#if canImport(HealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// **S1 / public #11** — a blood-pressure reading typed on the web never
    /// reached Apple Health: the server stores it as `MANUAL`, and the
    /// server→Health mirror excluded `.manual` as "already round-tripped at
    /// create-time". `.manual` is now mirrored, so these tests pin the dedup
    /// that keeps this device's own create-time samples from being written a
    /// second time, the update path (samples older builds wrote), and the echo
    /// filter that keeps a mirrored sample from being uploaded again.
    ///
    /// The planner is fed a fake Health state: CI has no Health database and no
    /// share authorization.
    @Suite("Server→Apple-Health mirror dedup for manual rows (S1)")
    struct HealthKitServerMirrorDedupTests {
        private static let instant = Date(timeIntervalSince1970: 1_759_250_940)

        /// A fake Health state: which server ids are already stamped on a
        /// sample, which own samples exist, and whether writes are authorized.
        private struct FakeHealth {
            var stampedIDs: Set<String> = []
            var ownSamples: [HKQuantitySample] = []
            var authorized = true

            var probe: HealthKitServerMirrorProbe {
                let stamped = stampedIDs
                let own = ownSamples
                let authorized = authorized
                return HealthKitServerMirrorProbe(
                    isShareAuthorized: { _ in authorized },
                    existsWithExternalIDs: { ids, _ in !stamped.isDisjoint(with: ids) },
                    ownSamplesNear: { type, instant in
                        own.filter { $0.quantityType == type && abs($0.startDate.timeIntervalSince(instant)) < 1 }
                    }
                )
            }
        }

        private func webBloodPressure(
            id: String = "srv-sys-1",
            diastolicID: String? = "srv-dia-1",
            source: MeasurementSource = .manual
        ) -> HealthLog.Measurement {
            HealthLog.Measurement(
                id: id,
                kind: .bloodPressure,
                recordedAt: Self.instant,
                value: .bloodPressure(systolic: 116, diastolic: 86),
                source: source,
                bloodPressureDiastolicId: diastolicID
            )
        }

        private func weight(id: String, kg: Double = 81.2) -> HealthLog.Measurement {
            HealthLog.Measurement(id: id, kind: .weight, recordedAt: Self.instant, value: .scalar(kg), source: .manual)
        }

        private func sample(
            _ identifier: HKQuantityTypeIdentifier,
            _ unit: HKUnit,
            _ value: Double,
            at instant: Date = Self.instant,
            metadata: [String: Any]? = nil
        ) -> HKQuantitySample {
            HKQuantitySample(
                type: HKQuantityType(identifier),
                quantity: HKQuantity(unit: unit, doubleValue: value),
                start: instant,
                end: instant,
                metadata: metadata
            )
        }

        // MARK: - The reported case

        @Test("a web-entered blood pressure (MANUAL, not in Health) is written with its server id")
        func webManualBloodPressureIsWritten() async {
            let plan = await HealthKitServerMirrorPlanner.plan(
                [webBloodPressure()],
                excluding: [],
                probe: FakeHealth().probe
            )

            #expect(plan.samples.count == 2)
            #expect(plan.samples.allSatisfy { $0.metadata?[HKMetadataKeyExternalUUID] as? String == "srv-sys-1" })
            #expect(plan.samples.allSatisfy {
                $0.metadata?[HealthKitSampleOwnership.appOriginMetadataKey] as? String
                    == HealthKitSampleOwnership.appOriginMetadataValue
            })
            #expect(Set(plan.samples.map(\.quantityType)) == [
                HKQuantityType(.bloodPressureSystolic), HKQuantityType(.bloodPressureDiastolic)
            ])
            #expect(plan.linkageIDs == ["srv-sys-1", "srv-dia-1"])
        }

        @Test("every kind the app may write follows the same rule for manual rows", arguments: [
            (MetricKind.weight, 81.2),
            (MetricKind.glucose, 104.0),
            (MetricKind.bodyTemperature, 36.8),
            (MetricKind.spo2, 97.0),
            (MetricKind.pulse, 64.0)
        ])
        func manualScalarKindsAreWritten(kind: MetricKind, value: Double) async {
            let row = HealthLog.Measurement(
                id: "srv-\(kind.rawValue)", kind: kind, recordedAt: Self.instant, value: .scalar(value), source: .manual
            )
            let plan = await HealthKitServerMirrorPlanner.plan([row], excluding: [], probe: FakeHealth().probe)
            #expect(plan.samples.count == 1)
            #expect(plan.samples.first?.metadata?[HKMetadataKeyExternalUUID] as? String == row.id)
        }

        @Test("without share authorization nothing is written")
        func unauthorizedWritesNothing() async {
            var health = FakeHealth()
            health.authorized = false
            let plan = await HealthKitServerMirrorPlanner.plan([webBloodPressure()], excluding: [], probe: health.probe)
            #expect(plan.samples.isEmpty)
        }

        @Test("APPLE_HEALTH and provider rows stay out of the mirror")
        func nonAuthoringSourcesStayOut() async {
            let rows = [MeasurementSource.appleHealth, .whoop, .external, .telegram, .mcp].map {
                webBloodPressure(id: "srv-\($0)", diastolicID: nil, source: $0)
            }
            let plan = await HealthKitServerMirrorPlanner.plan(rows, excluding: [], probe: FakeHealth().probe)
            #expect(plan.samples.isEmpty)
        }

        // MARK: - This device's own create-time sample

        @Test("a manual row this app already wrote at create-time is skipped (server id stamped)")
        func ownCreateTimeSampleIsSkipped() async {
            var health = FakeHealth()
            health.stampedIDs = ["srv-sys-1"]
            let plan = await HealthKitServerMirrorPlanner.plan([webBloodPressure()], excluding: [], probe: health.probe)
            #expect(plan.samples.isEmpty)
        }

        @Test("update path: a BP sample an older build stamped with the DIASTOLIC id is not duplicated")
        func legacyDiastolicStampIsSkipped() async {
            // Builds up to 287 returned the id of the last POST (the diastolic
            // row) from create, so the create-time sample carries that id while
            // the list carries the systolic id.
            var health = FakeHealth()
            health.stampedIDs = ["srv-dia-1"]
            let plan = await HealthKitServerMirrorPlanner.plan([webBloodPressure()], excluding: [], probe: health.probe)
            #expect(plan.samples.isEmpty)
        }

        @Test("update path: an own sample WITHOUT id metadata at the same instant and value is not duplicated")
        func legacyOwnSampleWithoutMetadataIsSkipped() async {
            var health = FakeHealth()
            health.ownSamples = [
                sample(.bloodPressureSystolic, .millimeterOfMercury(), 116),
                sample(.bloodPressureDiastolic, .millimeterOfMercury(), 86)
            ]
            let plan = await HealthKitServerMirrorPlanner.plan(
                [webBloodPressure(diastolicID: nil)],
                excluding: [],
                probe: health.probe
            )
            #expect(plan.samples.isEmpty)
        }

        @Test("an own sample with a different value or instant does not suppress the write")
        func differentOwnSampleDoesNotSuppress() async {
            var health = FakeHealth()
            health.ownSamples = [
                sample(.bodyMass, .gramUnit(with: .kilo), 80.0),
                sample(.bodyMass, .gramUnit(with: .kilo), 81.2, at: Self.instant.addingTimeInterval(120))
            ]
            let plan = await HealthKitServerMirrorPlanner.plan([weight(id: "srv-w")], excluding: [], probe: health.probe)
            #expect(plan.samples.count == 1)
        }

        @Test("the value match converts units (pounds sample, kilogram row)")
        func valueMatchConvertsUnits() {
            let candidate = sample(.bodyMass, .gramUnit(with: .kilo), 81.2)
            let inPounds = sample(.bodyMass, .pound(), 81.2 / 0.45359237)
            #expect(HealthKitServerMirrorPlanner.isAlreadyPresent(candidate, among: [inPounds]))
        }

        // MARK: - Claims, tombstones, batch duplicates

        @Test("ids claimed by an in-flight write or tombstoned are skipped; a batch repeat is written once")
        func excludedAndRepeatedIDs() async {
            let rows = [weight(id: "claimed"), weight(id: "fresh"), weight(id: "fresh"), webBloodPressure()]
            let plan = await HealthKitServerMirrorPlanner.plan(
                rows,
                excluding: ["claimed", "srv-dia-1"],
                probe: FakeHealth().probe
            )
            #expect(plan.linkageIDs == ["fresh"])
            #expect(plan.samples.count == 1)
        }

        @Test("tombstones keep the newest ids, drop empties, and only take app-minted deletions")
        func tombstones() throws {
            let suite = "hl.test.mirror.tombstones.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let tombstones = HealthKitMirrorTombstones(defaults: defaults)

            tombstones.record(["a", "", "b"])
            tombstones.record(["a"])
            #expect(tombstones.ids == ["a", "b"])

            tombstones.record((0 ..< HealthKitMirrorTombstones.capacity).map { "n\($0)" })
            #expect(tombstones.ids.count == HealthKitMirrorTombstones.capacity)
            #expect(!tombstones.ids.contains("b"))

            let minted: [String: Any] = [
                HKMetadataKeyExternalUUID: "srv-1",
                HealthKitSampleOwnership.appOriginMetadataKey: HealthKitSampleOwnership.appOriginMetadataValue
            ]
            let foreign: [String: Any] = [HKMetadataKeyExternalUUID: "foreign-1"]
            #expect(HealthKitMirrorTombstones.mintedIDs(fromDeletedMetadata: [minted, foreign, nil]) == ["srv-1"])
        }

        // MARK: - Echo

        @Test("a mirrored manual sample is recognised as this app's own on read-back and on delete")
        func mirroredManualSampleIsOwnEcho() async throws {
            let plan = await HealthKitServerMirrorPlanner.plan([webBloodPressure()], excluding: [], probe: FakeHealth().probe)
            let first = try #require(plan.samples.first)
            let externalUUID = first.metadata?[HKMetadataKeyExternalUUID] as? String
            // The import path drops it (our id + our source), so it is never
            // uploaded again as a new APPLE_HEALTH reading.
            #expect(HealthKitSampleOwnership.isOwnEcho(externalUUID: externalUUID, isFromThisApp: true))
            // The delete path can prove ownership, so a deletion in Apple
            // Health lands in the tombstones.
            #expect(HealthKitSampleOwnership.isAppMintedDeletion(metadata: first.metadata))
        }
    }

#endif
