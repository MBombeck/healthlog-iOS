import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Records every request `MockURLProtocol` sees, in order. The suites under
/// test each issue their request under test FIRST, so ``captured`` is that one.
/// `@unchecked Sendable` with a lock because the handler is `@Sendable` and runs
/// off the main actor.
final class WireRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [SharingWire.Capture] = []

    func record(_ request: URLRequest) {
        let capture = SharingWire.capture(request)
        lock.lock()
        defer { lock.unlock() }
        requests.append(capture)
    }

    /// The first request the code under test issued.
    var captured: SharingWire.Capture? {
        lock.lock()
        defer { lock.unlock() }
        return requests.first
    }

    var all: [SharingWire.Capture] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

/// Shared machinery for the Phase-18 wire fixtures: capture, canonicalisation,
/// fixture I/O, and the stubbed responses each call site needs to complete.
enum SharingWire {
    /// One request as the wire would carry it. Deliberately narrow: method,
    /// path, query, the `Accept` header and the canonical body. Those are the
    /// four things a consolidation could plausibly change, and nothing here
    /// records a header the client sets uniformly for every call (the bearer,
    /// the user agent), because pinning those would make the fixtures fail for
    /// reasons that have nothing to do with sharing.
    struct Capture: Codable, Equatable {
        let method: String
        let path: String
        let query: String?
        let accept: String?
        /// Canonical JSON (sorted keys, no whitespace), or `nil` for a bodyless
        /// request.
        let body: String?
    }

    // MARK: - Capture

    static func capture(_ request: URLRequest) -> Capture {
        let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        return Capture(
            method: request.httpMethod ?? "",
            path: components?.path ?? "",
            query: components?.percentEncodedQuery,
            accept: request.value(forHTTPHeaderField: "Accept"),
            body: canonical(bodyBytes(of: request))
        )
    }

    /// URLProtocol moves `httpBody` onto `httpBodyStream`; re-materialize either.
    static func bodyBytes(of request: URLRequest) -> Data? {
        if let body = request.httpBody, !body.isEmpty { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 8192
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }

    /// Key-sorted, whitespace-free JSON so two encoders that agree on content
    /// agree on bytes. A body that is not JSON is returned as its UTF-8 text.
    static func canonical(_ data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let sorted = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ) else
        {
            return String(data: data, encoding: .utf8)
        }
        return String(data: sorted, encoding: .utf8)
    }

    // MARK: - Fixture I/O

    static func fixtureURL(_ name: String, file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent() // Contracts
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("HealthLogTests/Fixtures/Sharing/\(name).json")
    }

    static func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let url = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func loadFixture(_ name: String) throws -> Capture {
        let data = try Data(contentsOf: fixtureURL(name))
        return try JSONDecoder().decode(Capture.self, from: data)
    }

    /// Compare a capture against its committed fixture.
    ///
    /// When the fixture does not exist yet, the capture is printed in the exact
    /// shape the fixture file takes and the case fails — that is the capture
    /// step of the protocol, run once against the untouched call sites before
    /// anything is rewired.
    static func assertMatchesFixture(
        _ captured: Capture?,
        named name: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let capture = try #require(captured, "no request reached the wire", sourceLocation: sourceLocation)
        guard let expected = try? loadFixture(name) else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let rendered = try String(data: encoder.encode(capture), encoding: .utf8) ?? "<unencodable>"
            Issue.record(
                """
                SHARING_FIXTURE_MISSING \(name)
                SHARING_FIXTURE_BEGIN \(name)
                \(rendered)
                SHARING_FIXTURE_END \(name)
                """,
                sourceLocation: sourceLocation
            )
            return
        }
        #expect(capture == expected, "\(name): wire drifted from the fixture", sourceLocation: sourceLocation)
    }

    // MARK: - Fixtures for the stubbed side

    static func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    @MainActor
    static func makeExportStore(api: APIClient) throws -> ExportStore {
        try ExportStore(
            api: api,
            outbox: OutboxQueue(inMemory: true),
            moduleGate: ModuleGate(
                repo: ModuleGateRepository(api: api),
                modules: ["labs": false, "illness": false]
            ),
            persistence: ExportPersistence()
        )
    }

    static func jsonOK(
        _ request: URLRequest,
        _ json: String,
        contentType: String = "application/json"
    ) -> (HTTPURLResponse, Data?) {
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType]
        )!
        return (http, Data(json.utf8))
    }

    static func binaryOK(
        _ request: URLRequest,
        contentType: String,
        bytes: Data
    ) -> (HTTPURLResponse, Data?) {
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType]
        )!
        return (http, bytes)
    }

    /// A create response the real `ShareLinkDTO` decoder accepts.
    static let shareLinkResponseJSON = """
    {"data":{"id":"sl_test","label":"Dr. Test",
      "rangeStart":"2023-08-16T22:13:20Z","rangeEnd":null,
      "resourceTypes":[],"allowFhirApi":false,
      "expiresAt":"2023-12-14T22:13:20Z","createdAt":"2023-11-14T22:13:20Z",
      "revokedAt":null,"lastAccessAt":null,"accessCount":0,"active":true,
      "protected":true,"token":"hls_test","passphrase":"AAAA-BBBB-CCCC-DDDD",
      "shareUrl":"https://test.healthlog.local/c/hls_test",
      "qrUrl":"https://test.healthlog.local/c/hls_test#k=AAAA-BBBB-CCCC-DDDD",
      "needsReselection":false,"documentOnly":false},"error":null}
    """

    /// The list response `ShareLinkStore.create` refreshes with afterwards.
    static let shareLinkListJSON = #"{"data":{"shareLinks":[]},"error":null}"#

    /// Capabilities payload carrying the fixed test vocabulary.
    static func capabilitiesJSON(leaves: [String]) -> String {
        let leafList = leaves.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"apiContractVersion":"1.34.2",
         "share":{"supported":true,"maxDays":90,"reportDownload":["fhir","pdf"],
                  "selectionVersion":2,
                  "groups":["vitals","labs","medications","sensitive"],
                  "leaves":[\(leafList)]}}
        """
    }

    static func profileJSON(
        leaves: [String],
        format: String = "pdf",
        rangeDays: Int = 90,
        includeCharts: Bool = true
    ) -> String {
        let leafList = leaves.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"profile":{"v":2,"leaves":[\(leafList)],"format":"\(format)",
                    "rangeDays":\(rangeDays),"includeCharts":\(includeCharts)}}
        """
    }
}
