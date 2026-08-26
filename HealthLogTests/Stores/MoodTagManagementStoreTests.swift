import Foundation
@testable import HealthLog
import Testing

#if !SWIFT_PACKAGE

    @MainActor
    @Suite("Mood tag management v1.17", .serialized)
    struct MoodTagManagementStoreTests {
        @Test("Custom tags project from their resolved group, archived tags stay separate")
        func customProjectionUsesResolvedTree() async throws {
            MockURLProtocol.handler = { request in
                let body = request.url?.path.hasSuffix("/layout") == true
                    ? Self.projectionLayout
                    : Self.projectionCatalog
                let url = try #require(request.url)
                let response = try #require(
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
                )
                return (response, Data(body.utf8))
            }
            let store = try makeStore()
            await store.load()

            #expect(store.customTags.map(\.key) == ["custom:moved"])
            #expect(store.archivedCustomTags.map(\.key) == ["custom:old"])
            #expect(store.visiblePlacements == [
                "feelings": ["custom:moved"],
                "customcat:garden": []
            ])
        }

        @Test("A custom move reloads authoritative state when its layout PUT fails")
        func movePartialFailureReloadsAuthoritativeState() async throws {
            let sequence = RequestSequence()
            MockURLProtocol.handler = { request in
                let call = sequence.next()
                let response: (Int, String)
                switch call {
                case 1:
                    response = (200, Self.catalog(groupKey: "feelings"))
                case 2, 4, 7:
                    response = (200, Self.layout)
                case 3:
                    response = (200, Self.movedTagResponse)
                case 5:
                    response = (422, #"{"data":null,"error":{"code":"FAILED","message":"Layout failed"}}"#)
                case 6:
                    response = (200, Self.catalog(groupKey: "customcat:garden"))
                default:
                    Issue.record("Unexpected request \(call): \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                    response = (500, "{}")
                }
                let url = try #require(request.url)
                let httpResponse = try #require(
                    HTTPURLResponse(url: url, statusCode: response.0, httpVersion: nil, headerFields: nil)
                )
                return (httpResponse, Data(response.1.utf8))
            }

            let store = try makeStore()
            await store.load()
            let succeeded = await store.moveTag(key: "custom:1", to: "customcat:garden")

            #expect(!succeeded)
            #expect(sequence.count == 7)
            #expect(store.catalog.categories.first { $0.key == "customcat:garden" }?.tags.map(\.key) == ["custom:1"])
            #expect(store.mutationError != nil)
        }

        private func makeStore() throws -> MoodTagManagementStore {
            let baseURL = try #require(URL(string: "https://test.healthlog.local"))
            let environment = AppEnvironment(
                baseURL: baseURL,
                cfAccessClientID: nil,
                cfAccessClientToken: nil,
                bundleID: "dev.healthlog.app",
                appVersion: "1",
                buildNumber: "1"
            )
            let keychain = InMemoryKeychain()
            try? keychain.setString("token", forKey: KeychainKey.authToken)
            let api = APIClient(environment: environment, keychain: keychain, sessionConfiguration: .mock())
            return MoodTagManagementStore(repo: MoodTagCatalogRepository(api: api))
        }

        private nonisolated static let projectionLayout = """
        {"data":{
          "groupOrder":["feelings","customcat:garden"],
          "placements":{"feelings":["custom:moved"],"customcat:garden":[]}
        },"error":null}
        """

        private nonisolated static let projectionCatalog = """
        {"data":{"categories":[
          {"key":"feelings","labelKey":"mood.tagCategory.feelings","icon":"Heart","tags":[
            {"key":"custom:moved","labelKey":null,"label":"Moved","icon":"Tag","custom":true}
          ]},
          {"key":"customcat:garden","labelKey":null,"label":"Garden","icon":"Leaf","custom":true,"tags":[
            {"key":"custom:old","labelKey":null,"label":"Old","icon":"Tag","custom":true,"archived":true}
          ]}
        ]},"error":null}
        """

        private nonisolated static let layout = """
        {"data":{
          "groupOrder":["feelings","customcat:garden"],
          "placements":{"feelings":["custom:1"],"customcat:garden":[]}
        },"error":null}
        """

        private nonisolated static func catalog(groupKey: String) -> String {
            let feelingsTags = groupKey == "feelings" ? Self.customTag : ""
            let gardenTags = groupKey == "customcat:garden" ? Self.customTag : ""
            return """
            {"data":{"categories":[
              {"key":"feelings","labelKey":"mood.tagCategory.feelings","icon":"Heart",
               "custom":false,"tags":[\(feelingsTags)]},
              {"key":"customcat:garden","labelKey":null,"label":"Garden","icon":"Leaf",
               "custom":true,"tags":[\(gardenTags)]}
            ]},"error":null}
            """
        }

        private nonisolated static let movedTagResponse = """
        {"data":{
          "key":"custom:1","labelKey":null,"label":"Moved","icon":"Tag","custom":true
        },"error":null}
        """

        private nonisolated static let customTag = """
        {"key":"custom:1","labelKey":null,"label":"Moved","icon":"Tag",
         "custom":true,"archived":false}
        """
    }

    private final class RequestSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.withLock {
                value += 1
                return value
            }
        }

        var count: Int {
            lock.withLock { value }
        }
    }

#endif
