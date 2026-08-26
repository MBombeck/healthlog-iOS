import Foundation
@testable import HealthLog
import ModelsR4
import Testing

// swiftlint:disable force_unwrapping

/// **Audit v0162 H2 — ExportStore contract.**
///
/// Pins the store that now owns the repository/service calls + FHIR/export
/// artifact assembly the four PHI-export/import screens previously did inline.
/// Exercises the real `APIClient` with a stubbed `URLSession` (`MockURLProtocol`)
/// per the project doctrine (export paths must run the real request-building +
/// response-handling so schema drift surfaces — never a mock server).
@MainActor
@Suite("ExportStore", .serialized)
struct ExportStoreTests {
    private func makeAPI(keychain: InMemoryKeychain = InMemoryKeychain()) -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    /// A store with the labs + illness modules OFF so the FHIR-assembly path
    /// takes no network for those gated blocks (keeps the local-emitter tests
    /// hermetic).
    private func makeStore(
        api: APIClient,
        persistence: ExportPersistence = ExportPersistence()
    ) throws -> ExportStore {
        let outbox = try OutboxQueue(inMemory: true)
        let gate = ModuleGate(
            repo: ModuleGateRepository(api: api),
            modules: ["labs": false, "illness": false]
        )
        return ExportStore(api: api, outbox: outbox, moduleGate: gate, persistence: persistence)
    }

    private func emptySnapshot() -> DoctorReportSpecBuilder.Snapshot {
        DoctorReportSpecBuilder.Snapshot(
            patientName: "Test Patient",
            appVersion: "0.1.0 (1)",
            measurements: [],
            medications: [],
            compliance: [],
            intakes: [],
            moodEntries: []
        )
    }

    // MARK: - Full backup / domain CSV → service call + protected persist

