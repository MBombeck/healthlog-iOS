import Foundation
@testable import HealthLog

// swiftlint:disable force_unwrapping

/// Fixtures for the S2 progress suites (``EcgSyncSweepProgressTests`` and
/// ``EcgSyncProgressLossTests``): a test-owned clock, a server-shaped ECG
/// limiter on that clock, and a recording sleeper. No HealthKit, no real
/// sample — the coordinator runs over the real ``APIClient`` +
/// `MockURLProtocol`, as in every ECG suite.
enum EcgSyncProgressFixtures {
    static let base = Date(timeIntervalSince1970: 1_783_000_000)

    /// `count` recordings in HealthKit insertion order, oldest first, one day
    /// apart — the shape a long-held anchor hands back.
    static func history(_ count: Int, prefix: String = "ecg") -> [EcgSourceRecording] {
        (0 ..< count).map { index in
            EcgSourceRecording(
                id: "\(prefix)-\(String(format: "%03d", index))",
                recordedAt: base.addingTimeInterval(Double(index) * 86400),
                samplingFrequency: 512,
                averageHeartRate: 62,
                classification: .notDetected,
                lead: "I",
                sampleCount: 3
            )
        }
    }

    static func volts(for recordings: [EcgSourceRecording]) -> [String: [Double]] {
        Dictionary(uniqueKeysWithValues: recordings.map { ($0.id, [0.000012]) })
    }

    static func ok(_ req: URLRequest, status: String) -> (HTTPURLResponse, Data?) {
        EcgSyncTestSupport.okResponse(status, code: status == "inserted" ? 201 : 200)(req)
    }

    static func serverError(_ req: URLRequest) -> (HTTPURLResponse, Data?) {
        (
            HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
            Data(#"{"data":null,"error":"temporary"}"#.utf8)
        )
    }

    /// A v1.39.8 limiter refusal: prose envelope without a code, the four
    /// headers `attachRateLimitHeaders` adds.
    static func rateLimited(_ req: URLRequest, retryAfter: Int, limit: Int) -> (HTTPURLResponse, Data?) {
        (
            HTTPURLResponse(
                url: req.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: [
                    "Retry-After": "\(retryAfter)",
                    "X-RateLimit-Limit": "\(limit)",
                    "X-RateLimit-Remaining": "0"
                ]
            )!,
            Data(#"{"data":null,"error":"Too many ECG submissions, try again later"}"#.utf8)
        )
    }
}

/// The test's wall clock. The sleeper advances it, so a pause "takes" exactly
/// the seconds the coordinator asked for.
final class EcgTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = EcgSyncProgressFixtures.base

    var now: Date {
        lock.withLock { current }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

/// Records every pause the coordinator asked for.
final class EcgPauseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _sleeps: [TimeInterval] = []

    var sleeps: [TimeInterval] {
        lock.withLock { _sleeps }
    }

    func record(_ seconds: TimeInterval) {
        lock.withLock { _sleeps.append(seconds) }
    }
}

/// `POST /api/insights/ecg` with the server's per-account bucket: a fixed
/// window of `limit` posts per `window` seconds on the test clock. Every post
/// counts, a refused one included. A recording id the server already holds
/// answers `updated`, a new one `inserted` — the outcomes of #115's log.
final class EcgIngestLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private let window: TimeInterval
    private let clock: EcgTestClock
    private let recorder = EcgRequestRecorder()
    private var windowStart: Date?
    private var inWindow = 0
    private var _posts: [String] = []
    private var _outcomes: [String: [String]] = [:]
    private var _refused = 0
    private var _storedOrder: [String] = []

    init(limit: Int, window: TimeInterval = 60, clock: EcgTestClock) {
        self.limit = limit
        self.window = window
        self.clock = clock
    }

    /// Every post, refused ones included, in wire order.
    var posts: [String] {
        lock.withLock { _posts }
    }

    var refused: Int {
        lock.withLock { _refused }
    }

    /// Stored outcomes per recording id (`inserted` / `updated`).
    var outcomes: [String: [String]] {
        lock.withLock { _outcomes }
    }

    /// Ids in the order the server first stored them.
    var storedOrder: [String] {
        lock.withLock { _storedOrder }
    }

    func handle(_ req: URLRequest) -> (HTTPURLResponse, Data?) {
        recorder.record(req)
        let id = recorder.lastJSON()?["externalRecordingId"] as? String ?? "?"
        let now = clock.now
        let decision: (status: String?, retryAfter: Int) = lock.withLock {
            _posts.append(id)
            if let start = windowStart, now.timeIntervalSince(start) < window {
                inWindow += 1
            } else {
                windowStart = now
                inWindow = 1
            }
            guard inWindow <= limit else {
                _refused += 1
                let reset = windowStart!.addingTimeInterval(window)
                return (nil, max(1, Int(reset.timeIntervalSince(now).rounded(.up))))
            }
            let status = _outcomes[id] == nil ? "inserted" : "updated"
            if status == "inserted" { _storedOrder.append(id) }
            _outcomes[id, default: []].append(status)
            return (status, 0)
        }
        guard let status = decision.status else {
            return EcgSyncProgressFixtures.rateLimited(req, retryAfter: decision.retryAfter, limit: limit)
        }
        return EcgSyncProgressFixtures.ok(req, status: status)
    }
}

/// A thread-safe call counter for the source's `beforeVoltages` hook.
final class EcgCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

// swiftlint:enable force_unwrapping
