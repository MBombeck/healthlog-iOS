#if canImport(HealthKit) && !SWIFT_PACKAGE
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// **REG (1.5) — public #15, #11, Server #1247 (mills1975): the diastolic
    /// value was missing on the server, and the blood pressure never showed up
    /// in Apple Health.**
    ///
    /// One reading, end to end, entered on the iPhone and on the Watch: the
    /// server ends up with a systolic AND a diastolic row, and what the app
    /// hands Apple Health is exactly one `bloodPressure` correlation holding
    /// both values. The halves are pinned on their own by
    /// `BPPairCreateIdempotencyTests` (server) and
    /// `HealthKitBloodPressureCorrelationTests` (Health); this suite runs the
    /// one reading through both.
    @Suite("REG public #15, #11, Server #1247: one reading, one pair, one correlation")
    @MainActor
    struct Regression_public_15 {
        /// The server's write side for `POST /api/measurements`: one row per
        /// create, keyed by idempotency key like the real replay cache.
        private final class MeasurementsServer: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: [(type: String, value: Double)] = []
            private var cache: [String: MeasurementWireDTO] = [:]

            var rows: [(type: String, value: Double)] {
                lock.withLock { stored }
            }

            func handle(_ request: any Sendable) throws -> any Sendable {
                if request is APIRequest<MeasurementListWireResponse> {
                    return MeasurementListWireResponse(measurements: [])
                }
                guard let req = request as? APIRequest<MeasurementWireDTO>, req.method == .post,
                      let body = req.body,
                      let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let wireType = json["type"] as? String,
                      let value = json["value"] as? Double else { throw HLError.unknown("unexpected request \(type(of: request))") }
                return lock.withLock { () -> MeasurementWireDTO in
                    let cell = "\(req.idempotencyKey.raw)|\(req.path)"
                    if let replay = cache[cell] { return replay }
                    stored.append((wireType, value))
                    let wire = MeasurementWireDTO(
                        id: "srv-\(stored.count)",
                        type: ServerMeasurementType(rawValue: wireType) ?? .weight,
                        value: value,
                        measuredAt: Date(timeIntervalSince1970: 1_759_250_940),
                        source: .manual
                    )
                    cache[cell] = wire
                    return wire
                }
            }
        }

        enum Entry: String, CaseIterable {
            case iPhone, watch
        }

        @Test("a reading from iPhone or Watch: a SYS/DIA pair at the server, one correlation for Health", arguments: Entry.allCases)
        func readingReachesBothSides(entry: Entry) async throws {
            let server = MeasurementsServer()
            let api = StubAPIClient()
            await api.setHandler { try server.handle($0) }
            let repo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
            let health = MockHealthKitWriter()
            let store = MeasurementsStore(repo: repo, healthKit: health, isStandalone: { false })

            let saved: Bool
            switch entry {
            case .iPhone:
                // The Erfassen sheet's call.
                saved = await store.capture(kind: .bloodPressure, value: .bloodPressure(systolic: 128, diastolic: 84), note: nil)
            case .watch:
                // The wrist hands the phone kind, primary and secondary value;
                // `AppContainer+Watch` maps and routes them like this.
                let kind = WatchMeasurementKind.bloodPressure
                saved = await store.captureReturningOutcome(
                    kind: kind.metricKind,
                    value: kind.measurementValue(value: 128, secondary: 84),
                    note: nil
                ) == .success
            }
            #expect(saved)

            // Server: both halves, each once.
            #expect(server.rows.map(\.type) == ["BLOOD_PRESSURE_SYS", "BLOOD_PRESSURE_DIA"])
            #expect(server.rows.map(\.value) == [128, 84])

            // Health: the reading handed over once, linked to both rows ...
            #expect(health.writtenMeasurements.count == 1)
            let written = try #require(health.writtenMeasurements.first)
            #expect(written.serverMirrorLinkageIDs == ["srv-1", "srv-2"])
            // ... and saved as what `HealthKitService.writeMeasurement` builds
            // for it: one bloodPressure correlation, both values inside.
            let metadata = HealthKitService.createTimeMetadata(for: written)
            let objects = HealthKitService.healthObjects(
                for: written,
                samples: HealthKitService.quantitySamples(for: written, metadata: metadata),
                metadata: metadata
            )
            #expect(objects.count == 1)
            let correlation = try #require(objects.first as? HKCorrelation)
            #expect(correlation.correlationType == HKCorrelationType(.bloodPressure))
            let mmHg = HKUnit.millimeterOfMercury()
            let systolic = correlation.objects(for: HKQuantityType(.bloodPressureSystolic)).compactMap { $0 as? HKQuantitySample }
            let diastolic = correlation.objects(for: HKQuantityType(.bloodPressureDiastolic)).compactMap { $0 as? HKQuantitySample }
            #expect(systolic.map { $0.quantity.doubleValue(for: mmHg) } == [128])
            #expect(diastolic.map { $0.quantity.doubleValue(for: mmHg) } == [84])
        }
    }
#endif
