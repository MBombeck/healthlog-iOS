import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Shared fixtures + test doubles for the two GH #74 upload suites
/// (``EcgSyncCoordinatorTests`` and ``EcgSyncErrorClassTests``), split out per
/// the `file_length` discipline in `PROJECT_GUIDE.md`.
///
/// **No HealthKit, no real health sample.** The ECG path is exercised through
/// the platform-free ``EcgRecordingSource`` seam with synthetic metadata and
/// synthetic voltages, over the REAL ``APIClient`` + `MockURLProtocol`.
enum EcgSyncTestSupport {
    static let recordedAt = Date(timeIntervalSince1970: 1_783_000_000)
    static let defaultRecordingID = "11111111-2222-3333-4444-555555555555"

    static func makeClient(
        token: String? = "bearer-abc",
        refreshHandler: (@Sendable () async -> RefreshOutcome)? = nil
    ) -> (APIClient, InMemoryKeychain) {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        if let token { try? keychain.setString(token, forKey: KeychainKey.authToken) }
        try? keychain.setString("user-123", forKey: KeychainKey.userID)
        return (
            APIClient(
                environment: env,
                keychain: keychain,
                sessionConfiguration: .mock(),
                refreshHandler: refreshHandler
            ),
            keychain
        )
    }

    /// A private `UserDefaults` suite per call, so anchor assertions never see
    /// another test's cursor.
    static func isolatedDefaults() -> @Sendable () -> UserDefaults {
        let suite = "ecg.tests.\(UUID().uuidString)"
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
        return { UserDefaults(suiteName: suite)! }
    }

    /// The per-user anchor key the coordinator writes for the fixture user.
    static let anchorKey = "hl.ecg.hk.anchor.user-123"

    static func makeCoordinator(
        api: APIClient,
        keychain: InMemoryKeychain,
        source: FakeEcgSource,
        optedIn: Bool = true,
        moduleEnabled: Bool = true,
        defaultsProvider: (@Sendable () -> UserDefaults)? = nil,
        anchorPersistenceOverride: (@Sendable (Data, String) -> Bool)? = nil,
        admission: HealthSyncImporterAdmission? = nil
    ) -> EcgSyncCoordinator {
        EcgSyncCoordinator(
            source: source,
            repo: EcgRepository(api: api),
            keychain: keychain,
            isOptedIn: { optedIn },
            isModuleEnabled: { moduleEnabled },
            defaultsProvider: defaultsProvider ?? isolatedDefaults(),
            anchorPersistenceOverride: anchorPersistenceOverride,
            admission: admission
        )
    }

    /// The anchor key the coordinator writes for one account — computed the same
    /// way production does, so a test can never assert against a key production
    /// does not use.
    static func anchorKey(for userID: String) -> String {
        EcgSyncCoordinator.anchorKeyPrefix + HealthKitBackfillWindowStore.partitionToken(for: userID)
    }

    static func recording(
        id: String = defaultRecordingID,
        samples: Int = 3,
        classification: EcgIngestClassification? = .notDetected,
        averageHeartRate: Double? = 62
    ) -> EcgSourceRecording {
        EcgSourceRecording(
            id: id,
            recordedAt: recordedAt,
            samplingFrequency: 512,
            averageHeartRate: averageHeartRate,
            classification: classification,
            lead: "I",
            sampleCount: samples
        )
    }

