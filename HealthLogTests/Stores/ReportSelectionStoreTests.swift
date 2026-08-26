import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Wire fixtures, deliberately **outside** the `@MainActor` suite so the
/// `@Sendable` `MockURLProtocol` handler can build responses without hopping
/// actors. The leaf ids here are a TEST vocabulary; production never carries a
/// list like this — it reads `capabilities.share.leaves`.
private enum Fixtures {
    static let leaves = ["WEIGHT", "PULSE", "LAB_RESULTS", "MEDICATION_LIST", "MOOD"]
    static let groups = ["vitals", "labs", "medications", "sensitive"]

    static func capabilitiesJSON(
        leaves: [String] = Fixtures.leaves,
        selectionVersion: Int = 2
    ) -> String {
        let leafList = leaves.map { "\"\($0)\"" }.joined(separator: ",")
        let groupList = groups.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"apiContractVersion":"1.34.2",
         "share":{"supported":true,"maxDays":90,"reportDownload":["fhir","pdf"],
                  "selectionVersion":\(selectionVersion),
                  "groups":[\(groupList)],"leaves":[\(leafList)]}}
        """
    }

    static func profileJSON(
        leaves: [String],
        format: String = "pdf",
        rangeDays: Int = 180,
        includeCharts: Bool = false
    ) -> String {
        let leafList = leaves.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"profile":{"v":2,"leaves":[\(leafList)],"format":"\(format)",
                    "rangeDays":\(rangeDays),"includeCharts":\(includeCharts)}}
        """
    }

    /// URLProtocol moves `httpBody` onto `httpBodyStream`; re-materialize either.
    static func body(of req: URLRequest) -> Data {
        req.httpBody ?? req.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            let size = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: size)
                if read <= 0 { break }
                data.append(buf, count: read)
            }
            return data
        } ?? Data()
    }

    static func ok(_ req: URLRequest, _ json: String) -> (HTTPURLResponse, Data?) {
        let http = HTTPURLResponse(
            url: req.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (http, Data(json.utf8))
    }
}

