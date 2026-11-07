#if canImport(HealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog

    /// REG (1.5) — barriers on the coordinator itself, so a case waits for a
    /// decision instead of sleeping and hoping load did not outlast the sleep.
    extension HealthKitHRBucketSyncCoordinator {
        /// `sync()`, entered with `gate` signalled on the coordinator's own
        /// executor: from `arrive()` to the join-or-start decision nothing
        /// else runs on the coordinator. This is the body of
        /// ``requestHRBucketSweep()``, minus the unobservable task hop.
        func sync(signalling gate: ArrivalGate) async -> Int {
            gate.arrive()
            return await sync()
        }

        /// Returns once the coordinator is free. After a `sync(signalling:)`
        /// has arrived, that is after its decision: the caller held the actor
        /// from the signal until it suspended.
        func drainedBarrier() {}
    }

    /// SYNC-HR — shared doubles for the heart-rate sweep stall and resume
    /// suites: a settable clock, a HealthKit read that can hang, a server
    /// that accepts every bucket, and a health store that never answers.
    enum HRBucketSweepTestSupport {
        static let user = "user-sync-hr"

        static func iso(_ value: String) -> Date {
            // swiftlint:disable:next force_unwrapping
            ISO8601DateFormatter.fractional.date(from: value)!
        }

        static func row(_ start: String, bpm: Double = 70) -> HealthKitHRBucketRow {
            HealthKitHRBucketRow(bucketStartUTC: iso(start), averageBpm: bpm, minBpm: bpm - 2, maxBpm: bpm + 2)
        }

        static func bucketId(_ start: String) -> String {
            "stats:HKQuantityTypeIdentifierHeartRate:\(start)"
        }

        /// Polls `condition` for up to `seconds`; `true` when it held.
        static func eventually(within seconds: Double = 5, _ condition: @Sendable () async -> Bool) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
            while ContinuousClock.now < deadline {
                if await condition() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return await condition()
        }

        /// Runs `body` in its own task and returns its value if it finishes
        /// within `seconds`, `nil` otherwise. A body that never returns is
        /// left parked, so a red run fails instead of hanging the suite.
        static func completes<T: Sendable>(
            within seconds: Double = 5,
            _ body: @escaping @Sendable () async -> T
        ) async -> T? {
            let box = Box<T>()
            Task { await box.set(body()) }
            _ = await eventually(within: seconds) { box.value != nil }
            return box.value
        }

        final class Box<T: Sendable>: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: T?
            var value: T? {
                lock.withLock { stored }
            }

            func set(_ value: T) {
                lock.withLock { stored = value }
            }
        }

        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var value: Date
            init(_ value: Date) {
                self.value = value
            }

            var now: Date {
                get { lock.withLock { value } }
                set { lock.withLock { value = newValue } }
            }

            func advance(by seconds: TimeInterval) {
                lock.withLock { value = value.addingTimeInterval(seconds) }
            }
        }

        /// A HealthKit read whose first `hangCount` calls do not answer until
        /// `release()`, whatever happens to the awaiting task: the shape of a
        /// statistics callback that never fires.
        final class Reader: HealthKitHRBucketReading, @unchecked Sendable {
            private let lock = NSLock()
            private var rows: [HealthKitHRBucketRow]
            private var hangCount: Int
            private var waiters: [CheckedContinuation<Void, Never>] = []
            private var _queries = 0
            private var _cancelledWhileHanging = 0

            init(rows: [HealthKitHRBucketRow], hangCount: Int = 0) {
                self.rows = rows
                self.hangCount = hangCount
            }

            var queries: Int {
                lock.withLock { _queries }
            }

            var cancelledWhileHanging: Int {
                lock.withLock { _cancelledWhileHanging }
            }

            func replaceRows(_ newRows: [HealthKitHRBucketRow]) {
                lock.withLock { rows = newRows }
            }

            func release() {
                let pending = lock.withLock {
                    let pending = waiters
                    waiters = []
                    return pending
                }
                pending.forEach { $0.resume() }
            }

            func bucketRows(from: Date, to: Date) async throws -> [HealthKitHRBucketRow] {
                let hangs = lock.withLock {
                    _queries += 1
                    guard hangCount > 0 else { return false }
                    hangCount -= 1
                    return true
                }
                if hangs {
                    await withTaskCancellationHandler {
                        await withCheckedContinuation { continuation in
                            lock.withLock { waiters.append(continuation) }
                        }
                    } onCancel: {
                        lock.withLock { _cancelledWhileHanging += 1 }
                    }
                }
                return lock.withLock { rows.filter { $0.bucketStartUTC >= from && $0.bucketStartUTC < to } }
            }
        }

        /// A health store that takes every query and never answers it.
        final class SilentStore: HealthKitQueryExecuting, @unchecked Sendable {
            private let lock = NSLock()
            private var _executed: [HKQuery] = []
            private var _stopped: [HKQuery] = []

            var executed: Int {
                lock.withLock { _executed.count }
            }

            var stopped: Int {
                lock.withLock { _stopped.count }
            }

            var stoppedTheExecutedQuery: Bool {
                lock.withLock { !_stopped.isEmpty && _stopped.allSatisfy { stop in _executed.contains { $0 === stop } } }
            }

            func execute(_ query: HKQuery) {
                lock.withLock { _executed.append(query) }
            }

            func stop(_ query: HKQuery) {
                lock.withLock { _stopped.append(query) }
            }
        }

        final class ServerAPI: APIClientProtocol, @unchecked Sendable {
            private let lock = NSLock()
            private var _posted: [[HealthKitBatchEntryDTO]] = []
            private var _failure: Error?

            var posted: [[HealthKitBatchEntryDTO]] {
                lock.withLock { _posted }
            }

            var postedIds: [String] {
                posted.flatMap { $0.map(\.externalId) }
            }

            var failure: Error? {
                get { lock.withLock { _failure } }
                set { lock.withLock { _failure = newValue } }
            }

            func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
                guard let body = request.body else { throw HLError.unknown("test stub: no body") }
                if let failure { throw failure }
                let payload = try BatchUploadOutcomeTests.batchDecoder().decode(HealthKitBatchPayload.self, from: body)
                lock.withLock { _posted.append(payload.entries) }
                let response = HealthKitBatchResponseDTO(
                    processed: payload.entries.count,
                    inserted: payload.entries.count,
                    duplicates: 0,
                    skipped: [],
                    entries: payload.entries.indices.map { .init(index: $0, status: .inserted) }
                )
                guard let typed = response as? T else { throw HLError.unknown("test stub: T mismatch") }
                return typed
            }

            func sendVoid(_: APIRequest<EmptyPayload>) async throws {}
            func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
                throw HLError.unknown("test stub: download not implemented")
            }
        }

        struct Flags: FeatureFlagsServicing {
            func isEnabled(_ flag: FeatureFlag) -> Bool {
                flag == .enableHRBuckets ? true : flag.defaultValue
            }
        }

        struct Harness {
            let suite: String
            let clock: Clock
            let api: ServerAPI
            let coordinator: HealthKitHRBucketSyncCoordinator

            var defaults: UserDefaults {
                // swiftlint:disable:next force_unwrapping
                UserDefaults(suiteName: suite)!
            }

            var ledger: HRBucketSyncLedger {
                HRBucketSyncLedgerStore.load(userId: HRBucketSweepTestSupport.user, defaults: defaults)
            }

            func rawGateDrops(_ date: Date) -> Bool {
                HRBucketRawGate.shouldDrop(sampleDate: date, userId: HRBucketSweepTestSupport.user, now: clock.now, defaults: defaults)
            }
        }

        /// A coordinator with an armed cutover, a token and the bucket flag
        /// on, reading from `service`.
        static func harness(
            service: any HealthKitHRBucketReading,
            cutover: Date,
            now: Date,
            staleAfter: TimeInterval = HealthKitHRBucketSyncCoordinator.defaultStaleAfter
        ) -> Harness {
            let suite = "test.hrbucket.synchr.\(UUID().uuidString)"
            // swiftlint:disable:next force_unwrapping
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            defaults.set(cutover, forKey: HRBucketCutoverStore.key(for: user))
            let keychain = InMemoryKeychain()
            try? keychain.setString("token", forKey: KeychainKey.authToken)
            try? keychain.setString(user, forKey: KeychainKey.userID)
            let clock = Clock(now)
            let api = ServerAPI()
            let coordinator = HealthKitHRBucketSyncCoordinator(
                service: service,
                uploader: MeasurementBatchUploader(api: api, throttle: BatchSyncThrottle()),
                featureFlags: Flags(),
                keychain: keychain,
                isStandalone: { false },
                clock: { clock.now },
                // swiftlint:disable:next force_unwrapping
                defaultsProvider: { UserDefaults(suiteName: suite)! },
                staleAfter: staleAfter
            )
            return Harness(suite: suite, clock: clock, api: api, coordinator: coordinator)
        }
    }
#endif
