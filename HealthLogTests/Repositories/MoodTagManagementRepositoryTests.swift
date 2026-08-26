import Foundation
import Testing

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    @testable import HealthLog

    @MainActor
    @Suite("Mood tag management repository v1.17", .serialized)
    struct MoodTagManagementRepositoryTests {
        private func makeAPI() -> APIClient {
            let environment = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            return APIClient(
                environment: environment,
                keychain: InMemoryKeychain(),
                sessionConfiguration: .mock()
            )
        }

        @Test("Management GET requests hidden, archived, and usage metadata")
        func managementReadIncludesCompleteManageSet() async throws {
            let request = RequestCapture()
            MockURLProtocol.handler = { urlRequest in
                request.capture(urlRequest)
                return Self.response(for: urlRequest, body: Self.catalogJSON)
            }

            let repository = MoodTagCatalogRepository(api: makeAPI())
            _ = try await repository.managementCatalog()

            #expect(request.query == "include=hidden,archived,usage")
        }

        @Test("Custom categories and archived tags decode the management wire")
        func customGroupAndArchivedTagDecode() throws {
            let catalog = try JSONDecoder().decode(MoodTagCatalog.self, from: Data("""
            {
              "categories": [{
                "key": "customcat:garden",
                "labelKey": null,
                "label": "Garten",
                "icon": "Leaf",
                "custom": true,
                "tags": [{
                  "key": "custom:old",
                  "labelKey": null,
                  "label": "Altes Tag",
                  "icon": "Tag",
                  "custom": true,
                  "archived": true,
                  "usageCount": 4
                }]
              }]
            }
            """.utf8))

            let group = try #require(catalog.categories.first)
            let tag = try #require(group.tags.first)
            #expect(group.labelKey == nil)
            #expect(group.label == "Garten")
            #expect(group.custom)
            #expect(group.localizedLabel == "Garten")
            #expect(tag.archived)
            #expect(tag.usageCount == 4)
        }

        @Test("PATCH custom carries categoryKey and percent-encodes the opaque key")
        func patchCustomCategoryAndSafePath() async throws {
            let request = RequestCapture()
            MockURLProtocol.handler = { urlRequest in
                request.capture(urlRequest)
                return Self.response(
                    for: urlRequest,
                    body: Self.movedTagJSON
                )
            }

            let repository = MoodTagCatalogRepository(api: makeAPI())
            _ = try await repository.updateCustom(
                key: "custom:a/b",
                label: nil,
                icon: nil,
                isActive: nil,
                categoryKey: "customcat:garden"
            )

            // `:` is a valid path `pchar` (kept raw); only the `/` is encoded.
            #expect(request.path == "/api/mood/tags/custom/custom:a%2Fb")
            let body = try #require(request.jsonBody)
            #expect(body["categoryKey"] as? String == "customcat:garden")
            #expect(body["label"] == nil)
            #expect(body["icon"] == nil)
            #expect(body["isActive"] == nil)
        }

        @Test("Archive and restore PATCH the custom tag isActive flag")
        func archiveRestoreRequestShape() async throws {
            let request = RequestCapture()
            MockURLProtocol.handler = { urlRequest in
                request.capture(urlRequest)
                return Self.response(
                    for: urlRequest,
                    body: Self.archivedTagJSON
                )
            }
            let repository = MoodTagCatalogRepository(api: makeAPI())

            _ = try await repository.updateCustom(
                key: "custom:x",
                label: nil,
                icon: nil,
                isActive: false
            )
            #expect(request.jsonBody?["isActive"] as? Bool == false)

            _ = try await repository.updateCustom(
                key: "custom:x",
                label: nil,
                icon: nil,
                isActive: true
            )
            #expect(request.jsonBody?["isActive"] as? Bool == true)
        }

        @Test("Group POST, PATCH, and DELETE match the v1.17 routes")
        func groupCRUDRequestShapes() async throws {
            let request = RequestCapture()
            let calls = Counter()
            MockURLProtocol.handler = { urlRequest in
                let call = calls.increment()
                request.capture(urlRequest)
                switch call {
                case 1:
                    return Self.response(
                        for: urlRequest,
                        status: 201,
                        body: Self.createdGroupJSON
                    )
                case 2:
                    return Self.response(
                        for: urlRequest,
                        body: Self.updatedGroupJSON
                    )
                default:
                    return Self.response(
                        for: urlRequest,
                        body: Self.deletedGroupJSON
                    )
                }
            }

            let repository = MoodTagCatalogRepository(api: makeAPI())
            let created = try await repository.createGroup(label: "Garten", icon: "Leaf")
            #expect(created.custom)
            #expect(created.label == "Garten")
            let createBody = try #require(request.jsonBody)
            #expect(createBody["label"] as? String == "Garten")
            #expect(createBody["icon"] as? String == "Leaf")

            _ = try await repository.updateGroup(
                key: "customcat:g1",
                label: "Draußen",
                icon: "Trees",
                isActive: nil
            )
            #expect(request.path == "/api/mood/tags/groups/customcat:g1")
            #expect(request.method == "PATCH")
            let updateBody = try #require(request.jsonBody)
            #expect(updateBody["label"] as? String == "Draußen")
            #expect(updateBody["icon"] as? String == "Trees")
            #expect(updateBody["isActive"] == nil)

            let deleted = try await repository.deleteGroup(key: "customcat:g1", purge: false)
            #expect(request.path == "/api/mood/tags/groups/customcat:g1")
            #expect(request.method == "DELETE")
            #expect(request.query == nil)
            #expect(deleted.rehomedCount == 2)
            #expect(!deleted.purged)
        }

        @Test("Group-order PUT preserves placements from GET")
        func groupOrderWritePreservesPlacements() async throws {
            let request = RequestCapture()
            let calls = Counter()
            MockURLProtocol.handler = { urlRequest in
                _ = calls.increment()
                request.capture(urlRequest)
                return Self.response(for: urlRequest, body: Self.layoutJSON)
            }

            let repository = MoodTagCatalogRepository(api: makeAPI())
            _ = try await repository.updateGroupOrder(["customcat:g1", "feelings"])

            #expect(calls.value == 2)
            let body = try #require(request.jsonBody)
            #expect(body["groupOrder"] as? [String] == ["customcat:g1", "feelings"])
            let placements = try #require(body["placements"] as? [String: [String]])
            #expect(placements == ["feelings": ["happy"], "customcat:g1": ["custom:1"]])
        }

        @Test("Placement PUT preserves group order and sends the full visible map")
        func placementWritePreservesGroupOrderAndUsesFullMap() async throws {
            let request = RequestCapture()
            MockURLProtocol.handler = { urlRequest in
                request.capture(urlRequest)
                return Self.response(for: urlRequest, body: Self.layoutJSON)
            }

            let repository = MoodTagCatalogRepository(api: makeAPI())
            _ = try await repository.updatePlacements([
                "feelings": ["happy", "sad"],
                "customcat:g1": ["custom:1", "worked_out"]
            ])

            let body = try #require(request.jsonBody)
            #expect(body["groupOrder"] as? [String] == ["feelings", "customcat:g1"])
            let placements = try #require(body["placements"] as? [String: [String]])
            #expect(placements == [
                "feelings": ["happy", "sad"],
                "customcat:g1": ["custom:1", "worked_out"]
            ])
        }

        private nonisolated static func response(
            for request: URLRequest,
            status: Int = 200,
            body: String
        ) -> (HTTPURLResponse, Data) {
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(body.utf8)
            )
        }

        private nonisolated static let catalogJSON = #"{"data":{"categories":[]},"error":null}"#
        private nonisolated static let movedTagJSON =
            #"{"data":{"key":"custom:a/b","labelKey":null,"label":"Neu","icon":"Tag","custom":true},"error":null}"#
        private nonisolated static let archivedTagJSON =
            #"{"data":{"key":"custom:x","labelKey":null,"label":"X","icon":"Tag","custom":true},"error":null}"#
        private nonisolated static let createdGroupJSON = """
        {"data":{
          "key":"customcat:g1","labelKey":null,"label":"Garten","icon":"Leaf","custom":true
        },"error":null}
        """
        private nonisolated static let updatedGroupJSON = """
        {"data":{
          "key":"customcat:g1","labelKey":null,"label":"Draußen","icon":"Trees",
          "custom":true,"isActive":true
        },"error":null}
        """
        private nonisolated static let deletedGroupJSON =
            #"{"data":{"key":"customcat:g1","purged":false,"rehomedCount":2},"error":null}"#
        private nonisolated static let layoutJSON = """
        {"data":{
          "groupOrder":["feelings","customcat:g1"],
          "placements":{"feelings":["happy"],"customcat:g1":["custom:1"]}
        },"error":null}
        """
    }

    private final class RequestCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var storedPath = ""
        private var storedMethod = ""
        private var storedQuery: String?
        private var storedBody: Data?

        var path: String {
            lock.withLock { storedPath }
        }

        var method: String {
            lock.withLock { storedMethod }
        }

        var query: String? {
            lock.withLock { storedQuery }
        }

        var jsonBody: [String: Any]? {
            lock.withLock {
                guard let storedBody else { return nil }
                return try? JSONSerialization.jsonObject(with: storedBody) as? [String: Any]
            }
        }

        func capture(_ request: URLRequest) {
            lock.withLock {
                storedPath = URLComponents(
                    url: request.url!,
                    resolvingAgainstBaseURL: false
                )?.percentEncodedPath ?? ""
                storedMethod = request.httpMethod ?? ""
                storedQuery = request.url?.query
                storedBody = request.httpBody ?? Self.body(from: request.httpBodyStream)
            }
        }

        private nonisolated static func body(from stream: InputStream?) -> Data? {
            guard let stream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: bufferSize)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            return data
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0

        var value: Int {
            lock.withLock { stored }
        }

        func increment() -> Int {
            lock.withLock {
                stored += 1
                return stored
            }
        }
    }

#endif
