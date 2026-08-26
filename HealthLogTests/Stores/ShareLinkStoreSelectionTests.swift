// Diese Suite testet App-Target-Symbole, die in der SPM-Library nicht enthalten
// sind. SPM-Test-Build überspringt die Datei.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    // swiftlint:disable force_unwrapping

    /// **CU-12 — the two states the share-link surface was blind to.**
    ///
    /// Driven through the real ``ShareLinkStore`` over the real `APIClient` with a
    /// stubbed `URLSession` (`MockURLProtocol`), never a mock server. Two
    /// acceptance criteria live here:
    ///
    /// 1. a `needsReselection: true` row surfaces as a *retired* link — the state
    ///    the screen renders its honest "revoked during a server update" hint
    ///    from. Before CU-12 the flag was not decoded, so every dead link from
    ///    migration 0275 rendered as a normal one;
    /// 2. a `422 share-link.selection.forbidden_leaf` reaches the user as
    ///    readable copy rather than the raw wire code that `HLError`'s verbatim
    ///    4xx passthrough would otherwise show.
    ///
    /// `.serialized` — the cases share the process-global `MockURLProtocol.handler`.
    @MainActor
    @Suite("ShareLinkStore — retired links + selection refusals (CU-12)", .serialized)
    struct ShareLinkStoreSelectionTests {
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

        private func makeStore(api: APIClient) -> ShareLinkStore {
            ShareLinkStore(
                repo: ShareLinkRepository(api: api),
                capabilities: ServerCapabilitiesRepository(api: api)
            )
        }

        @Test("a needsReselection row lands in retiredLinks and out of activeLinks")
        func retiredLinkSurfaces() async {
            let api = makeAPI()
            MockURLProtocol.handler = { req in
                let payload = """
                {"data":{"shareLinks":[\
                {"id":"sl_dead","label":"Dr. Schmidt","rangeStart":"2026-01-01T00:00:00Z","rangeEnd":null,\
                "resourceTypes":[],"allowFhirApi":false,"expiresAt":"2026-09-01T00:00:00Z",\
                "createdAt":"2026-05-05T00:00:00Z","revokedAt":"2026-07-01T00:00:00Z","lastAccessAt":null,\
                "accessCount":2,"active":false,"needsReselection":true},\
                {"id":"sl_live","label":"Dr. Neu","rangeStart":"2026-06-01T00:00:00Z","rangeEnd":null,\
                "resourceTypes":[],"allowFhirApi":false,"expiresAt":"2026-09-01T00:00:00Z",\
                "createdAt":"2026-07-05T00:00:00Z","revokedAt":null,"lastAccessAt":null,\
                "accessCount":0,"active":true,"needsReselection":false}]},"error":null}
                """
                let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (http, Data(payload.utf8))
            }

            let store = makeStore(api: api)
            await store.load()

            #expect(store.links.count == 2)
            #expect(store.retiredLinks.map(\.id) == ["sl_dead"])
            // The dead one must not masquerade as usable.
            #expect(store.activeLinks.map(\.id) == ["sl_live"])
            #expect(store.error == nil)
        }

        @Test("no retired rows → no hint state at all")
        func noRetiredLinksWhenServerSendsNone() async {
            let api = makeAPI()
            MockURLProtocol.handler = { req in
                let payload = """
                {"data":{"shareLinks":[\
                {"id":"sl_live","label":"Dr. Neu","rangeStart":"2026-06-01T00:00:00Z","rangeEnd":null,\
                "expiresAt":"2026-09-01T00:00:00Z","createdAt":"2026-07-05T00:00:00Z","revokedAt":null,\
                "lastAccessAt":null,"accessCount":0,"active":true}]},"error":null}
                """
                let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (http, Data(payload.utf8))
            }

            let store = makeStore(api: api)
            await store.load()
            #expect(store.retiredLinks.isEmpty)
        }

        @Test("a forbidden-leaf 422 becomes readable copy, not the wire code")
        func forbiddenLeafSurfacesReadableCopy() async {
            let api = makeAPI()
            MockURLProtocol.handler = { req in
                let payload = #"{"data":null,"error":"share-link.selection.forbidden_leaf"}"#
                let http = HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!
                return (http, Data(payload.utf8))
            }

            let store = makeStore(api: api)
            let ok = await store.create(
                CreateShareLinkBody(
                    label: "Dr. Schmidt",
                    rangeStart: "2026-03-01T00:00:00Z",
                    rangeEnd: nil,
                    expiresAt: "2026-09-01T00:00:00Z",
                    selection: ReportSelection(leaves: ["INSURANCE"])
                )
            )

            #expect(!ok)
            let shown = store.error ?? ""
            #expect(!shown.contains("share-link.selection.forbidden_leaf"))
            #expect(!shown.contains("forbidden_leaf"))
            #expect(shown == ShareLinkError.forbiddenLeaf.userFacingDescription)
        }

        // MARK: - Live vocabulary

        @Test("the offered vocabulary comes from capabilities.share.leaves, minus INSURANCE")
        func vocabularyComesFromCapabilitiesMinusForbidden() async {
            let api = makeAPI()
            MockURLProtocol.handler = { req in
                let payload = """
                {"data":{"apiContractVersion":"1.34.2","share":{"supported":true,"maxDays":90,\
                "reportDownload":["fhir","pdf"],"selectionVersion":2,"groups":["VITALS","REPORT"],\
                "leaves":["WEIGHT","PATIENT_IDENTITY","INSURANCE","LAB_RESULTS"]}},"error":null}
                """
                let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (http, Data(payload.utf8))
            }

            let store = makeStore(api: api)
            await store.loadSelectionVocabulary()

            #expect(store.hasSelectionVocabulary)
            #expect(store.offeredLeaves == ["WEIGHT", "PATIENT_IDENTITY", "LAB_RESULTS"])
            // Validation still knows INSURANCE exists — the vocabulary is the
            // server's, only the *offer* is narrowed.
            #expect(store.leafVocabulary.contains("INSURANCE"))
        }

        @Test("a capabilities failure leaves the picker honestly unavailable — never a local fallback")
        func vocabularyFailureDegradesHonestly() async {
            let api = makeAPI()
            MockURLProtocol.handler = { req in
                let payload = #"{"data":null,"error":"boom"}"#
                let http = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (http, Data(payload.utf8))
            }

            let store = makeStore(api: api)
            await store.loadSelectionVocabulary()

            #expect(!store.hasSelectionVocabulary)
            #expect(store.offeredLeaves.isEmpty)
            #expect(store.leafVocabulary.isEmpty)
            // A vocabulary failure is not a banner — the list stays usable.
            #expect(store.error == nil)
        }

        @Test("an old server without a v2 vocabulary is treated as unusable, not as empty")
        func staleSelectionVersionIsUnusable() async {
            let api = makeAPI()
            MockURLProtocol.handler = { req in
                let payload = """
                {"data":{"apiContractVersion":"1.30.0","share":{"supported":true,"maxDays":90,\
                "selectionVersion":1,"leaves":["WEIGHT"]}},"error":null}
                """
                let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (http, Data(payload.utf8))
            }

            let store = makeStore(api: api)
            await store.loadSelectionVocabulary()
            #expect(!store.hasSelectionVocabulary)
        }
    }

    // swiftlint:enable force_unwrapping

#endif
