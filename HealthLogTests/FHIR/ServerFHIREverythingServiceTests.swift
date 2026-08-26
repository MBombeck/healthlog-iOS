import Foundation
@testable import HealthLog
import ModelsR4
import Testing

// swiftlint:disable force_unwrapping

/// **v0.14.2 FW5-C — server FHIR `$everything` fetcher + source selection (B3).**
///
/// Pins, against the *real* `APIClient` + stubbed `URLSession`:
///   - the `searchset` Bundle decode (`total` + `entry[]`),
///   - the `next`-link follow (page 1 → page 2, accumulating entries; stop when
///     `next` is absent),
///   - the `next`-page query extraction from a Bundle's `next` link,
///   - the paired-prefers-server / offline-falls-back-to-local selection rule.
///
/// **CU-13 (server v1.34.2)** adds: the request goes to the type-level
/// `/api/fhir/Patient/$everything` (the bare `/api/fhir/$everything` 404s), and
/// a zero-entry Bundle is reported as such instead of passing for an export.
@Suite("ServerFHIREverythingService", .serialized)
struct ServerFHIREverythingServiceTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    // MARK: - Source selection (pure rule)

    @Test("preferred() prefers server when reachable, local otherwise")
    func selectionRule() {
        #expect(FHIRExportSource.preferred(isBackendReachable: true) == .server)
        #expect(FHIRExportSource.preferred(isBackendReachable: false) == .local)
    }

    // MARK: - next-page query extraction

    @Test("nextPageQuery extracts _count/_offset from a next link, nil when absent")
    func nextQueryExtraction() throws {
        // Bundle with a next link.
        let withNext = ModelsR4.Bundle(type: BundleType.searchset.asPrimitive())
        let nextLink = try BundleLink(
            relation: FHIRString("next").asPrimitive(),
            url: FHIRPrimitive(FHIRURI(#require(URL(string: "https://x/api/fhir/$everything?_count=200&_offset=200"))))
        )
        let selfLink = try BundleLink(
            relation: FHIRString("self").asPrimitive(),
            url: FHIRPrimitive(FHIRURI(#require(URL(string: "https://x/api/fhir/$everything?_count=200&_offset=0"))))
        )
        withNext.link = [selfLink, nextLink]
        let q = ServerFHIREverythingService.nextPageQuery(from: withNext)
        let dict = try Dictionary(uniqueKeysWithValues: #require(q?.map { ($0.0, $0.1) }))
        #expect(dict["_offset"] == "200")
        #expect(dict["_count"] == "200")

        // Bundle without a next link → nil (terminal page).
        let last = ModelsR4.Bundle(type: BundleType.searchset.asPrimitive())
        last.link = [selfLink]
        #expect(ServerFHIREverythingService.nextPageQuery(from: last) == nil)

        // No links at all → nil.
        let bare = ModelsR4.Bundle(type: BundleType.searchset.asPrimitive())
        #expect(ServerFHIREverythingService.nextPageQuery(from: bare) == nil)
    }

    // MARK: - searchset decode + next follow

    @Test("fetchEverything follows next, accumulates entries, carries total")
    func followsNextAndAccumulates() async throws {
        let api = makeAPI()
        // Two pages: page1 has a next link → page2 (offset 1) has no next.
        nonisolated(unsafe) var requestCount = 0
        nonisolated(unsafe) var capturedAccept: String?
        MockURLProtocol.handler = { req in
            // CU-07: the handler is process-global — only the FHIR route counts.
            if req.targets("/api/fhir/Patient/$everything") {
                capturedAccept = req.value(forHTTPHeaderField: "Accept")
                requestCount += 1
            }
            let offset = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "_offset" })?.value ?? "0"
            let body = if offset == "0" {
                // Page 1 — one observation + a next link to offset 1.
                """
                {"resourceType":"Bundle","type":"searchset","total":2,\
                "link":[\
                {"relation":"self","url":"https://x/api/fhir/$everything?_count=1&_offset=0"},\
                {"relation":"next","url":"https://x/api/fhir/$everything?_count=1&_offset=1"}],\
                "entry":[{"resource":{"resourceType":"Observation","status":"final",\
                "code":{"text":"Weight"}}}]}
                """
            } else {
                // Page 2 — one more observation, no next link (terminal).
                """
                {"resourceType":"Bundle","type":"searchset","total":2,\
                "link":[{"relation":"self","url":"https://x/api/fhir/$everything?_count=1&_offset=1"}],\
                "entry":[{"resource":{"resourceType":"Observation","status":"final",\
                "code":{"text":"Steps"}}}]}
                """
            }
            let http = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/fhir+json"]
            )!
            return (http, Data(body.utf8))
        }

        let service = ServerFHIREverythingService(api: api)
        // The actor encodes the combined Bundle to Sendable bytes; decode them
        // back here (nonisolated) to assert on the combined envelope.
        let fetched = try await service.fetchEverything()
        let bundle = try JSONDecoder().decode(ModelsR4.Bundle.self, from: fetched.json)

        #expect(capturedAccept == "application/fhir+json")
        #expect(requestCount == 2) // page1 + page2 (then next absent → stop)
        #expect(bundle.type.value == .searchset)
        #expect(bundle.total?.value?.integer == 2)
        #expect(bundle.entry?.count == 2)
        #expect(fetched.entryCount == 2)
        #expect(!fetched.isEmpty)
    }

    // MARK: - CU-13 — the route moved to the Patient type

    @Test("every page is requested from /api/fhir/Patient/$everything")
    func requestsTypeLevelPatientRoute() async throws {
        let api = makeAPI()
        nonisolated(unsafe) var paths: [String] = []
        MockURLProtocol.handler = { req in
            // CU-07: scoped to the FHIR namespace, NOT to the new route — the
            // assertions below must still be able to see a hit on the deleted
            // `/api/fhir/$everything` path if the follower ever regressed there.
            if req.targets(prefixedBy: "/api/fhir") {
                paths.append(req.url?.path ?? "")
            }
            // Page 1 carries a next link so the follower runs too — the second
            // request must land on the same new route, not the deleted one.
            let offset = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "_offset" })?.value ?? "0"
            let body = if offset == "0" {
                """
                {"resourceType":"Bundle","type":"searchset","total":2,\
                "link":[{"relation":"next",\
                "url":"https://x/api/fhir/Patient/$everything?_count=1&_offset=1"}],\
                "entry":[{"resource":{"resourceType":"Patient"}}]}
                """
            } else {
                """
                {"resourceType":"Bundle","type":"searchset","total":2,\
                "entry":[{"resource":{"resourceType":"Observation","status":"final",\
                "code":{"text":"Weight"}}}]}
                """
            }
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(body.utf8))
        }

        let fetched = try await ServerFHIREverythingService(api: api).fetchEverything()

        #expect(paths.count == 2)
        #expect(paths.allSatisfy { $0 == "/api/fhir/Patient/$everything" })
        // The deleted route must not be hit by any page, follower included.
        #expect(paths.contains("/api/fhir/$everything") == false)
        #expect(fetched.entryCount == 2)
    }

    @Test("a zero-entry bundle reports itself empty (scoped to the saved selection)")
    func emptyBundleIsReportedEmpty() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            // Server v1.34.2 scopes the bundle to the owner's saved report
            // selection — never saved one → a healthy 200 with no entries.
            let body = #"{"resourceType":"Bundle","type":"searchset","total":0}"#
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(body.utf8))
        }
        let fetched = try await ServerFHIREverythingService(api: api).fetchEverything()
        #expect(fetched.entryCount == 0)
        #expect(fetched.isEmpty)
        #expect(!fetched.json.isEmpty) // still a well-formed searchset envelope
    }

    @Test("fetchEverything stops after a single page when there is no next link")
    func singlePageStops() async throws {
        let api = makeAPI()
        nonisolated(unsafe) var requestCount = 0
        MockURLProtocol.handler = { req in
            if req.targets("/api/fhir/Patient/$everything") { requestCount += 1 }
            let body = """
            {"resourceType":"Bundle","type":"searchset","total":1,\
            "link":[{"relation":"self","url":"https://x/api/fhir/$everything?_count=200&_offset=0"}],\
            "entry":[{"resource":{"resourceType":"Patient"}}]}
            """
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(body.utf8))
        }
        let service = ServerFHIREverythingService(api: api)
        let bundle = try await JSONDecoder().decode(
            ModelsR4.Bundle.self,
            from: service.fetchEverything().json
        )
        #expect(requestCount == 1)
        #expect(bundle.entry?.count == 1)
    }

    @Test("a 429 throttle surfaces as an error (caller falls back to local)")
    func throttleThrows() async {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            // Server B3: 429 is a FHIR OperationOutcome; APIClient maps it to
            // HLError.rateLimited, which propagates so the export falls back local.
            let body = #"{"resourceType":"OperationOutcome","issue":[{"severity":"error","code":"throttled"}]}"#
            let http = HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
            return (http, Data(body.utf8))
        }
        let service = ServerFHIREverythingService(api: api)
        await #expect(throws: (any Error).self) {
            _ = try await service.fetchEverything()
        }
    }
}