    /// A canned success answer in the server's envelope shape.
    static func okResponse(
        _ status: String,
        code: Int = 200
    ) -> @Sendable (URLRequest) -> (HTTPURLResponse, Data?) {
        { req in
            let json = #"""
            {"data":{"id":"row-1","status":"\#(status)","recordedAt":"2026-07-01T09:14:00Z",
            "sampleCount":3,"durationSeconds":30},"error":null}
            """#
            return (
                HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!,
                Data(json.utf8)
            )
        }
    }
}

// MARK: - Test doubles

/// Synthetic ``EcgRecordingSource``. No HealthKit, no real sample.
final class FakeEcgSource: EcgRecordingSource, @unchecked Sendable {
    private let lock = NSLock()
    private var recordings: [EcgSourceRecording]
    private let volts: [String: [Double]]
    private let failVoltagesFor: Set<String>
    private let nextAnchor: Data?
    private let timeline: EventTimeline?
    private let beforeVoltages: (@Sendable () async -> Void)?
    private var _fetchCount = 0
    private var _voltageRequests: [String] = []
    private var _lastAnchorSeen: Data?

    init(
        recordings: [EcgSourceRecording],
        volts: [String: [Double]],
        failVoltagesFor: Set<String> = [],
        nextAnchor: Data? = Data("anchor".utf8),
        timeline: EventTimeline? = nil,
        beforeVoltages: (@Sendable () async -> Void)? = nil
    ) {
        self.recordings = recordings
        self.volts = volts
        self.failVoltagesFor = failVoltagesFor
        self.nextAnchor = nextAnchor
        self.timeline = timeline
        self.beforeVoltages = beforeVoltages
    }

    var fetchCount: Int {
        lock.withLock { _fetchCount }
    }

    var voltageRequests: [String] {
        lock.withLock { _voltageRequests }
    }

    var lastAnchorSeen: Data? {
        lock.withLock { _lastAnchorSeen }
    }

    func setRecordings(_ new: [EcgSourceRecording]) {
        lock.withLock { recordings = new }
    }

    func fetchRecordings(since anchor: Data?) async throws -> EcgSourceFetchResult {
        let current: [EcgSourceRecording] = lock.withLock {
            _fetchCount += 1
            _lastAnchorSeen = anchor
            return recordings
        }
        return EcgSourceFetchResult(recordings: current, anchor: nextAnchor)
    }

    func voltages(forRecordingID id: String) async throws -> [Double] {
        lock.withLock { _voltageRequests.append(id) }
        timeline?.append("volts:\(id)")
        await beforeVoltages?()
        if failVoltagesFor.contains(id) { throw URLError(.cannotOpenFile) }
        return volts[id] ?? []
    }
}

/// Deterministic suspension point between ECG metadata and waveform delivery.
/// The test changes the authenticated account while the coordinator is parked,
/// then releases the exact suspension that used to resume into a B-authenticated
/// wire request carrying A's recording.
actor EcgVoltageBarrier {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// Ordered event log shared between the fake source and the URL handler, so a
/// test can assert the *interleaving* (read → send → read → send) rather than
/// only the totals.
final class EventTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []

    var events: [String] {
        lock.withLock { _events }
    }

    func append(_ event: String) {
        lock.withLock { _events.append(event) }
    }
}

/// Records requests seen by `MockURLProtocol`, scoped to the ECG endpoint.
final class EcgRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var bodies: [Data] = []

    func record(_ req: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(req)
        bodies.append(Self.body(req) ?? Data())
    }

    var count: Int {
        lock.withLock { requests.count }
    }

    var isEmpty: Bool {
        lock.withLock { requests.isEmpty }
    }

    var lastPath: String? {
        lock.withLock { requests.last?.url?.path }
    }

    var lastIdempotencyKey: String? {
        lock.withLock { requests.last?.value(forHTTPHeaderField: "Idempotency-Key") }
    }

    var lastAuthorization: String? {
        lock.withLock { requests.last?.value(forHTTPHeaderField: "Authorization") }
    }

    /// The raw JSON object, so the key set can be pinned exactly (the body is
    /// `.strict()` server-side — a typed decode would silently tolerate extras).
    func lastJSON() -> [String: Any]? {
        lock.lock()
        let data = bodies.last
        lock.unlock()
        guard let data, !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func body(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// swiftlint:enable force_unwrapping

// swiftlint:enable force_unwrapping
