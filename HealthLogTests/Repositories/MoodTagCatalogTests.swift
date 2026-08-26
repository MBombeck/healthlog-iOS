import Foundation
import Testing

// swiftlint:disable force_unwrapping force_try

#if !SWIFT_PACKAGE

    @testable import HealthLog

    /// v0.14 — coverage for the Daylio-style structured mood-tag feature.
    ///
    /// Five axes, mirroring the build brief's test list:
    ///  1. **Catalog decode** — `GET /api/mood/tags` envelope → `MoodTagCatalog`,
    ///     plus SWR cache-TTL + bundled-fallback discipline.
    ///  2. **Picker selection state** — Set toggle + catalog-ordered projection.
    ///  3. **Save includes `tagKeys`** — the real `MoodRepository` POST body
    ///     carries the picked keys (stub URLSession, not a mock server).
    ///  4. **Offline persists `tagKeys`** — standalone write → read-back, no net.
    ///  5. **Adopt-on-pair carries `tagKeys`** — the bulk DTO encodes them.
    @MainActor
    @Suite("Mood tag taxonomy (v0.14)", .serialized)
    struct MoodTagCatalogTests {
        // MARK: - Fixtures

        private final class ClockBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _now: Date
            init(now: Date) {
                _now = now
            }

            var now: Date {
                lock.withLock { _now }
            }

            func advance(by interval: TimeInterval) {
                lock.withLock { _now = _now.addingTimeInterval(interval) }
            }
        }

        private final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var _value = 0
            var value: Int {
                lock.withLock { _value }
            }

            func increment() {
                lock.withLock { _value += 1 }
            }
        }

        private func makeAPI() -> APIClient {
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        }

        /// Server-shaped catalog envelope (mirrors `src/app/api/mood/tags/route.ts`).
        /// `nonisolated` so the `@Sendable` MockURLProtocol closure can read it
        /// from the `@MainActor` suite without a main-actor hop.
        private nonisolated static let catalogJSON: Data = .init("""
        {
          "data": {
            "categories": [
              {
                "key": "feelings",
                "labelKey": "mood.tagCategory.feelings",
                "icon": "Heart",
                "tags": [
                  { "key": "happy", "labelKey": "mood.tag.happy", "icon": "Smile" },
                  { "key": "sad", "labelKey": "mood.tag.sad", "icon": "Frown" }
                ]
              },
              {
                "key": "health",
                "labelKey": "mood.tagCategory.health",
                "icon": "HeartPulse",
                "tags": [
                  { "key": "worked_out", "labelKey": "mood.tag.workedOut", "icon": "Dumbbell" }
                ]
              }
            ]
          },
          "error": null
        }
        """.utf8)

        // MARK: - 1. Catalog decode + SWR

        @Test("Catalog decodes the server envelope into categories + tags")
        func catalogDecodes() async {
            let repo = MoodTagCatalogRepository(api: makeAPI())
            MockURLProtocol.handler = { req in
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.catalogJSON)
            }
            let catalog = await repo.catalog()
            #expect(catalog.categories.count == 2)
            #expect(catalog.categories.first?.key == "feelings")
            #expect(catalog.categories.first?.tags.map(\.key) == ["happy", "sad"])
            #expect(catalog.containsTag("worked_out"))
            #expect(!catalog.containsTag("nope"))
        }

        @Test("Lucide icon names map to SF Symbols, not raw Lucide strings")
        func iconsMapToSFSymbols() async throws {
            let repo = MoodTagCatalogRepository(api: makeAPI())
            MockURLProtocol.handler = { req in
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.catalogJSON)
            }
            let catalog = await repo.catalog()
            let happy = try #require(catalog.categories.flatMap(\.tags).first { $0.key == "happy" })
            // `Smile` (Lucide) must resolve to an SF Symbol, never echo the Lucide name.
            #expect(MoodTagSFSymbol.symbol(forTag: happy) == "face.smiling")
            #expect(catalog.categories.first?.sfSymbol == "heart")
        }

        @Test("Second call within TTL is cache-served (no extra HTTP hit)")
        func cacheWithinTTL() async {
            let clock = ClockBox(now: Date(timeIntervalSince1970: 1_700_000_000))
            let repo = MoodTagCatalogRepository(api: makeAPI(), cacheTTL: 86400, clock: { clock.now })
            let hits = Counter()
            MockURLProtocol.handler = { [hits] req in
                hits.increment()
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.catalogJSON)
            }
            _ = await repo.catalog()
            clock.advance(by: 3600)
            _ = await repo.catalog()
            #expect(hits.value == 1)
        }

        @Test("Network failure on first call returns the bundled fallback (no throw)")
        func networkFailureFallsBack() async {
            let repo = MoodTagCatalogRepository(api: makeAPI())
            MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
            let catalog = await repo.catalog()
            // Bundled fallback seeds all five server categories.
            #expect(catalog.categories.map(\.key) == ["feelings", "sleep", "health", "social", "work"])
            #expect(catalog.containsTag("worked_out"))
        }

        @Test("Bundled fallback resolves every tag to a real SF Symbol")
        func bundledFallbackSymbolsResolve() {
            let catalog = MoodTagCatalogRepository.bundledFallback
            for tag in catalog.categories.flatMap(\.tags) {
                let symbol = MoodTagSFSymbol.symbol(forTag: tag)
                #expect(!symbol.isEmpty)
                // Never echo a Lucide name (Lucide names are PascalCase words).
                #expect(symbol != tag.icon)
            }
        }

        // MARK: - 2. Picker selection state

        @Test("Selection toggle + catalog-ordered projection is deterministic")
        func orderedSelection() {
            let catalog = MoodTagCatalogRepository.bundledFallback
            // Pick out-of-order across categories.
            var selection: Set<String> = []
            selection.insert("worked_out") // health
            selection.insert("happy") // feelings (earlier category)
            selection.insert("party") // social
            let ordered = catalog.orderedKeys(from: selection)
            // Category order feelings < health < social drives the result.
            #expect(ordered == ["happy", "worked_out", "party"])
        }

        @Test("Unknown selected keys survive at the tail, never dropped")
        func orderedSelectionKeepsUnknown() {
            let catalog = MoodTagCatalogRepository.bundledFallback
            let ordered = catalog.orderedKeys(from: ["happy", "ghost_tag"])
            #expect(ordered.first == "happy")
            #expect(ordered.contains("ghost_tag"))
            #expect(ordered.count == 2)
        }

        // MARK: - 3. Save includes tagKeys (real repo, stub session)

        @Test("POST /api/mood-entries body carries the picked tagKeys")
        func saveIncludesTagKeys() async throws {
            let captured = CapturedBody()
            MockURLProtocol.handler = { req in
                captured.capture(req)
                // Echo a server-shaped created entry (status 201) including tagKeys.
                let body = Data("""
                { "data": { "id": "srv-1", "mood": "GUT", "tags": [], "tagKeys": ["happy","worked_out"],
                  "moodLoggedAt": "2026-06-04T10:00:00.000Z", "source": "MANUAL", "note": null }, "error": null }
                """.utf8)
                return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, body)
            }
            let repo = try MoodRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
            let saved = try await repo.log(score: 4, tags: [], tagKeys: ["happy", "worked_out"], note: nil)
            #expect(saved.tagKeys == ["happy", "worked_out"])

            let bodyJSON = try #require(captured.json())
            let sentKeys = bodyJSON["tagKeys"] as? [String]
            #expect(sentKeys == ["happy", "worked_out"], "the POST body must carry tagKeys")
        }

        @Test("Empty tagKeys are omitted from the POST body (lean legacy bodies)")
        func emptyTagKeysOmitted() async throws {
            let captured = CapturedBody()
            MockURLProtocol.handler = { req in
                captured.capture(req)
                let body = Data("""
                { "data": { "id": "srv-2", "mood": "OKAY", "tags": [],
                  "moodLoggedAt": "2026-06-04T10:00:00.000Z", "source": "MANUAL", "note": null }, "error": null }
                """.utf8)
                return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, body)
            }
            let repo = try MoodRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
            _ = try await repo.log(score: 3, tags: [], tagKeys: [], note: nil)
            let bodyJSON = try #require(captured.json())
            #expect(bodyJSON["tagKeys"] == nil)
        }

        @Test("A server response without tagKeys decodes to an empty set (back-compat)")
        func decodesMissingTagKeys() throws {
            let json = Data("""
            { "id": "old", "mood": "GUT", "tags": ["Stress"],
              "moodLoggedAt": "2026-06-04T10:00:00.000Z", "source": "MANUAL", "note": null }
            """.utf8)
            let entry = try JSONDecoder.hlDefault.decode(MoodEntry.self, from: json)
            #expect(entry.tagKeys.isEmpty)
            #expect(entry.tags == ["Stress"])
        }

        // MARK: - 4. Offline persist + read-back (standalone, no network)

        private struct EmptyHK: StandaloneHealthKitReadServing {
            func standaloneRecentSamples(kind _: MetricKind, days _: Int, limit _: Int) async -> [SeriesPoint] {
                []
            }

            func standaloneDailySeries(kind _: MetricKind, days _: Int) async -> [SeriesPoint] {
                []
            }
        }

        @Test("Standalone mood write persists tagKeys and reads them back, no /api/*")
        func standaloneRoundTripCarriesTagKeys() async throws {
            let fired = Counter()
            MockURLProtocol.handler = { [fired] _ in
                fired.increment()
                throw URLError(.notConnectedToInternet)
            }
            let local = try LocalRepository(store: LocalStore(modelContainer: LocalStore.makeInMemory()))
            let gate = StandaloneGate(local: local, healthKit: EmptyHK(), isStandalone: { true })
            let repo = try MoodRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true), standalone: gate)

            let saved = try await repo.log(score: 5, tags: [], tagKeys: ["grateful", "slept_well"], note: nil)
            #expect(saved.tagKeys == ["grateful", "slept_well"])

            let recent = try await repo.recent(days: 30)
            let readBack = try #require(recent.first { $0.id == saved.id })
            #expect(readBack.tagKeys == ["grateful", "slept_well"])
            #expect(fired.value == 0, "standalone path must fire zero /api/* calls")
        }

        @Test("Standalone mood update edits tagKeys")
        func standaloneUpdateEditsTagKeys() async throws {
            let local = try LocalRepository(store: LocalStore(modelContainer: LocalStore.makeInMemory()))
            let gate = StandaloneGate(local: local, healthKit: EmptyHK(), isStandalone: { true })
            let repo = try MoodRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true), standalone: gate)
            MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }

            let saved = try await repo.log(score: 4, tags: [], tagKeys: ["happy"], note: nil)
            let updated = try await repo.update(
                id: saved.id, patch: MoodEntryPatch(tagKeys: ["happy", "walked"])
            )
            #expect(Set(updated.tagKeys) == Set(["happy", "walked"]))
        }

        // MARK: - 5. Adopt-on-pair carries tagKeys

        @Test("Bulk adopt DTO encodes tagKeys when present, omits when empty")
        func bulkDTOEncodesTagKeys() throws {
            let encoder = JSONEncoder()
            let withKeys = BulkMoodEntryDTO(
                mood: "GUT", tags: nil, tagKeys: ["happy", "walked"], note: nil,
                moodLoggedAt: Date(timeIntervalSince1970: 1_700_000_000), source: "MANUAL", externalId: "a"
            )
            let json = try #require(JSONSerialization.jsonObject(with: encoder.encode(withKeys)) as? [String: Any])
            #expect(json["tagKeys"] as? [String] == ["happy", "walked"])

            let withoutKeys = BulkMoodEntryDTO(
                mood: "OKAY", tags: nil, tagKeys: nil, note: nil,
                moodLoggedAt: Date(timeIntervalSince1970: 1_700_000_000), source: "MANUAL", externalId: "b"
            )
            let json2 = try #require(JSONSerialization.jsonObject(with: encoder.encode(withoutKeys)) as? [String: Any])
            #expect(json2["tagKeys"] == nil)
        }

        // MARK: - v1.13.0 — custom / label / hidden decode + symbol coverage

        private nonisolated static let customCatalogJSON: Data = .init("""
        {
          "data": {
            "categories": [
              {
                "key": "feelings",
                "labelKey": "mood.tagCategory.feelings",
                "icon": "Heart",
                "tags": [
                  { "key": "happy", "labelKey": "mood.tag.happy", "icon": "Smile" },
                  { "key": "sad", "labelKey": "mood.tag.sad", "icon": "Frown", "hidden": true }
                ]
              },
              {
                "key": "custom",
                "labelKey": "mood.tagCategory.custom",
                "icon": "Tag",
                "tags": [
                  { "key": "custom:abc-123", "labelKey": null, "icon": "Brain", "custom": true, "label": "Migräne" }
                ]
              }
            ]
          },
          "error": null
        }
        """.utf8)

        @Test("Custom tag decodes custom=true + label, and renders label not labelKey")
        func customTagDecodes() async throws {
            let repo = MoodTagCatalogRepository(api: makeAPI())
            MockURLProtocol.handler = { req in
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.customCatalogJSON)
            }
            let catalog = try await repo.managementCatalog()
            let custom = try #require(catalog.categories
                .first { $0.key == "custom" }?.tags.first)
            #expect(custom.custom)
            #expect(custom.label == "Migräne")
            // localizedLabel renders the user's `label` verbatim, not the (null) labelKey.
            #expect(custom.localizedLabel == "Migräne")
            // The custom category resolves its own labelKey.
            #expect(catalog.categories.first { $0.key == "custom" }?.labelKey == "mood.tagCategory.custom")
            // Catalogue lookup also returns the custom label.
            #expect(catalog.label(forTagKey: "custom:abc-123") == "Migräne")
        }

        @Test("Hidden catalogue tag decodes hidden=true (management read)")
        func hiddenFlagDecodes() async throws {
            let repo = MoodTagCatalogRepository(api: makeAPI())
            MockURLProtocol.handler = { req in
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.customCatalogJSON)
            }
            let catalog = try await repo.managementCatalog()
            let sad = try #require(catalog.categories.flatMap(\.tags).first { $0.key == "sad" })
            #expect(sad.hidden)
            let happy = try #require(catalog.categories.flatMap(\.tags).first { $0.key == "happy" })
            #expect(!happy.hidden)
            #expect(!happy.custom)
        }

        @Test("A catalogue tag decodes custom=false + nil label (back-compat)")
        func catalogueTagDefaultsCustomFalse() async throws {
            let repo = MoodTagCatalogRepository(api: makeAPI())
            MockURLProtocol.handler = { req in
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.catalogJSON)
            }
            let catalog = await repo.catalog()
            let happy = try #require(catalog.categories.flatMap(\.tags).first { $0.key == "happy" })
            #expect(!happy.custom)
            #expect(happy.label == nil)
            #expect(!happy.hidden)
        }

        @Test("Every custom-icon allow-list name maps to a real SF Symbol (not the Lucide name)")
        func allowListIconsAllMap() {
            // #21 — the allow-list now mirrors the full 74-name server catalog
            // (`src/lib/mood/icon-catalog.ts`), no client-only extras.
            #expect(MoodTagCatalog.customIconAllowList.count == 74)
            for icon in MoodTagCatalog.customIconAllowList {
                let symbol = MoodTagSFSymbol.symbolForAllowListIcon(icon)
                #expect(!symbol.isEmpty)
                // Never echo the Lucide PascalCase name as a "symbol".
                #expect(symbol != icon, "\(icon) must map to an SF Symbol, not echo the Lucide name")
                // Every allow-list name must have an explicit table entry — none
                // may rely on the fallback (that would be a silent blank-risk).
                #expect(MoodTagSFSymbol.symbol(forLucide: icon) != nil, "\(icon) missing from the symbol table")
            }
        }

        // MARK: - v1.13.0 — custom-tag CRUD request shapes (real repo, stub session)

        @Test("POST /api/mood/tags/custom carries label + icon + categoryKey")
        func createCustomRequestShape() async throws {
            let captured = CapturedBody()
            let path = PathBox()
            MockURLProtocol.handler = { req in
                captured.capture(req)
                path.set(req.url?.path ?? "", method: req.httpMethod ?? "")
                let body = Data("""
                { "data": { "key": "custom:new-1", "labelKey": null, "icon": "Brain", "custom": true, "label": "Therapie" }, "error": null }
                """.utf8)
                return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, body)
            }
            let repo = MoodTagCatalogRepository(api: makeAPI())
            let created = try await repo.createCustom(label: "Therapie", icon: "Brain", categoryKey: "custom")
            #expect(created.key == "custom:new-1")
            #expect(created.label == "Therapie")
            #expect(path.path == "/api/mood/tags/custom")
            #expect(path.method == "POST")
            let json = try #require(captured.json())
            #expect(json["label"] as? String == "Therapie")
            #expect(json["icon"] as? String == "Brain")
            #expect(json["categoryKey"] as? String == "custom")
        }

        @Test("PATCH /api/mood/tags/custom/:key omits nil fields")
        func patchCustomOmitsNil() async throws {
            let captured = CapturedBody()
            let path = PathBox()
            MockURLProtocol.handler = { req in
                captured.capture(req)
                path.set(req.url?.path ?? "", method: req.httpMethod ?? "")
                let body = Data("""
                { "data": { "key": "custom:x", "labelKey": null, "icon": "Tag", "custom": true, "label": "Neu" }, "error": null }
                """.utf8)
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            }
            let repo = MoodTagCatalogRepository(api: makeAPI())
            _ = try await repo.updateCustom(key: "custom:x", label: "Neu", icon: nil, isActive: nil)
            #expect(path.path == "/api/mood/tags/custom/custom:x")
            #expect(path.method == "PATCH")
            let json = try #require(captured.json())
            #expect(json["label"] as? String == "Neu")
            #expect(json["icon"] == nil, "nil icon must be omitted from the PATCH body")
            #expect(json["isActive"] == nil, "nil isActive must be omitted")
        }

        @Test("DELETE custom: soft by default, ?purge=true when purging")
        func deleteCustomPurgeFlag() async throws {
            let path = PathBox()
            MockURLProtocol.handler = { req in
                path.set(req.url?.path ?? "", method: req.httpMethod ?? "")
                path.setQuery(req.url?.query)
                // 200 + `{}` so the `EmptyResponse` decode is satisfied in the
                // stub (a real 204 No Content carries no body; the request shape
                // — verb + path + ?purge — is what this test pins).
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
            }
            let repo = MoodTagCatalogRepository(api: makeAPI())
            try await repo.deleteCustom(key: "custom:y", purge: false)
            #expect(path.method == "DELETE")
            #expect(path.query == nil)
            try await repo.deleteCustom(key: "custom:y", purge: true)
            #expect(path.query == "purge=true")
        }

        @Test("PUT /api/mood/tags/:key/hidden carries the hidden flag")
        func setCatalogueHiddenRequestShape() async throws {
            let captured = CapturedBody()
            let path = PathBox()
            MockURLProtocol.handler = { req in
                captured.capture(req)
                path.set(req.url?.path ?? "", method: req.httpMethod ?? "")
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
            }
            let repo = MoodTagCatalogRepository(api: makeAPI())
            try await repo.setCatalogueHidden(key: "sad", hidden: true)
            #expect(path.path == "/api/mood/tags/sad/hidden")
            #expect(path.method == "PUT")
            let json = try #require(captured.json())
            #expect(json["hidden"] as? Bool == true)
        }

        @Test("422 over the cap surfaces as HLError.server (inline for the UI)")
        func createCustom422Surfaces() async {
            MockURLProtocol.handler = { req in
                let body = Data("""
                { "data": null, "error": { "code": "MOOD_TAG_CAP", "message": "You can create up to 50 tags." } }
                """.utf8)
                return (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, body)
            }
            let repo = MoodTagCatalogRepository(api: makeAPI())
            await #expect(throws: HLError.self) {
                _ = try await repo.createCustom(label: "x", icon: "Tag", categoryKey: "custom")
            }
        }

        // MARK: - Path/query capture helper

        private final class PathBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _path = ""
            private var _method = ""
            private var _query: String?
            func set(_ path: String, method: String) {
                lock.withLock { _path = path
                    _method = method
                }
            }

            func setQuery(_ q: String?) {
                lock.withLock { _query = q }
            }

            var path: String {
                lock.withLock { _path }
            }

            var method: String {
                lock.withLock { _method }
            }

            var query: String? {
                lock.withLock { _query }
            }
        }

        // MARK: - Body capture helper

        private final class CapturedBody: @unchecked Sendable {
            private let lock = NSLock()
            private var _body: Data?

            func capture(_ req: URLRequest) {
                lock.withLock { _body = req.httpBody ?? Self.bodyFromStream(req) }
            }

            func json() -> [String: Any]? {
                let data = lock.withLock { _body }
                guard let data else { return nil }
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }

            private static func bodyFromStream(_ req: URLRequest) -> Data? {
                guard let stream = req.httpBodyStream else { return nil }
                stream.open()
                defer { stream.close() }
                var data = Data()
                let bufSize = 4096
                let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
                defer { buf.deallocate() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buf, maxLength: bufSize)
                    if read <= 0 { break }
                    data.append(buf, count: read)
                }
                return data
            }
        }
    }

#endif
