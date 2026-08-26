import Foundation
import Testing

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    @testable import HealthLog

    /// **Parity 1.1 — the purge confirmation's usage count.**
    ///
    /// Purging a custom mood tag hard-deletes it AND cascades away every link to
    /// the user's historical mood entries. The confirmation names how many
    /// entries that is, exactly as the web does
    /// (`archived-tags-card.tsx:178`). The number must come from the server —
    /// it is served per tag under `?include=usage`
    /// (`api/mood/tags/route.ts:170`) — never from a client-side guess, so the
    /// two things pinned here are: the management read *asks* for it, and the
    /// DTO keeps `nil` distinguishable from `0` when it is not served.
    ///
    /// Lives in its own file rather than in `MoodTagCatalogTests` because that
    /// suite is already over the `type_body_length` budget.
    @MainActor
    @Suite("Mood tag usage count (parity 1.1)", .serialized)
    struct MoodTagUsageCountTests {
        private func makeAPI() -> APIClient {
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        }

        /// Thread-safe capture of the request's query string.
        private final class QueryBox: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: String?
            func set(_ value: String?) {
                lock.withLock { stored = value }
            }

            var value: String? {
                lock.withLock { stored }
            }
        }

        /// One custom tag WITH a usage count, one catalogue tag WITHOUT one —
        /// so both branches of the confirmation body are exercised.
        private nonisolated static let usageCatalogJSON: Data = .init("""
        {
          "data": {
            "categories": [
              {
                "key": "feelings",
                "labelKey": "mood.tagCategory.feelings",
                "icon": "Heart",
                "tags": [
                  { "key": "happy", "labelKey": "mood.tag.happy", "icon": "Smile" }
                ]
              },
              {
                "key": "custom",
                "labelKey": "mood.tagCategory.custom",
                "icon": "Tag",
                "tags": [
                  {
                    "key": "custom:abc-123",
                    "labelKey": null,
                    "icon": "Brain",
                    "custom": true,
                    "label": "Migräne",
                    "usageCount": 17
                  },
                  {
                    "key": "custom:def-456",
                    "labelKey": null,
                    "icon": "Tag",
                    "custom": true,
                    "label": "Neu",
                    "usageCount": 0
                  }
                ]
              }
            ]
          },
          "error": null
        }
        """.utf8)

        @Test("Management read asks the server for the usage counts")
        func managementReadRequestsUsage() async throws {
            let repo = MoodTagCatalogRepository(api: makeAPI())
            let query = QueryBox()
            MockURLProtocol.handler = { req in
                query.set(req.url?.query)
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Self.usageCatalogJSON
                )
            }
            _ = try await repo.managementCatalog()
            let captured = try #require(query.value)
            // `include` is a comma list server-side; both flags must ride along —
            // dropping `hidden` would empty the hide/show section.
            #expect(captured.contains("include="))
            #expect(captured.contains("usage"))
            #expect(captured.contains("hidden"))
        }

        @Test("usageCount decodes per tag when the server serves it")
        func usageCountDecodes() async throws {
            let repo = MoodTagCatalogRepository(api: makeAPI())
            MockURLProtocol.handler = { req in
                (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Self.usageCatalogJSON
                )
            }
            let catalog = try await repo.managementCatalog()
            let tags = catalog.categories.flatMap(\.tags)
            let used = try #require(tags.first { $0.key == "custom:abc-123" })
            #expect(used.usageCount == 17)
            // A never-used tag is a real `0`, NOT `nil` — the confirmation may
            // honestly say "0 entries" in that case.
            let unused = try #require(tags.first { $0.key == "custom:def-456" })
            #expect(unused.usageCount == 0)
        }

        /// A pre-`include=usage` server omits the field entirely. It must stay
        /// `nil`, never collapse to `0` — the confirmation then drops the count
        /// rather than telling the user "0 entries" about a tag it cannot count.
        @Test("Absent usageCount decodes as nil, never 0")
        func absentUsageCountStaysNil() async throws {
            let repo = MoodTagCatalogRepository(api: makeAPI())
            MockURLProtocol.handler = { req in
                (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Self.usageCatalogJSON
                )
            }
            let catalog = try await repo.managementCatalog()
            let happy = try #require(catalog.categories.flatMap(\.tags).first { $0.key == "happy" })
            #expect(happy.usageCount == nil)
        }
    }

#endif
