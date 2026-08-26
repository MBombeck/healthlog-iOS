import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping force_try

#if canImport(HealthKit)

    /// End-to-end Integration: HK-STATS round-trip von DailyStatRow durch
    /// die Cache-`plan(for:)`-Logik in den Sync-Coordinator + APIClient mit
    /// MockURLProtocol gegen die echte Server-Wire-Konvention. Validiert,
    /// dass die externalId-Locked-Konstruktion am Server ankommt + dass der
    /// Cache-State nach jedem Action-Arm korrekt fortgeschrieben wird.
    @Suite("HK-STATS round-trip — HK→externalId UPSERT→cache update", .serialized)
    struct HealthKitStatisticsRoundTripTests {
        // MARK: - Helpers

        private func makeAPI() -> APIClient {
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        }

        static let owner = "account-a"

        /// One round-trip fixture. Phase 07 / Plan 07-04: the coordinator has no
        /// way to name an owner other than an admission, so the round-trip has
        /// to carry one.
        private struct Harness {
            let coordinator: HealthKitStatisticsSyncCoordinator
            let cache: HealthKitDailyStatsCache
            let lease: HealthSyncAuthenticatedLease
            /// Retained on purpose. `AuthenticatedSessionLease` holds the
            /// registry weakly, so a registry that goes out of scope turns every
            /// admission stale — which is correct behaviour and a confusing test
            /// failure.
            let registry: AuthenticatedSessionLeaseRegistry
        }

        /// The uploader carries the *credential* half of the admission (owner +
        /// exact bearer generation, pinned onto the request); the coordinator's
        /// `HealthSyncAuthenticatedLease` carries the *identity* half (which
        /// account's cache partition may be written). Both halves are configured
        /// here so the round-trip exercises the production pairing.
        static func makeUploader(api: APIClientProtocol) -> MeasurementBatchUploader {
            MeasurementBatchUploader(
                api: api,
                throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0),
                authenticationSnapshot: {
                    MeasurementUploadAuthenticationSnapshot(ownerUserID: owner, bearerToken: "bearer-a")
                }
            )
        }

        private func makeCoordinator(api: APIClientProtocol) throws -> Harness {
            let container = try HealthKitDailyStatsCache.makeInMemory()
            let cache = HealthKitDailyStatsCache(modelContainer: container)
            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.owner)
            let lease = try HealthSyncAuthenticatedLease.admit(
                from: registry,
                ownerID: Self.owner,
                source: .dailyStatistics,
                bearerProvider: { "bearer-a" }
            )
            let coordinator = HealthKitStatisticsSyncCoordinator(
                statisticsService: HealthKitStatisticsService(),
                cache: cache,
                uploader: Self.makeUploader(api: api),
                featureFlags: AlwaysOnFeatureFlags(),
                admission: { lease }
            )
            return Harness(coordinator: coordinator, cache: cache, lease: lease, registry: registry)
        }

        private func sampleRow(value: Double = 8345) -> HealthKitDailyStatRow {
            HealthKitDailyStatRow(
                hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                dayStart: Date(timeIntervalSince1970: 1_716_000_000),
                dayKey: "2026-05-16",
                value: value,
                unit: "steps"
            )
        }

        // MARK: - Round-trip: .post path

        @Test("execute(.post): POSTs /api/measurements/batch with locked externalId and updates cache")
        func postPathSucceeds() async throws {
            let api = makeAPI()
            let harness = try makeCoordinator(api: api)
            let (coordinator, cache, lease) = (harness.coordinator, harness.cache, harness.lease)

            nonisolated(unsafe) var capturedBody: Data?
            nonisolated(unsafe) var capturedPath: String?
            nonisolated(unsafe) var capturedMethod: String?
            MockURLProtocol.handler = { req in
                // CU-07: the handler is process-global — record only OUR route.
                if req.targets("/api/measurements/batch") {
                    capturedPath = req.url?.path
                    capturedMethod = req.httpMethod
                    capturedBody = req.httpBody ?? Self.readHTTPBodyStream(from: req)
                }
                let responseBody = #"""
                {"data":{"processed":1,"inserted":1,"duplicates":0,"skipped":[],"entries":[{"index":0,"status":"inserted"}]},"error":null}
                """#
                let response = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(responseBody.utf8))
            }

            let row = sampleRow(value: 8345)
            try await coordinator.execute(action: .post(row: row), requiring: lease)

            #expect(capturedPath == "/api/measurements/batch")
            #expect(capturedMethod == "POST")
            let body = try #require(capturedBody)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(HealthKitBatchPayload.self, from: body)
            #expect(decoded.entries.count == 1)
            #expect(decoded.entries[0].externalId == "stats:HKQuantityTypeIdentifierStepCount:2026-05-16")
            #expect(decoded.entries[0].hkIdentifier == "HKQuantityTypeIdentifierStepCount")
            #expect(decoded.entries[0].value == 8345)
            #expect(decoded.entries[0].unit == "steps")

            // Cache should reflect the new lastPostedValue, under this account.
            let cached = try #require(await cache.read(
                ownerUserID: Self.owner,
                hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                dayKey: "2026-05-16"
            ))
            #expect(cached.lastPostedValue == 8345)
            #expect(cached.ownerUserID == Self.owner)
        }

        // MARK: - Round-trip: .upsert path — late-Watch-Sync correction

        /// **Restated (Phase 07 / Plan 07-04).** This was
        /// `execute(.patch): PATCH /api/measurements/{id} updates value + cache`.
        /// That arm required a server row id the stats path never obtained —
        /// `postDailyStat` always returned `nil`, so `serverMeasurementId` was
        /// never written and the PATCH was unreachable in production. The
        /// deployed route treats `stats:<type>:<day>` as a mutable upsert, so
        /// the correction is a re-POST of the same stable identity, answered
        /// `updated`. What the old test really pinned — a divergent day total
        /// reaches the server and the cache is written forward — is asserted
        /// here on the route production actually takes.
        @Test("execute(.upsert): re-POSTs the stable stats identity and takes `updated` as terminal")
        func upsertPathSucceeds() async throws {
            let api = makeAPI()
            let harness = try makeCoordinator(api: api)
            let (coordinator, cache, lease) = (harness.coordinator, harness.cache, harness.lease)

            try await cache.write(
                ownerUserID: Self.owner,
                hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                dayKey: "2026-05-16",
                lastPostedValue: 5000
            )

            nonisolated(unsafe) var capturedPath: String?
            nonisolated(unsafe) var capturedMethod: String?
            nonisolated(unsafe) var capturedBody: Data?
            nonisolated(unsafe) var capturedAuthorization: String?
            MockURLProtocol.handler = { req in
                if req.targets("/api/measurements/batch") {
                    capturedPath = req.url?.path
                    capturedMethod = req.httpMethod
                    capturedBody = req.httpBody ?? Self.readHTTPBodyStream(from: req)
                    capturedAuthorization = req.value(forHTTPHeaderField: "Authorization")
                }
                let body = #"""
                {"data":{"processed":1,"inserted":0,"duplicates":0,"skipped":[],"entries":[{"index":0,"status":"updated"}]},"error":null}
                """#
                let response = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(body.utf8))
            }

            let row = sampleRow(value: 8345) // late-Watch-Sync: total grew
            try await coordinator.execute(action: .upsert(row: row), requiring: lease)

            #expect(capturedPath == "/api/measurements/batch")
            #expect(capturedMethod == "POST")
            #expect(capturedAuthorization == "Bearer bearer-a", "the admitted bearer must be pinned onto the request")
            let body = try #require(capturedBody)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(HealthKitBatchPayload.self, from: body)
            #expect(decoded.entries.count == 1)
            #expect(decoded.entries[0].externalId == "stats:HKQuantityTypeIdentifierStepCount:2026-05-16")
            #expect(decoded.entries[0].value == 8345)

            let cached = try #require(await cache.read(
                ownerUserID: Self.owner,
                hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                dayKey: "2026-05-16"
            ))
            #expect(cached.lastPostedValue == 8345)
        }

        @Test("execute(.upsert): a `duplicate` answer is still terminal")
        func upsertAcceptsDuplicate() async throws {
            let api = makeAPI()
            let harness = try makeCoordinator(api: api)
            let (coordinator, cache, lease) = (harness.coordinator, harness.cache, harness.lease)

            MockURLProtocol.handler = { req in
                let body = #"""
                {"data":{"processed":1,"inserted":0,"duplicates":1,"skipped":[],"entries":[{"index":0,"status":"duplicate"}]},"error":null}
                """#
                let response = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(body.utf8))
            }

            let row = sampleRow(value: 8345)
            try await coordinator.execute(action: .upsert(row: row), requiring: lease)

            let cached = try #require(await cache.read(
                ownerUserID: Self.owner,
                hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                dayKey: "2026-05-16"
            ))
            #expect(cached.lastPostedValue == 8345)
        }

        // MARK: - HTTP 200 is not acceptance

        @Test("a `failed` row throws and leaves the previous cache value in place")
        func rejectedRowKeepsThePreviousCacheValue() async throws {
            let api = makeAPI()
            let harness = try makeCoordinator(api: api)
            let (coordinator, cache, lease) = (harness.coordinator, harness.cache, harness.lease)

            try await cache.write(
                ownerUserID: Self.owner,
                hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                dayKey: "2026-05-16",
                lastPostedValue: 5000
            )

            MockURLProtocol.handler = { req in
                let body = #"""
                {"data":{"processed":1,"inserted":0,"duplicates":0,"skipped":[],"entries":[{"index":0,"status":"failed","reason":"persistence_error"}]},"error":null}
                """#
                let response = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(body.utf8))
            }

            let row = sampleRow(value: 8345)
            await #expect(throws: MeasurementBatchAcceptanceError.self) {
                try await coordinator.execute(action: .upsert(row: row), requiring: lease)
            }

            let cached = try #require(await cache.read(
                ownerUserID: Self.owner,
                hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                dayKey: "2026-05-16"
            ))
            #expect(cached.lastPostedValue == 5000, "a rejected row must not advance the cached day total")
        }

        @Test("an empty `entries[]` on HTTP 200 is not acceptance")
        func emptyEntryListIsNotAcceptance() async throws {
            let api = makeAPI()
            let harness = try makeCoordinator(api: api)
            let (coordinator, cache, lease) = (harness.coordinator, harness.cache, harness.lease)

            MockURLProtocol.handler = { req in
                let body = #"""
                {"data":{"processed":1,"inserted":1,"duplicates":0,"skipped":[],"entries":[]},"error":null}
                """#
                let response = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(body.utf8))
            }

            let row = sampleRow(value: 8345)
            await #expect(throws: MeasurementBatchAcceptanceError.self) {
                try await coordinator.execute(action: .post(row: row), requiring: lease)
            }
            #expect(await cache.read(
                ownerUserID: Self.owner,
                hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                dayKey: "2026-05-16"
            ) == nil)
        }

        // MARK: - End-to-end via cache.plan(for:) — late-Watch-Sync correction

        @Test("Full sync via cache.plan: same value emits .skip, no HTTP call fires")
        func planSkipsOnUnchangedValue() async throws {
            let api = makeAPI()
            let harness = try makeCoordinator(api: api)
            let (coordinator, cache, lease) = (harness.coordinator, harness.cache, harness.lease)

            try await cache.write(
                ownerUserID: Self.owner,
                hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                dayKey: "2026-05-16",
                lastPostedValue: 8345
            )

            nonisolated(unsafe) var requestCount = 0
            MockURLProtocol.handler = { req in
                // CU-07: `requestCount == 0` is only meaningful when a parallel
                // suite's request cannot raise it — scope to the measurement
                // route this coordinator uses (.post/.upsert both hit
                // `/api/measurements/batch`).
                if req.targets(prefixedBy: "/api/measurements") { requestCount += 1 }
                let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }

            let row = sampleRow(value: 8345)
            let action = await cache.plan(ownerUserID: Self.owner, for: row)
            try await coordinator.execute(action: action, requiring: lease)

            #expect(requestCount == 0, "No HTTP traffic should fire on .skip")
        }

        // MARK: - URLRequest body-stream helper

        /// URLRequest body for POST/PATCH bodies arrives as an InputStream in some
        /// Foundation paths. Reads it synchronously to a Data buffer for assertions.
        nonisolated static func readHTTPBodyStream(from request: URLRequest) -> Data? {
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
    }

    // MARK: - Stub feature flags (round-trip variant)

    /// Feature-flag stub that always reports ON — round-trip tests want the
    /// daily-stats path active without touching UserDefaults.
    struct AlwaysOnFeatureFlags: FeatureFlagsServicing {
        func isEnabled(_: FeatureFlag) -> Bool {
            true
        }
    }

#endif

// swiftlint:enable force_unwrapping force_try
