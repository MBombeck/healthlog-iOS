import Foundation
@testable import HealthLog
import Testing

@Suite("Measurement batch authentication lease")
struct MeasurementBatchAuthenticationLeaseTests {
    private final class SessionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var owner: String?
        private var token: String?

        init(owner: String?, token: String?) {
            self.owner = owner
            self.token = token
        }

        func snapshot() -> MeasurementUploadAuthenticationSnapshot {
            lock.withLock {
                MeasurementUploadAuthenticationSnapshot(ownerUserID: owner, bearerToken: token)
            }
        }

        func replace(owner: String?, token: String?) {
            lock.withLock {
                self.owner = owner
                self.token = token
            }
        }
    }

    private final class SwitchingAPI: APIClientProtocol, @unchecked Sendable {
        private let session: SessionBox
        private let lock = NSLock()
        private var headers: [String?] = []

        init(session: SessionBox) {
            self.session = session
        }

        var authorizationHeaders: [String?] {
            lock.withLock { headers }
        }

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            lock.withLock { headers.append(request.extraHeaders["Authorization"]) }
            session.replace(owner: "B", token: "token-b")
            let response = HealthKitBatchResponseDTO(
                processed: 1,
                inserted: 1,
                duplicates: 0,
                skipped: [],
                entries: [.init(index: 0, status: .inserted)]
            )
            guard let typed = response as? T else { throw HLError.unknown("type mismatch") }
            return typed
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.unknown("not implemented")
        }
    }

    private final class RecordingAPI: APIClientProtocol, @unchecked Sendable {
        struct RequestSnapshot: Equatable {
            let authorization: String?
            let maxRetries: Int
            let allowsAuthenticationRecovery: Bool
        }

        private let lock = NSLock()
        private var requests: [RequestSnapshot] = []

        var requestSnapshots: [RequestSnapshot] {
            lock.withLock { requests }
        }

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            lock.withLock {
                requests.append(RequestSnapshot(
                    authorization: request.extraHeaders["Authorization"],
                    maxRetries: request.maxRetries,
                    allowsAuthenticationRecovery: request.allowsAuthenticationRecovery
                ))
            }
            let response = HealthKitBatchResponseDTO(
                processed: 1,
                inserted: 1,
                duplicates: 0,
                skipped: [],
                entries: [.init(index: 0, status: .inserted)]
            )
            guard let typed = response as? T else { throw HLError.unknown("type mismatch") }
            return typed
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.unknown("not implemented")
        }
    }

    private static func entry() -> HealthKitBatchEntryDTO {
        .init(
            hkIdentifier: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
            value: 42,
            unit: "ms",
            startDate: Date(timeIntervalSince1970: 1_715_673_600),
            endDate: Date(timeIntervalSince1970: 1_715_673_660),
            externalId: "lease-test"
        )
    }

    @Test("captured A bearer is pinned and A-to-B during wire cannot consume")
    func accountSwitchDuringWireFailsClosed() async throws {
        let session = SessionBox(owner: "A", token: "token-a")
        let api = SwitchingAPI(session: session)
        let uploader = MeasurementBatchUploader(
            api: api,
            throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60, jitter: 0 ... 0),
            authenticationSnapshot: { session.snapshot() }
        )
        let lease = try await uploader.captureAuthenticationLease()

        await #expect(throws: MeasurementUploadAuthenticationLease.ValidationError.self) {
            _ = try await uploader.upload([Self.entry()], requiring: lease)
        }
        #expect(api.authorizationHeaders == ["Bearer token-a"])
    }

    @Test("missing owner or bearer blocks before wire")
    func unavailableAuthenticationMeansNoWire() async {
        let session = SessionBox(owner: "A", token: nil)
        let api = RecordingAPI()
        let uploader = MeasurementBatchUploader(
            api: api,
            throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60, jitter: 0 ... 0),
            authenticationSnapshot: { session.snapshot() }
        )

        await #expect(throws: MeasurementUploadAuthenticationLease.ValidationError.self) {
            _ = try await uploader.upload([Self.entry()])
        }
        #expect(api.requestSnapshots.isEmpty)
    }

    @Test("owner or token replacement after capture blocks before wire")
    func staleAuthenticationMeansNoWire() async throws {
        let session = SessionBox(owner: "A", token: "token-a")
        let api = RecordingAPI()
        let uploader = MeasurementBatchUploader(
            api: api,
            throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60, jitter: 0 ... 0),
            authenticationSnapshot: { session.snapshot() }
        )
        let lease = try await uploader.captureAuthenticationLease()
        session.replace(owner: "A", token: "token-a-rotated")

        await #expect(throws: MeasurementUploadAuthenticationLease.ValidationError.self) {
            _ = try await uploader.upload([Self.entry()], requiring: lease)
        }
        #expect(api.requestSnapshots.isEmpty)
    }

    @Test("leased request pins bearer and disables retry plus global auth recovery")
    func leasedRequestPolicyIsFailClosed() async throws {
        let session = SessionBox(owner: "A", token: "token-a")
        let api = RecordingAPI()
        let uploader = MeasurementBatchUploader(
            api: api,
            throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60, jitter: 0 ... 0),
            authenticationSnapshot: { session.snapshot() }
        )

        let outcomes = try await uploader.upload([Self.entry()])

        #expect(outcomes.count == 1)
        #expect(api.requestSnapshots == [
            .init(
                authorization: "Bearer token-a",
                maxRetries: 0,
                allowsAuthenticationRecovery: false
            )
        ])
    }
}
