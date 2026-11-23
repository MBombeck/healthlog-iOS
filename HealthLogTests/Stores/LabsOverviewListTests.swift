// The labs marker list comes from `GET /api/labs/overview`.
//
// `LabsStore.load()` used to build the "by type" list from one page of
// `GET /api/labs?limit=500`, so on a long history every marker whose readings
// all sat beyond that page vanished from the list. The overview (server
// v1.42.4+) has one entry per marker over the whole history; against an older
// server the list keeps the old grouping.
//
// Drives the REAL store over the REAL `APIClient` on a session-scoped
// `MockURLProtocolSession`, like `LabsPartialFailureTests`. Fixtures follow
// `LabOverviewMarker` in `docs/api/openapi.yaml` on `origin/release/v1.43.0`
// (`b4dc0d592`, document identical to `v1.42.4`).

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @Suite("#130 labs list from the overview", .serialized)
    @MainActor
    struct LabsOverviewListTests {
        private nonisolated static let owner = "owner-labs-overview"

        private func makeStore(_ session: MockURLProtocolSession) throws -> LabsStore {
            let keychain = InMemoryKeychain()
            try? keychain.setString("token", forKey: KeychainKey.authToken)
            let api = APIClient(
                environment: AppEnvironment(
                    baseURL: session.baseURL,
                    bundleID: "dev.healthlog.app",
                    appVersion: "1.3.0",
                    buildNumber: "1"
                ),
                keychain: keychain,
                sessionConfiguration: session.configuration
            )
            let repository = try LabsRepository(api: api, outbox: OutboxQueue(inMemory: true))
            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.owner)
            let store = LabsStore(repository: repository)
            store.bindAuthenticatedSessionRegistry(registry, ownerIDProvider: { Self.owner })
            return store
        }

        private nonisolated static func row(_ id: String, analyte: String, biomarkerId: String?, takenAt: String) -> String {
            let link = biomarkerId.map { "\"\($0)\"" } ?? "null"
            return """
            {"id":"\(id)","biomarkerId":\(link),"panel":null,"analyte":"\(analyte)","value":5.0,"unit":"mg/dl",
            "referenceLow":null,"referenceHigh":null,"takenAt":"\(takenAt)","source":"MANUAL","hasNote":false,
            "rangeStatus":"unknown","createdAt":"\(takenAt)","updatedAt":"\(takenAt)"}
            """
        }

        /// One page of `GET /api/labs`: only the newest marker's readings fit,
        /// as on a long history where the page ends long before 2001.
        private nonisolated static let labsPage = Data("""
        {"data":{"results":[\(row("r1", analyte: "Ferritin", biomarkerId: "bm_fe", takenAt: "2026-10-01T08:00:00Z")),
        \(row("r2", analyte: "Ferritin", biomarkerId: "bm_fe", takenAt: "2026-04-01T08:00:00Z"))],
        "meta":{"total":2000,"limit":500,"offset":0}}}
        """.utf8)

        private nonisolated static let catalog = Data(#"""
        {"data":{"biomarkers":[
          {"id":"bm_fe","name":"Ferritin","unit":"ng/ml","hasContext":false,"createdAt":"","updatedAt":"",
           "aliases":["Ferritin (S)","FERR"]},
          {"id":"bm_tsh","name":"TSH","unit":"mU/l","hasContext":false,"createdAt":"","updatedAt":""}]}}
        """#.utf8)

        /// The overview: Ferritin with its full count, TSH measured only in
        /// 2001 (not on the page above), and an unlinked legacy analyte.
        private nonisolated static let overview = Data("""
        {"data":{"markers":[
          {"key":"bm:bm_fe","count":1200,"trend":[4.0,null,5.0],
           "latest":\(row("r1", analyte: "Ferritin", biomarkerId: "bm_fe", takenAt: "2026-10-01T08:00:00Z"))},
          {"key":"bm:bm_tsh","count":3,"trend":[2.1],
           "latest":\(row("old", analyte: "TSH", biomarkerId: "bm_tsh", takenAt: "2001-03-01T08:00:00Z"))},
          {"key":"analyte:homocystein","count":7,"trend":[],
           "latest":\(row("hc", analyte: "Homocystein", biomarkerId: nil, takenAt: "2004-05-01T08:00:00Z"))},
          {"key":"broken"}
        ]}}
        """.utf8)

        private func install(_ session: MockURLProtocolSession, overviewStatus: Int) {
            session.install { request in
                let path = request.url?.path ?? ""
                let status = path == "/api/labs/overview" ? overviewStatus : 200
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                if status != 200 {
                    return (response, Data(#"{"data":null,"error":"Not found","meta":{"errorCode":"labs.notFound"}}"#.utf8))
                }
                switch path {
                case "/api/labs/overview": return (response, Self.overview)
                case "/api/biomarkers": return (response, Self.catalog)
                default: return (response, Self.labsPage)
                }
            }
        }

        @Test("the list shows every marker of the overview, also one measured only long ago")
        func listFromOverview() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            install(session, overviewStatus: 200)
            let store = try makeStore(session)

            await store.load()

            let index = store.markerIndex
            #expect(index.map(\.name) == ["Ferritin", "Homocystein", "TSH"], "TSH (2001) is cut off")
            #expect(index.first { $0.name == "Ferritin" }?.count == 1200, "the server's count, not the page's 2")
            let tsh = try #require(index.first { $0.name == "TSH" })
            #expect(tsh.biomarkerId == "bm_tsh")
            #expect(tsh.latest.takenAt == "2001-03-01T08:00:00Z")
            #expect(index.first { $0.name == "Homocystein" }?.biomarkerId == nil)
            #expect(store.markerOverview?.markers.count == 3, "the unreadable marker is skipped, the rest kept")
            #expect(store.lastError == nil)
        }

        @Test("a server without the overview route keeps the list from the labs page")
        func fallbackOnOlderServer() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            install(session, overviewStatus: 404)
            let store = try makeStore(session)

            await store.load()

            #expect(store.markerOverview == nil)
            #expect(store.lastError == nil, "a missing overview route is not a failure of the surface")
            let index = store.markerIndex
            #expect(index.map(\.name) == ["Ferritin"])
            #expect(index.first?.count == 2)
        }

        @Test("a failed overview read keeps the previous overview")
        func failedOverviewKeepsPrevious() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            install(session, overviewStatus: 200)
            let store = try makeStore(session)
            await store.load()
            #expect(store.markerIndex.count == 3)

            install(session, overviewStatus: 409)
            await store.load()
            #expect(store.markerIndex.count == 3, "a transient failure does not shrink the list")
            #expect(store.lastError == nil)
        }

        @Test("aliases decode from the catalog, absent ones read as none")
        func aliasesDecode() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            install(session, overviewStatus: 200)
            let store = try makeStore(session)
            await store.load()

            #expect(store.biomarkers.first { $0.id == "bm_fe" }?.aliases == ["Ferritin (S)", "FERR"])
            #expect(store.biomarkers.first { $0.id == "bm_tsh" }?.aliases == [])
        }

        @Test("logout drops the overview with the rest of the labs PHI")
        func logoutClearsOverview() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            install(session, overviewStatus: 200)
            let store = try makeStore(session)
            await store.load()
            #expect(store.markerOverview != nil)

            store.clearOnLogout()
            #expect(store.markerOverview == nil)
            #expect(store.markerIndex.isEmpty)
        }

        @Test("a body without markers is not an overview")
        func shapeWithoutMarkersFails() {
            #expect(throws: (any Error).self) {
                try JSONDecoder.hlDefault.decode(LabOverviewResponse.self, from: Data(#"{"results":[]}"#.utf8))
            }
        }

        @Test("converted readings keep the printed value; decoded, not yet shown")
        func convertedFieldsDecode() throws {
            let json = Data(#"""
            {"id":"c1","analyte":"Glucose","value":5.5,"unit":"mmol/l","converted":true,"sourceValue":99,
             "sourceUnit":"mg/dl","printedReferenceText":"70-99 mg/dl","takenAt":"2026-10-01T08:00:00Z",
             "rangeStatus":"in-range"}
            """#.utf8)
            let row = try JSONDecoder.hlDefault.decode(LabResultDTO.self, from: json)
            #expect(row.converted == true)
            #expect(row.sourceValue == 99)
            #expect(row.sourceUnit == "mg/dl")
            #expect(row.printedReferenceText == "70-99 mg/dl")
            let detail = try JSONDecoder.hlDefault.decode(LabResultDetailDTO.self, from: json)
            #expect(detail.sourceUnit == "mg/dl")
        }
    }

#endif
