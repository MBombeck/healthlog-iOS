#if canImport(HealthKit)
    import Foundation
    @testable import HealthLog
    import Testing

    /// W-HR-BUCKET-UPLOAD / GH #34 — coordinator gating contract.
    ///
    /// The HK statistics query itself is exercised against a real `HKHealthStore`
    /// in integration; here we pin the cheap-first gate order that must
    /// short-circuit BEFORE any HK query / upload fires: standalone, missing
    /// share-auth token, and the feature flag. Each returns 0 with no API
    /// traffic. Plus: a just-armed (future) cutover produces no buckets, and the
    /// incremental cursor key is per-User partitioned.
    @Suite("HealthKitHRBucketSyncCoordinator — gating (standalone / auth / flag / cutover)")
    struct HealthKitHRBucketSyncCoordinatorTests {
        private final class CapturingAPI: APIClientProtocol, @unchecked Sendable {
            private let lock = NSLock()
            private(set) var sendCount = 0

            func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
                lock.withLock { sendCount += 1 }
                throw HLError.unknown("test stub: should not be called when gated")
            }

            func sendVoid(_: APIRequest<EmptyPayload>) async throws {
                lock.withLock { sendCount += 1 }
            }

            func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
                throw HLError.unknown("test stub: download not implemented")
            }
        }

        private struct FlagStub: FeatureFlagsServicing {
            let enabled: Bool
            func isEnabled(_ flag: FeatureFlag) -> Bool {
                switch flag {
                case .enableHRBuckets: enabled
                default: flag.defaultValue
                }
            }
        }

        /// Returns a fresh isolated suite NAME (Sendable) — the coordinator
        /// reconstructs `UserDefaults(suiteName:)` inside its `@Sendable`
        /// provider, so no non-Sendable `UserDefaults` instance crosses the
        /// actor-init isolation boundary.
        private func isolatedSuite() -> String {
            let suite = "test.hrbucket.\(UUID().uuidString)"
            // swiftlint:disable:next force_unwrapping
            UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
            return suite
        }

        private func makeCoordinator(
            api: CapturingAPI,
            flagOn: Bool,
            standalone: Bool,
            token: String?,
            suite: String
        ) -> HealthKitHRBucketSyncCoordinator {
            let keychain = InMemoryKeychain()
            if let token { try? keychain.setString(token, forKey: KeychainKey.authToken) }
            try? keychain.setString("user-xyz", forKey: KeychainKey.userID)
            return HealthKitHRBucketSyncCoordinator(
                service: HealthKitHRBucketService(),
                uploader: MeasurementBatchUploader(api: api, throttle: BatchSyncThrottle()),
                featureFlags: FlagStub(enabled: flagOn),
                keychain: keychain,
                isStandalone: { standalone },
                clock: { ISO8601DateFormatter.fractional.date(from: "2026-06-25T12:00:00.000Z") ?? Date() },
                // swiftlint:disable:next force_unwrapping
                defaultsProvider: { UserDefaults(suiteName: suite)! }
            )
        }

        @Test("standalone → no upload, no API traffic")
        func standaloneSuppressed() async {
            let api = CapturingAPI()
            let coord = makeCoordinator(
                api: api, flagOn: true, standalone: true, token: "tok", suite: isolatedSuite()
            )
            let uploaded = await coord.sync(lookbackHours: 48)
            #expect(uploaded == 0)
            #expect(api.sendCount == 0)
        }

        @Test("missing share-auth token → no upload, no API traffic")
        func noTokenSuppressed() async {
            let api = CapturingAPI()
            let coord = makeCoordinator(
                api: api, flagOn: true, standalone: false, token: nil, suite: isolatedSuite()
            )
            let uploaded = await coord.sync(lookbackHours: 48)
            #expect(uploaded == 0)
            #expect(api.sendCount == 0)
        }

        @Test("feature flag OFF → no upload, no API traffic")
        func flagOffSuppressed() async {
            let api = CapturingAPI()
            let coord = makeCoordinator(
                api: api, flagOn: false, standalone: false, token: "tok", suite: isolatedSuite()
            )
            let uploaded = await coord.sync(lookbackHours: 48)
            #expect(uploaded == 0)
            #expect(api.sendCount == 0)
        }

        @Test("cutover in the future (just armed) → no buckets, no API traffic")
        func cutoverInFutureNoBuckets() async throws {
            // First sync arms the cutover to the NEXT UTC midnight (after the
            // pinned clock 2026-06-25T12:00Z → 2026-06-26T00:00Z). Since the
            // window-end is the current 10-minute bucket (< cutover), no closed
            // bucket is on-or-after the cutover yet → nothing to upload.
            let api = CapturingAPI()
            let suite = isolatedSuite()
            let coord = makeCoordinator(
                api: api, flagOn: true, standalone: false, token: "tok", suite: suite
            )
            let uploaded = await coord.sync(lookbackHours: 48)
            #expect(uploaded == 0)
            #expect(api.sendCount == 0)
            // The cutover WAS armed as a side effect (next UTC midnight).
            // swiftlint:disable:next force_unwrapping
            let defaults = try #require(UserDefaults(suiteName: suite))
            let armed = HRBucketCutoverStore.persistedCutover(userId: "user-xyz", defaults: defaults)
            #expect(armed == ISO8601DateFormatter.fractional.date(from: "2026-06-26T00:00:00.000Z"))
        }

        @Test("last-bucket cursor key is per-User partitioned")
        func lastBucketKeyPartitioned() {
            let k1 = HealthKitHRBucketSyncCoordinator.lastBucketKey(for: "userA")
            let k2 = HealthKitHRBucketSyncCoordinator.lastBucketKey(for: "userB")
            #expect(k1 != k2)
            #expect(k1.hasPrefix(HealthKitHRBucketSyncCoordinator.lastBucketDefaultsKeyPrefix))
        }
    }
#endif