    @Test("downloadFullBackup runs the service and persists a temp file")
    func fullBackupPersists() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            let http = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (http, Data(#"{"measurements":[]}"#.utf8))
        }
        let store = try makeStore(api: api)

        let url = try await store.downloadFullBackup(.json)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.lastPathComponent.hasPrefix("healthlog-export-"))
        #expect(url.pathExtension == "json")
    }

    @Test("downloadDomainCSV persists under the server-suggested filename")
    func domainCSVPersists() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            let http = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: nil,
                headerFields: [
                    "Content-Type": "text/csv",
                    "Content-Disposition": "attachment; filename=\"healthlog-mood-u1-2026-06-02.csv\""
                ]
            )!
            return (http, Data("date,value\n2026-06-02,72\n".utf8))
        }
        let store = try makeStore(api: api)

        let url = try await store.downloadDomainCSV(.mood)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(url.lastPathComponent == "healthlog-mood-u1-2026-06-02.csv")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("export errors surface (rate-limit) instead of a silent nil")
    func fullBackupRateLimitThrows() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            let http = HTTPURLResponse(
                url: req.url!, statusCode: 429, httpVersion: nil,
                headerFields: ["X-RateLimit-Reset": "2000-01-01T00:00:00Z"]
            )!
            return (http, Data())
        }
        let store = try makeStore(api: api)
        await #expect(throws: HLError.self) {
            _ = try await store.downloadFullBackup(.json)
        }
    }

    // MARK: - FHIR assembly

    @Test("makeLocalBundleJSON produces a non-empty, round-tripping bundle")
    func localBundleRoundTrips() throws {
        let now = Date(timeIntervalSince1970: 1_716_000_000)
        let json = try #require(
            ExportStore.makeLocalBundleJSON(
                periodDays: 90,
                snapshot: emptySnapshot(),
                generatedAt: now,
                labs: nil,
                illnesses: nil
            )
        )
        #expect(!json.isEmpty)
        let decoded = try JSONDecoder().decode(ModelsR4.Bundle.self, from: json)
        #expect(decoded.type.value != nil)
    }

    @Test("assembleFHIR uses the local emitter when the backend is unreachable")
    func assembleFHIRLocalWhenOffline() async throws {
        let api = makeAPI()
        let store = try makeStore(api: api)
        // isBackendReachable == false → preferred == .local, so no server call
        // and (labs/illness gated off) no network at all.
        let assembly = try #require(
            await store.assembleFHIR(
                periodDays: 90,
                snapshot: emptySnapshot(),
                generatedAt: Date(timeIntervalSince1970: 1_716_000_000),
                isBackendReachable: false
            ).assembly
        )
        #expect(assembly.source == .local)
        #expect(!assembly.json.isEmpty)
    }

    @Test("assembleFHIR falls back to local when the server $everything fetch fails")
    func assembleFHIRFallsBackOnServerError() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            // Any server-side failure on the `$everything` fetch must fall
            // through to the local emitter — the export never dead-ends.
            let http = HTTPURLResponse(
                url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil
            )!
            return (http, Data())
        }
        let store = try makeStore(api: api)
        let assembly = try #require(
            await store.assembleFHIR(
                periodDays: 90,
                snapshot: emptySnapshot(),
                generatedAt: Date(timeIntervalSince1970: 1_716_000_000),
                isBackendReachable: true
            ).assembly
        )
        #expect(assembly.source == .local)
        #expect(!assembly.json.isEmpty)
    }

    // MARK: - CU-13 — new route + the selection-scoped empty bundle

    /// Answers the two routes the server arm touches: the moved
    /// `Patient/$everything` and the saved-profile route CU-11 owns. Records
    /// every path so a request to the deleted route is visible.
    private func serverArmHandler(
        bundleJSON: String,
        profileJSON: String,
        record: @escaping @Sendable (String) -> Void
    ) -> @Sendable (URLRequest) -> (HTTPURLResponse, Data?) {
        { req in
            let path = req.url?.path ?? ""
            record(path)
            let body = path.hasPrefix("/api/auth/me/report-selection") ? profileJSON : bundleJSON
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(body.utf8))
        }
    }

    /// `nonisolated` — the handler closures read it off the MainActor.
    private nonisolated static let emptyBundleJSON =
        #"{"resourceType":"Bundle","type":"searchset","total":0}"#

    @Test("an empty server bundle with NO saved selection reports the actionable state")
    func emptyBundleWithoutSavedSelection() async throws {
        let api = makeAPI()
        nonisolated(unsafe) var paths: [String] = []
        MockURLProtocol.handler = serverArmHandler(
            bundleJSON: Self.emptyBundleJSON,
            // The honest "this account has never saved one" answer (CU-01).
            profileJSON: #"{"data":{"profile":null},"error":null}"#,
            record: { paths.append($0) }
        )
        let store = try makeStore(api: api)

        let outcome = await store.assembleFHIR(
            periodDays: 90,
            snapshot: emptySnapshot(),
            generatedAt: Date(timeIntervalSince1970: 1_716_000_000),
            isBackendReachable: true
        )

        // Not a silent empty export, and NOT a silent downgrade to the local
        // emitter either — the state is named so the screen can instruct.
        #expect(outcome == .empty(hasSavedSelection: false))
        // The hint is coupled to the real state: the saved-profile route was
        // actually asked, not guessed from the empty result.
        #expect(paths.contains("/api/auth/me/report-selection"))
        #expect(paths.contains("/api/fhir/Patient/$everything"))
        #expect(paths.contains("/api/fhir/$everything") == false)
    }

    @Test("an empty server bundle WITH a saved selection is a different honest state")
    func emptyBundleWithSavedSelection() async throws {
        let api = makeAPI()
        nonisolated(unsafe) var paths: [String] = []
        MockURLProtocol.handler = serverArmHandler(
            bundleJSON: Self.emptyBundleJSON,
            profileJSON: #"""
            {"data":{"profile":{"v":2,"leaves":["WEIGHT"],"format":"fhir",
            "rangeDays":90,"includeCharts":true}},"error":null}
            """#,
            record: { paths.append($0) }
        )
        let store = try makeStore(api: api)

        let outcome = await store.assembleFHIR(
            periodDays: 90,
            snapshot: emptySnapshot(),
            generatedAt: Date(timeIntervalSince1970: 1_716_000_000),
            isBackendReachable: true
        )
        #expect(outcome == .empty(hasSavedSelection: true))
    }

    @Test("a failed report-selection read never claims the user has no selection")
    func selectionReadFailureDoesNotAccuse() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            let isProfile = (req.url?.path ?? "").hasPrefix("/api/auth/me/report-selection")
            let http = HTTPURLResponse(
                url: req.url!,
                statusCode: isProfile ? 500 : 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (http, isProfile ? Data() : Data(Self.emptyBundleJSON.utf8))
        }
        let store = try makeStore(api: api)

        let outcome = await store.assembleFHIR(
            periodDays: 90,
            snapshot: emptySnapshot(),
            generatedAt: Date(timeIntervalSince1970: 1_716_000_000),
            isBackendReachable: true
        )
        // Sending someone to save a selection they may already have would be an
        // errand that fixes nothing — the unknown case takes the neutral wording.
        #expect(outcome == .empty(hasSavedSelection: true))
    }

    @Test("a non-empty server bundle is the server-sourced export, no profile read needed")
    func nonEmptyServerBundleAssembles() async throws {
        let api = makeAPI()
        nonisolated(unsafe) var paths: [String] = []
        MockURLProtocol.handler = serverArmHandler(
            bundleJSON: """
            {"resourceType":"Bundle","type":"searchset","total":1,\
            "entry":[{"resource":{"resourceType":"Patient"}}]}
            """,
            profileJSON: #"{"data":{"profile":null},"error":null}"#,
            record: { paths.append($0) }
        )
        let store = try makeStore(api: api)

        let assembly = try #require(
            await store.assembleFHIR(
                periodDays: 90,
                snapshot: emptySnapshot(),
                generatedAt: Date(timeIntervalSince1970: 1_716_000_000),
                isBackendReachable: true
            ).assembly
        )
        #expect(assembly.source == .server)
        #expect(!assembly.json.isEmpty)
        // No round-trip spent on the profile when the bundle carries data.
        #expect(paths.contains("/api/auth/me/report-selection") == false)
    }

    // MARK: - PHI write helpers

    @Test("writeData lands the FHIR bytes as a .fhir.json temp file")
    func writeDataUsesFhirExtension() throws {
        let now = Date(timeIntervalSince1970: 1_716_000_000)
        let url = try ExportStore.writeData(Data("{}".utf8), generatedAt: now)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.lastPathComponent.hasSuffix(".fhir.json"))
    }

    @Test("dayStamp renders a stable yyyy-MM-dd stamp")
    func dayStampFormat() {
        let stamp = ExportStore.dayStamp(Date(timeIntervalSince1970: 1_716_000_000))
        // 1_716_000_000 == 2024-05-18 (UTC).
        #expect(stamp == "2024-05-18")
    }

    // MARK: - Phase 09 / plan 09-03 — the write leaves the main actor

    /// **The counted contract.** A protected atomic write of a multi-megabyte
    /// PHI export is a blocking file operation; performed on the main actor it
    /// is a blocking file operation on the frame-producing thread. The counting
    /// writer records the originating thread of every write, so "the write left
    /// the main actor" is a census rather than a claim about a duration.
    ///
    /// Two payloads, 1 MiB and 250 MiB, because the property must not depend on
    /// the size — and because `Data(count:)` is calloc-backed, the 250 MiB
    /// fixture costs address space rather than resident memory: the counting
    /// writer reads its `count` and never touches its pages.
    @Test("large export persistence never runs on the main actor")
    func largePersistenceNeverRunsOnMainActor() async throws {
        let counting = Phase09CountingWriter()
        let store = try makeStore(
            api: makeAPI(),
            persistence: ExportPersistence(writer: counting.exportWriter)
        )
        let sizes = [1 << 20, 250 << 20]
        var urls: [URL] = []
        for size in sizes {
            try await urls.append(
                store.persistExport(
                    data: Data(count: size),
                    filename: "healthlog-export-09-03-\(size).json"
                )
            )
        }

        // The URL is published only after the bytes landed: one write per
        // payload, in order, at the exact byte count, under the exact options.
        #expect(counting.writeCount == 2)
        #expect(counting.writes.map(\.byteCount) == sizes)
        #expect(counting.writes.allSatisfy { $0.options.contains(.completeFileProtection) })
        #expect(counting.writes.allSatisfy { $0.options.contains(.atomic) })
        #expect(urls.map(\.lastPathComponent) == sizes.map { "healthlog-export-09-03-\($0).json" })

        #expect(
            counting.mainThreadWriteCount == 0,
            "EXPECTED_RED: export persistence ran on MainActor"
        )
    }

    /// The FHIR bundle takes the same boundary. Its write used to be the largest
    /// one still happening inline in a screen's `async` body.
    @Test("the FHIR bundle write also leaves the main actor, still fully protected")
    func fhirPersistenceNeverRunsOnMainActor() async throws {
        let counting = Phase09CountingWriter()
        let store = try makeStore(
            api: makeAPI(),
            persistence: ExportPersistence(writer: counting.exportWriter)
        )
        let url = try await store.persistFHIR(
            Data(count: 4 << 20),
            generatedAt: Date(timeIntervalSince1970: 1_716_000_000)
        )
        #expect(counting.writeCount == 1)
        #expect(counting.writes.first?.byteCount == 4 << 20)
        #expect(counting.writes.first?.options.contains(.completeFileProtection) == true)
        #expect(counting.mainThreadWriteCount == 0)
        #expect(url.lastPathComponent.hasSuffix(".fhir.json"))
    }

    /// **The publication check, and the trap under it.**
    ///
    /// A user who leaves the export surface mid-write must not be handed a share
    /// sheet afterwards, so the store re-checks cancellation between the write
    /// and the return. Proving that requires cancelling the work from outside
    /// it: cancelling from inside the case's own task would cancel *Swift
    /// Testing's* task, which the framework reports as a **skip** — a silently
    /// unchecked contract inside a green run (09-02's finding). The export
    /// therefore runs in its own unstructured `Task`, and the case asserts it is
    /// itself still uncancelled at the end so the trap cannot quietly reopen.
    @Test("a cancelled export writes its bytes but never publishes the URL")
    func cancelledExportDoesNotPublishItsURL() async throws {
        let counting = Phase09CountingWriter()
        let store = try makeStore(
            api: makeAPI(),
            persistence: ExportPersistence(writer: counting.exportWriter)
        )
        // `_Concurrency.Task` spelled in full: this file imports ModelsR4, whose
        // FHIR `Task` resource otherwise shadows the concurrency one.
        let work = _Concurrency.Task { @MainActor in
            try await store.persistExport(data: Data(count: 1 << 20), filename: "healthlog-export-cancel.json")
        }
        work.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await work.value
        }
        // The bytes did land — the check sits after the write, not instead of
        // it, so the file exists for the temp sweeper to collect rather than
        // half-written. This is a refusal to publish, not a failure to write.
        #expect(counting.writeCount == 1)
        #expect(counting.mainThreadWriteCount == 0)
        #expect(!_Concurrency.Task.isCancelled, "the cancellation must target the export, not the test")
    }

    /// The FHIR filename stamp had to stop being a shared `DateFormatter` so the
    /// write could run off the main actor without an unchecked-`Sendable` escape
    /// hatch. This pins that the replacement produces the same string the
    /// formatter did, at instants that exercise every padded field.
    @Test("the FHIR stamp matches the en_US_POSIX formatter it replaced")
    func fhirStampMatchesTheFormatterItReplaced() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let instants = [
            Date(timeIntervalSince1970: 0),
            Date(timeIntervalSince1970: 1_716_000_000),
            Date(timeIntervalSince1970: 1_767_225_599),
            Date(timeIntervalSince1970: 1_800_000_123)
        ]
        for instant in instants {
            #expect(ExportStore.fhirStamp(instant) == formatter.string(from: instant))
        }
    }
}

// swiftlint:enable force_unwrapping

private extension ExportStore.FHIRAssemblyOutcome {
    /// The assembled artifact, or `nil` for the two no-file outcomes — lets the
    /// existing cases keep their `#require` rhythm now that "no bundle" is a
    /// three-way answer.
    var assembly: ExportStore.FHIRAssembly? {
        guard case let .assembled(assembly) = self else { return nil }
        return assembly
    }
}
