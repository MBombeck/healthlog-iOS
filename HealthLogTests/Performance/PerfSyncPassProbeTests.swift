#if HL_PERF_PROBES && canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Synchronization
    import XCTest

    /// **PERF (1.5) — the app-side cost of a foreground sync pass, for comparing
    /// two builds.**
    ///
    /// Not a gate and not a budget, like `LaunchPerformanceProbeTest`: the numbers
    /// only mean something next to the same probe on another build, on the same
    /// simulator, in the same hour. Compiled only with `-D HL_PERF_PROBES` (so a
    /// release run never records it as skipped) and skips unless `TEST_RUNNER_HL_PERF_OUT` names a
    /// host file the samples are appended to.
    ///
    /// Two seams, both network-free and HealthKit-free:
    /// - the orchestrator planning and running a `.foreground` pass over every
    ///   capability (each one answers at once), so only the coordination is timed;
    /// - one page of 3000 fixture samples (pulse, SpO2, steps over three days)
    ///   through the wire gate and the batch uploader to a server that accepts
    ///   everything at once: mapping, encoding, chunking and the verdict walk.
    final class PerfSyncPassProbeTests: XCTestCase {
        private var outputFile: String {
            ProcessInfo.processInfo.environment["HL_PERF_OUT"] ?? ""
        }

        override func setUpWithError() throws {
            let missing = outputFile.isEmpty
            try XCTSkipIf(missing, "HL_PERF_OUT not set — the sync probe only runs on request")
        }

        // MARK: - Orchestration

        private static func registry() -> HealthSyncCapabilityRegistry {
            func make(_ capability: HealthSyncCapability) -> HealthSyncCapabilityRegistry.Run {
                { _ in HealthSyncCapabilityResult(capability: capability, disposition: .succeeded) }
            }
            return HealthSyncCapabilityRegistry(
                speziSampleCollection: make(.speziSampleCollection),
                workoutImport: make(.workoutImport),
                ecgUpload: make(.ecgUpload),
                dailyStatistics: make(.dailyStatistics),
                heartRateBuckets: make(.heartRateBuckets),
                nutrientDailyTotals: make(.nutrientDailyTotals),
                moodStateOfMindImport: make(.moodStateOfMindImport),
                appleMedicationImport: make(.appleMedicationImport),
                cycleImport: make(.cycleImport),
                heartHealthEvents: make(.heartHealthEvents),
                outboxDrain: make(.outboxDrain),
                serverMirror: make(.serverMirror)
            )
        }

        func test_foregroundPassOrchestration() async {
            // Warm-up, not recorded.
            for _ in 0 ..< 10 {
                _ = await HealthSyncOrchestrator(registry: Self.registry()).run(.foreground)
            }
            var samples: [Double] = []
            for _ in 0 ..< 200 {
                let start = DispatchTime.now().uptimeNanoseconds
                let outcome = await HealthSyncOrchestrator(registry: Self.registry()).run(.foreground)
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1000)
                XCTAssertFalse(outcome.planned.isEmpty)
            }
            record(String(format: "sync orchestration_us_median=%.1f n=%d", Self.median(samples), samples.count))
        }

        // MARK: - Wire pass

        /// Accepts every row at once and counts what it saw.
        final class AcceptingServer: APIClientProtocol, @unchecked Sendable {
            private let state = Mutex<(calls: Int, rows: Int)>((0, 0))

            var rows: Int {
                state.withLock { $0.rows }
            }

            func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
                guard let body = request.body else { throw HLError.unknown("no body") }
                let payload = try BatchUploadOutcomeTests.batchDecoder().decode(HealthKitBatchPayload.self, from: body)
                state.withLock {
                    $0.calls += 1
                    $0.rows += payload.entries.count
                }
                let response = HealthKitBatchResponseDTO(
                    processed: payload.entries.count,
                    inserted: payload.entries.count,
                    duplicates: 0,
                    skipped: [],
                    entries: payload.entries.indices.map { .init(index: $0, status: .inserted) }
                )
                guard let typed = response as? T else { throw HLError.unknown("T mismatch") }
                return typed
            }

            func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

            func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
                throw HLError.unknown("download not implemented")
            }
        }

        private static func fixtureSamples() -> [HKSample] {
            let origin = Date(timeIntervalSince1970: 1_790_000_000)
            var samples: [HKSample] = []
            for index in 0 ..< 1000 {
                let date = origin.addingTimeInterval(Double(index) * 259)
                samples.append(HKQuantitySample(
                    type: HKQuantityType(.heartRate),
                    quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: 55 + Double(index % 40)),
                    start: date,
                    end: date
                ))
                samples.append(HKQuantitySample(
                    type: HKQuantityType(.oxygenSaturation),
                    quantity: HKQuantity(unit: .percent(), doubleValue: 0.94 + Double(index % 5) / 100),
                    start: date.addingTimeInterval(7),
                    end: date.addingTimeInterval(7)
                ))
                samples.append(HKQuantitySample(
                    type: HKQuantityType(.stepCount),
                    quantity: HKQuantity(unit: .count(), doubleValue: Double(20 + index % 300)),
                    start: date,
                    end: date.addingTimeInterval(120)
                ))
            }
            return samples
        }

        func test_wirePassTransmit() async throws {
            let samples = Self.fixtureSamples()
            var mapSamples: [Double] = []
            var sendSamples: [Double] = []
            var rows = 0
            for iteration in 0 ..< 8 {
                let registry = AuthenticatedSessionLeaseRegistry()
                let lease = try CollectorFixture.makeLease(registry: registry)
                let server = AcceptingServer()
                let consumption = HealthSampleConsumption(
                    uploader: MeasurementBatchUploader(
                        api: server,
                        throttle: BatchSyncThrottle(maxPerWindow: 100_000, jitter: 0 ... 0),
                        syncTrigger: SyncTriggerContext()
                    ),
                    gate: HealthSampleWireGate(dailyStatsEnabled: false, hrBucketGate: nil),
                    retry: HealthSampleBackfillAndHoldTests.RecordingRetry(),
                    skipRegister: HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage),
                    build: "300"
                )
                let mapStart = DispatchTime.now().uptimeNanoseconds
                let page = HealthSampleWireGate(dailyStatsEnabled: false, hrBucketGate: nil).map(samples)
                let mapEnd = DispatchTime.now().uptimeNanoseconds
                _ = await consumption.transmitReporting(page, admitted: lease)
                let sendEnd = DispatchTime.now().uptimeNanoseconds
                rows = server.rows
                // The first round warms caches and is not recorded.
                guard iteration > 0 else { continue }
                mapSamples.append(Double(mapEnd - mapStart) / 1_000_000)
                sendSamples.append(Double(sendEnd - mapEnd) / 1_000_000)
            }
            XCTAssertGreaterThan(rows, 0)
            record(String(
                format: "sync wire_map_ms_median=%.2f wire_send_ms_median=%.2f rows=%d samples=%d n=%d",
                Self.median(mapSamples), Self.median(sendSamples), rows, samples.count, mapSamples.count
            ))
        }

        // MARK: - Output

        private static func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return .nan }
            let mid = sorted.count / 2
            return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        }

        private func record(_ line: String) {
            let url = URL(fileURLWithPath: outputFile)
            let data = Data((line + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
#endif