/// **CU-11 — the report-selection panel's state.**
///
/// Drives the real ``ServerCapabilitiesRepository`` / ``ReportSelectionRepository``
/// over the real `APIClient` with a stubbed `URLSession` (`MockURLProtocol`) —
/// never a mock server (PROJECT_GUIDE.md). `.serialized` because the handler is
/// process-global and every assertion here depends on it answering only this
/// suite's requests.
///
/// What is locked down:
///   - the vocabulary is read from `capabilities.share.leaves` and **never**
///     invented locally: an empty/`selectionVersion`-mismatched payload makes
///     the panel unavailable rather than falling back to a list,
///   - `profile: null` is the honest "never saved" state (nothing pre-chosen),
///   - the saved-profile round-trip sends exactly the five documented fields,
///   - an empty selection is a legal, non-error state,
///   - `422 export.selection.unknown_leaf` rebuilds the scope from a fresh
///     capabilities read and narrows — never widens — it.
@Suite("ReportSelectionStore", .serialized)
@MainActor
struct ReportSelectionStoreTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private func makeStore(_ api: APIClient) -> ReportSelectionStore {
        ReportSelectionStore(
            capabilities: ServerCapabilitiesRepository(api: api),
            profiles: ReportSelectionRepository(api: api)
        )
    }

    // MARK: - Loading

    @Test("load reads the vocabulary live and adopts the saved profile")
    func loadAdoptsProfile() async {
        MockURLProtocol.handler = { req in
            if req.url?.path == "/api/meta/capabilities" {
                return Fixtures.ok(req, Fixtures.capabilitiesJSON())
            }
            return Fixtures.ok(req, Fixtures.profileJSON(leaves: ["PULSE", "LAB_RESULTS"]))
        }

        let store = makeStore(makeAPI())
        await store.loadIfNeeded()

        #expect(store.phase == .ready)
        #expect(store.vocabulary == Fixtures.leaves)
        #expect(store.groups == Fixtures.groups)
        #expect(store.chosen == ["PULSE", "LAB_RESULTS"])
        #expect(store.hasSavedProfile)
        // The presentation half of the profile rides along.
        #expect(store.format == .pdf)
        #expect(store.rangeDays == 180)
        #expect(store.includeCharts == false)
        #expect(store.notice == nil)
        // Ordered by the SERVER's catalogue order, not the profile's.
        #expect(store.currentSelection.leaves == ["PULSE", "LAB_RESULTS"])
    }

    @Test("profile: null is 'never saved' — nothing is pre-chosen for the user")
    func nullProfileChoosesNothing() async {
        MockURLProtocol.handler = { req in
            if req.url?.path == "/api/meta/capabilities" {
                return Fixtures.ok(req, Fixtures.capabilitiesJSON())
            }
            return Fixtures.ok(req, #"{"profile":null}"#)
        }

        let store = makeStore(makeAPI())
        await store.loadIfNeeded()

        #expect(store.phase == .ready)
        #expect(store.chosen.isEmpty)
        #expect(store.hasSavedProfile == false)
        // Legal, and explicitly not an error.
        #expect(store.currentSelection.leaves.isEmpty)
        #expect(store.resolvedSelection == ReportSelection.empty)
    }

    @Test("a saved leaf this build's server no longer serves is dropped, and said so")
    func retiredLeafIsDropped() async {
        MockURLProtocol.handler = { req in
            if req.url?.path == "/api/meta/capabilities" {
                return Fixtures.ok(req, Fixtures.capabilitiesJSON())
            }
            return Fixtures.ok(req, Fixtures.profileJSON(leaves: ["PULSE", "RETIRED_LEAF"]))
        }

        let store = makeStore(makeAPI())
        await store.loadIfNeeded()

        #expect(store.chosen == ["PULSE"])
        #expect(store.notice == .droppedRetiredLeaves(count: 1))
    }

    @Test("no vocabulary → unavailable, and NOT a locally invented list")
    func noVocabularyIsUnavailable() async {
        MockURLProtocol.handler = { req in
            if req.url?.path == "/api/meta/capabilities" {
                return Fixtures.ok(req, Fixtures.capabilitiesJSON(leaves: []))
            }
            return Fixtures.ok(req, #"{"profile":null}"#)
        }

        let store = makeStore(makeAPI())
        await store.loadIfNeeded()

        #expect(store.phase == .unavailable(.noVocabulary))
        #expect(store.vocabulary.isEmpty)
        #expect(store.resolvedSelection == nil)
    }

    @Test("a vocabulary at a grammar version this build does not speak is refused")
    func versionMismatchIsUnavailable() async {
        MockURLProtocol.handler = { req in
            if req.url?.path == "/api/meta/capabilities" {
                return Fixtures.ok(req, Fixtures.capabilitiesJSON(selectionVersion: 3))
            }
            return Fixtures.ok(req, #"{"profile":null}"#)
        }

        let store = makeStore(makeAPI())
        await store.loadIfNeeded()

        #expect(store.phase == .unavailable(.noVocabulary))
    }

    @Test("a capabilities failure is surfaced, not papered over")
    func capabilitiesFailureIsSurfaced() async {
        MockURLProtocol.handler = { req in
            let http = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (http, Data("{}".utf8))
        }

        let store = makeStore(makeAPI())
        await store.loadIfNeeded()

        guard case .unavailable(.loadFailed) = store.phase else {
            Issue.record("expected .unavailable(.loadFailed), got \(store.phase)")
            return
        }
        #expect(store.resolvedSelection == nil)
    }

    // MARK: - Editing

    @Test("clear-all, and toggling only ever admits a live leaf")
    func editing() async {
        MockURLProtocol.handler = { req in
            if req.url?.path == "/api/meta/capabilities" {
                return Fixtures.ok(req, Fixtures.capabilitiesJSON())
            }
            return Fixtures.ok(req, #"{"profile":null}"#)
        }

        let store = makeStore(makeAPI())
        await store.loadIfNeeded()

        store.choose(Fixtures.leaves)
        #expect(store.currentSelection.leaves == Fixtures.leaves)

        // The only bulk control narrows; there is no blanket bulk-on, because
        // the sensitive tier must never ride along on a single tap.
        store.selectNone()
        #expect(store.currentSelection.leaves.isEmpty)

        store.toggle("MOOD")
        #expect(store.isChosen("MOOD"))
        store.toggle("MOOD")
        #expect(store.isChosen("MOOD") == false)

        // An id outside the live vocabulary can never enter the selection —
        // neither by toggle nor by restore.
        store.toggle("NOT_A_LEAF")
        #expect(store.chosen.isEmpty)
        store.choose(["NOT_A_LEAF", "PULSE"])
        #expect(store.chosen == ["PULSE"])
    }

    // MARK: - Saved-profile round trip

    @Test("save PUTs exactly the five documented fields and adopts the server echo")
    func saveRoundTrip() async throws {
        nonisolated(unsafe) var putBody: Data?
        nonisolated(unsafe) var putMethod: String?
        MockURLProtocol.handler = { req in
            if req.url?.path == "/api/meta/capabilities" {
                return Fixtures.ok(req, Fixtures.capabilitiesJSON())
            }
            if req.httpMethod == "PUT" {
                putMethod = req.httpMethod
                putBody = Fixtures.body(of: req)
                // The server persists CATALOGUE ordering, not the caller's.
                return Fixtures.ok(req, Fixtures.profileJSON(
                    leaves: ["PULSE", "LAB_RESULTS"],
                    format: "package",
                    rangeDays: 365,
                    includeCharts: true
                ))
            }
            return Fixtures.ok(req, #"{"profile":null}"#)
        }

        let store = makeStore(makeAPI())
        await store.loadIfNeeded()
        store.toggle("LAB_RESULTS")
        store.toggle("PULSE")
        store.format = .package
        store.rangeDays = 365
        store.includeCharts = true
        await store.save()

        #expect(putMethod == "PUT")
        let json = try #require(
            JSONSerialization.jsonObject(with: putBody ?? Data()) as? [String: Any]
        )
        #expect(Set(json.keys) == ["v", "leaves", "format", "rangeDays", "includeCharts"])
        #expect(json["v"] as? Int == 2)
        #expect(json["leaves"] as? [String] == ["PULSE", "LAB_RESULTS"])
        #expect(json["format"] as? String == "package")
        #expect(json["rangeDays"] as? Int == 365)
        #expect(json["includeCharts"] as? Bool == true)

        // The echo is adopted — the store now mirrors what the server stored.
        #expect(store.saveError == nil)
        #expect(store.hasSavedProfile)
        #expect(store.chosen == ["PULSE", "LAB_RESULTS"])
        #expect(store.format == .package)
        #expect(store.rangeDays == 365)
        #expect(store.includeCharts == true)
    }

    @Test("saving an empty selection is a legal write, not an error")
    func saveEmptySelection() async throws {
        nonisolated(unsafe) var putBody: Data?
        MockURLProtocol.handler = { req in
            if req.url?.path == "/api/meta/capabilities" {
                return Fixtures.ok(req, Fixtures.capabilitiesJSON())
            }
            if req.httpMethod == "PUT" {
                putBody = Fixtures.body(of: req)
                return Fixtures.ok(req, Fixtures.profileJSON(leaves: []))
            }
            return Fixtures.ok(req, #"{"profile":null}"#)
        }

        let store = makeStore(makeAPI())
        await store.loadIfNeeded()
        store.selectNone()
        await store.save()

        let json = try #require(
            JSONSerialization.jsonObject(with: putBody ?? Data()) as? [String: Any]
        )
        #expect((json["leaves"] as? [String])?.isEmpty == true)
        #expect(store.saveError == nil)
        #expect(store.phase == .ready)
    }

    // MARK: - 422 recovery

    @Test("422 export.selection.unknown_leaf rebuilds the scope from fresh capabilities")
    func unknownLeafRebuild() async {
        // The second capabilities read no longer serves MOOD — the rebuild must
        // narrow to the fresh list and never widen back.
        nonisolated(unsafe) var capabilitiesHits = 0
        MockURLProtocol.handler = { req in
            if req.url?.path == "/api/meta/capabilities" {
                capabilitiesHits += 1
                let leaves = capabilitiesHits == 1
                    ? Fixtures.leaves
                    : Fixtures.leaves.filter { $0 != "MOOD" }
                return Fixtures.ok(req, Fixtures.capabilitiesJSON(leaves: leaves))
            }
            return Fixtures.ok(req, #"{"profile":null}"#)
        }

        let store = makeStore(makeAPI())
        await store.loadIfNeeded()
        store.choose(Fixtures.leaves)
        #expect(store.isChosen("MOOD"))

        let handled = await store.handleExportFailure(HealthRecordExportError.unknownLeaf)

        #expect(handled)
        #expect(capabilitiesHits == 2)
        #expect(store.phase == .ready)
        #expect(store.notice == .rebuiltFromCapabilities)
        #expect(store.isChosen("MOOD") == false)
        #expect(store.currentSelection.leaves == Fixtures.leaves.filter { $0 != "MOOD" })
    }

    @Test("an unrelated failure is not claimed as a selection problem")
    func unrelatedFailureIsNotHandled() async {
        MockURLProtocol.handler = { req in
            if req.url?.path == "/api/meta/capabilities" {
                return Fixtures.ok(req, Fixtures.capabilitiesJSON())
            }
            return Fixtures.ok(req, #"{"profile":null}"#)
        }

        let store = makeStore(makeAPI())
        await store.loadIfNeeded()
        store.choose(Fixtures.leaves)

        let handled = await store.handleExportFailure(
            HLError.server(status: 429, code: nil, message: "Too many requests")
        )

        #expect(handled == false)
        #expect(store.notice == nil)
        #expect(store.currentSelection.leaves == Fixtures.leaves)
    }
}

// swiftlint:enable force_unwrapping
