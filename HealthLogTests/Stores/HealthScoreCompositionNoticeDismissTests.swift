import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **#115 B6 — the composition note can be put away.**
///
/// The server raises `healthScore.compositionNotice` when a pillar joins or
/// leaves the score and takes its dismissal on `POST /api/daily/digest/dismiss`
/// with the notice's `itemKey` (`health-score:` is a dismissible notice prefix
/// at v1.39.0, `src/lib/daily/priority-item.ts`). The app decoded the notice
/// and had no path to dismiss it, so the note stayed until the set moved again.
@MainActor
@Suite("#115 B6 — Health Score composition notice dismissal")
struct HealthScoreCompositionNoticeDismissTests {
    /// `healthScoreCompositionItemKey` shape at v1.39.0.
    private nonisolated static let itemKey = "health-score:v2:composition:3f1c0a9b7e21"

    private nonisolated static let snapshot = """
    {"data":{"briefingState":"ready","healthScore":{"score":82,"band":"green","delta":null,\
    "deltaReason":"first_eligibility_window","composition":["BLOOD_PRESSURE"],\
    "scoreBasis":{"domains":1,"recommended":3,"tier":"minimal","physiological":true},\
    "compositionNotice":{"itemKey":"\(itemKey)","left":["SLEEP"],"joined":[],"dismissed":false}}},"error":null}
    """

    private final class Ledger: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(String, Data?)] = []

        func record(_ request: URLRequest) {
            lock.lock()
            defer { lock.unlock() }
            entries.append(("\(request.httpMethod ?? "GET") \(request.url?.path ?? "")", Self.body(request)))
        }

        var requests: [String] {
            lock.lock()
            defer { lock.unlock() }
            return entries.map(\.0)
        }

        var lastBody: [String: Any]? {
            lock.lock()
            defer { lock.unlock() }
            return entries.last?.1.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        }

        private static func body(_ request: URLRequest) -> Data? {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
    }

    private func makeStore(_ session: MockURLProtocolSession, ledger: Ledger, dismissStatus: Int) -> HealthScoreStore {
        session.install { request in
            ledger.record(request)
            let (status, body): (Int, String) = switch request.url?.path ?? "" {
            case "/api/dashboard/snapshot": (200, Self.snapshot)
            case "/api/daily/digest/dismiss" where dismissStatus == 200: (200, #"{"data":{"dismissed":true},"error":null}"#)
            case "/api/daily/digest/dismiss": (dismissStatus, #"{"data":null,"error":"Server error"}"#)
            default: (404, #"{"data":null,"error":"Not found"}"#)
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }
        let env = AppEnvironment(baseURL: session.baseURL, bundleID: "dev.healthlog.app", appVersion: "1.1.0", buildNumber: "1")
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: session.configuration)
        return HealthScoreStore(repo: AnalyticsRepository(api: api))
    }

    @Test("dismissing posts the notice's itemKey and puts the note away")
    func dismissPostsItemKeyAndHidesNote() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let ledger = Ledger()
        let store = makeStore(session, ledger: ledger, dismissStatus: 200)
        await store.load()
        let before = try #require(store.score?.compositionNotice)
        #expect(before.isShowable)

        let ok = await store.dismissCompositionNotice()

        #expect(ok)
        #expect(ledger.requests.contains("POST /api/daily/digest/dismiss"))
        #expect(ledger.lastBody?["itemKey"] as? String == Self.itemKey)
        #expect(ledger.lastBody?.count == 1, "the route's schema is strict: itemKey only")
        let after = try #require(store.score?.compositionNotice)
        #expect(after.dismissed)
        #expect(HealthScorePresentation.noticeLines(after).isEmpty)
        // The score itself is untouched.
        #expect(store.score?.score == 82)
    }

    @Test("a refused dismissal leaves the note on screen")
    func failedDismissKeepsNote() async {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let ledger = Ledger()
        let store = makeStore(session, ledger: ledger, dismissStatus: 422)
        await store.load()

        let ok = await store.dismissCompositionNotice()

        #expect(ok == false)
        #expect(store.score?.compositionNotice?.isShowable == true)
    }
}
