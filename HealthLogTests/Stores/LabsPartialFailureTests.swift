// 14-03 (E1, iOS half) — one failing subrequest may not blank the other's success.
//
// `LabsStore.load()` fans out `GET /api/labs` and `GET /api/biomarkers` and then
// awaits them as ONE tuple. A throw from either half jumps out of the `do`
// block, so a failed biomarker CATALOG discards a perfectly good labs result and
// the screen falls through to its error phase with no rows — the #67 symptom the
// dashboard was taught to survive and the Labs screen never was.
//
// Drives the REAL store over the REAL `APIClient` on a session-scoped
// `MockURLProtocolSession` (09-13). 13-03's unconditional `defer` on this store
// is adjacency, not subject: every case here also asserts the flags came down.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @Suite("Labs partial failure (14-03)", .serialized)
    @MainActor
    struct LabsPartialFailureTests {
        private nonisolated static let owner = "owner-labs"

        private func makeAPI(_ session: MockURLProtocolSession) -> APIClient {
            let keychain = InMemoryKeychain()
            try? keychain.setString("token", forKey: KeychainKey.authToken)
            let environment = AppEnvironment(
                baseURL: session.baseURL,
                bundleID: "dev.healthlog.app",
                appVersion: "0.19.0",
                buildNumber: "1"
            )
            return APIClient(
                environment: environment,
                keychain: keychain,
                sessionConfiguration: session.configuration
            )
        }

        private func makeStore(_ session: MockURLProtocolSession) throws -> LabsStore {
            let repository = try LabsRepository(
                api: makeAPI(session),
                outbox: OutboxQueue(inMemory: true)
            )
            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.owner)
            let store = LabsStore(repository: repository)
            store.bindAuthenticatedSessionRegistry(registry, ownerIDProvider: { Self.owner })
            return store
        }

        private nonisolated static let labsBody = Data(#"""
        {"data":{"results":[{"id":"lab_1","biomarkerId":null,"panel":"Blutbild","analyte":"Ferritin",
        "value":142.0,"unit":"ng/ml","referenceLow":30.0,"referenceHigh":300.0,
        "takenAt":"2026-08-01T08:00:00Z","source":"MANUAL","hasNote":false,"rangeStatus":"NORMAL",
        "createdAt":"2026-08-01T08:00:00Z","updatedAt":"2026-08-01T08:00:00Z"}],"meta":{"total":1}}}
        """#.utf8)

        private nonisolated static let catalogBody = Data(#"""
        {"data":{"biomarkers":[{"id":"bm_1","name":"Ferritin","unit":"ng/ml",
        "lowerBound":30.0,"upperBound":300.0,"panel":"Blutbild","hasContext":false,"context":null,
        "hidden":false,"createdAt":"2026-08-01T08:00:00Z","updatedAt":"2026-08-01T08:00:00Z"}]}}
        """#.utf8)

        /// Answers `/api/labs` and `/api/biomarkers` with the given status each.
        private func install(
            _ session: MockURLProtocolSession,
            labsStatus: Int,
            catalogStatus: Int
        ) {
            let labs = Self.labsBody
            let catalog = Self.catalogBody
            session.install { request in
                let path = request.url?.path ?? ""
                let isCatalog = path.hasPrefix("/api/biomarkers")
                let status = isCatalog ? catalogStatus : labsStatus
                let headers = ["Content-Type": "application/json"]
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                )!
                if status != 200 {
                    return (response, Data(#"{"data":null,"error":"boom"}"#.utf8))
                }
                return (response, isCatalog ? catalog : labs)
            }
        }

        // MARK: - 1) the catalog may not take the labs down with it

        @Test("Ein fehlgeschlagener Biomarker-Katalog verwirft die Laborwerte nicht")
        func biomarkerFailureKeepsLabs() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            install(session, labsStatus: 200, catalogStatus: 500)
            let store = try makeStore(session)

            await store.load()

            #expect(
                store.labs.count == 1,
                "EXPECTED_RED: a failed biomarker catalog discards the successful labs result"
            )
            #expect(store.labs.first?.analyte == "Ferritin")
            #expect(store.total == 1)
            // The failed half states its own failure, in its own slot — NOT in
            // `lastError`, which is what `LabsScreen.phase` reads to decide the
            // whole surface failed.
            #expect(store.biomarkers.isEmpty)
            #expect(store.biomarkerCatalogError != nil, "the catalogue states its own failure")
            #expect(store.lastError == nil, "a catalogue hiccup is not a labs failure")
            #expect(store.isDisabled == false)
            // 13-03 adjacency: the flags came down on this path too.
            #expect(store.isLoading == false)
        }

        // MARK: - 1b) the retry can end the statement

        /// The screen offers a retry that re-runs only the half that failed.
        /// It has to be able to clear the statement it retries.
        @Test("Ein erfolgreicher Katalog-Retry beendet die Aussage")
        func aSuccessfulCatalogRetryClearsTheStatement() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            install(session, labsStatus: 200, catalogStatus: 500)
            let store = try makeStore(session)

            await store.load()
            #expect(store.biomarkerCatalogError != nil)
            #expect(store.labs.count == 1)

            install(session, labsStatus: 200, catalogStatus: 200)
            await store.reloadBiomarkers()

            #expect(store.biomarkerCatalogError == nil)
            #expect(store.biomarkers.count == 1)
            #expect(store.labs.count == 1, "the healthy half was never disturbed")
        }

        // MARK: - 2) the inverse fails honestly

        @Test("Ein Labs-Fehler erfindet keine Zeilen aus dem Katalog")
        func labsFailureStatesItselfWithoutPhantomRows() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            install(session, labsStatus: 500, catalogStatus: 200)
            let store = try makeStore(session)

            await store.load()

            #expect(store.labs.isEmpty, "a catalog is not data")
            #expect(store.lastError != nil, "the labs half states its failure")
            #expect(store.isLoading == false)
        }

        // MARK: - 3) controls — both good, both bad

        @Test("Beide Hälften gesund: unveränderte Vollansicht")
        func bothHalvesRenderUnchanged() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            install(session, labsStatus: 200, catalogStatus: 200)
            let store = try makeStore(session)

            await store.load()

            #expect(store.labs.count == 1)
            #expect(store.biomarkers.count == 1)
            #expect(store.lastError == nil)
            #expect(store.biomarkerCatalogError == nil)
            #expect(store.isDisabled == false)
            #expect(store.isLoading == false)
        }

        @Test("Beide Hälften kaputt: der bestehende Vollfehlerpfad bleibt")
        func bothHalvesFailingKeepsTheFullFailurePath() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            install(session, labsStatus: 500, catalogStatus: 500)
            let store = try makeStore(session)

            await store.load()

            #expect(store.labs.isEmpty)
            #expect(store.biomarkers.isEmpty)
            #expect(store.lastError != nil)
            #expect(store.isLoading == false)
        }
    }

#endif
