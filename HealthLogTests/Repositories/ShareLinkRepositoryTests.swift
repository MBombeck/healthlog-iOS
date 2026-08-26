import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **v0.14.2 FW5-A — clinician share-link contract (server B1), extended by
/// CU-12 for server v1.32.39.**
///
/// Pins the create/list/revoke wire shapes against the *real* `APIClient` with a
/// stubbed `URLSession` (`MockURLProtocol`) — never a mock server (PROJECT_GUIDE.md) — so
/// schema drift surfaces. Covers:
///   - the `.strict()` create payload (exactly the allowed keys, no `userId`,
///     **no `resourceTypes` / `allowFhirApi`**, rolling window = explicit `null`
///     `rangeEnd`, and the v2 `selection` object),
///   - the create response decode incl. the one-time `token`,
///   - the list decode (token-less) incl. `needsReselection` / `documentOnly`,
///   - the `422 share-link.selection.*` mapping onto ``ShareLinkError``,
///   - the 404-revoke-as-success mapping,
///   - the share-token-never-logged guard (`LogSanitizer` redacts `hls_…`).
///
/// `.serialized` — every network case installs the process-global
/// `MockURLProtocol.handler`, which parallel cases would race on.
@Suite("ShareLinkRepository", .serialized)
struct ShareLinkRepositoryTests {
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

    // MARK: - Create payload (strict)

    @Test("CreateShareLinkBody encodes exactly the schema keys — no userId, rolling = null rangeEnd")
    func createBodyStrictEncode() throws {
        let body = CreateShareLinkBody(
            label: "Dr. Schmidt",
            rangeStart: "2026-03-01T00:00:00Z",
            rangeEnd: nil, // rolling
            expiresAt: "2026-07-01T00:00:00Z",
            selection: ReportSelection(leaves: ["WEIGHT", "LAB_RESULTS"])
        )
        let data = try JSONEncoder.hlDefault.encode(body)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // Exactly the always-present keys + the explicit-null rangeEnd.
        #expect(Set(json.keys) == ["label", "rangeStart", "expiresAt", "rangeEnd", "selection"])
        #expect(json["label"] as? String == "Dr. Schmidt")
        #expect(json["rangeStart"] as? String == "2026-03-01T00:00:00Z")
        #expect(json["expiresAt"] as? String == "2026-07-01T00:00:00Z")
        // rolling window → explicit JSON null (distinct from absent).
        #expect(json["rangeEnd"] is NSNull)
        // .strict() rejects userId — we must never emit it.
        #expect(json["userId"] == nil)
    }

    /// The CU-12 acceptance criterion, stated as a fixture: since server
    /// v1.32.39 both keys are refused on the request with a `422`, so they must
    /// not appear on the wire under **any** input — there is no longer an
    /// argument that could put them there.
    @Test("CU-12: the create body can never carry allowFhirApi or resourceTypes")
    func createBodyNeverCarriesRetiredFields() throws {
        for selection in [ReportSelection.empty, ReportSelection(leaves: ["MOOD"])] {
            let body = CreateShareLinkBody(
                label: "Cardiology",
                rangeStart: "2026-03-01T00:00:00Z",
                rangeEnd: "2026-06-01T00:00:00Z",
                expiresAt: "2026-07-01T00:00:00Z",
                selection: selection
            )
            let data = try JSONEncoder.hlDefault.encode(body)
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["allowFhirApi"] == nil)
            #expect(json["resourceTypes"] == nil)
            #expect(json["rangeEnd"] as? String == "2026-06-01T00:00:00Z")
        }
    }

    @Test("CU-12: selection rides as the v2 object { v: 2, leaves: [...] }")
    func createBodyCarriesSelection() throws {
        let body = CreateShareLinkBody(
            label: "Dr. Schmidt",
            rangeStart: "2026-03-01T00:00:00Z",
            rangeEnd: nil,
            expiresAt: "2026-07-01T00:00:00Z",
            selection: ReportSelection(leaves: ["WEIGHT", "LAB_RESULTS", "MEDICATION_LIST"])
        )
        let data = try JSONEncoder.hlDefault.encode(body)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let selection = try #require(json["selection"] as? [String: Any])
        #expect(Set(selection.keys) == ["v", "leaves"])
        #expect(selection["v"] as? Int == 2)
        #expect(selection["leaves"] as? [String] == ["WEIGHT", "LAB_RESULTS", "MEDICATION_LIST"])
    }

    /// An empty selection is legal on this route (the document-only link) — it
    /// must still ride as `[]`, never be omitted, because the schema requires
    /// the key and absence would read as a missing field rather than a chosen
    /// empty scope.
    @Test("CU-12: an empty selection encodes as leaves: [], not as an absent key")
    func createBodyEmptySelectionEncodesExplicitly() throws {
        let body = CreateShareLinkBody(
            label: "Documents only",
            rangeStart: "2026-03-01T00:00:00Z",
            rangeEnd: nil,
            expiresAt: "2026-07-01T00:00:00Z",
            selection: .empty
        )
        let data = try JSONEncoder.hlDefault.encode(body)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let selection = try #require(json["selection"] as? [String: Any])
        #expect(selection["leaves"] as? [String] == [])
    }

    // MARK: - Forbidden-leaf policy (INSURANCE never offered)

    @Test("CU-12: INSURANCE is filtered out of the offered vocabulary, everything else survives")
    func policyFiltersInsurance() {
        let live = ["WEIGHT", "PATIENT_IDENTITY", "INSURANCE", "LAB_RESULTS"]
        #expect(
            ShareLinkSelectionPolicy.offeredLeaves(from: live)
                == ["WEIGHT", "PATIENT_IDENTITY", "LAB_RESULTS"]
        )
    }

    @Test("CU-12: a selection carrying INSURANCE is caught before the request leaves")
    func policyDetectsForbiddenLeafPreFlight() {
        let selection = ReportSelection(leaves: ["WEIGHT", "INSURANCE"])
        #expect(ShareLinkSelectionPolicy.forbiddenLeaves(in: selection) == ["INSURANCE"])
        #expect(ShareLinkSelectionPolicy.forbiddenLeaves(in: ReportSelection(leaves: ["WEIGHT"])).isEmpty)
    }

    // MARK: - Create response decode (incl. token)

    @Test("create decodes the one-time hls_ token + posts to /api/share-links")
    func createDecodesToken() async throws {
        let api = makeAPI()
        let token = "hls_0123456789abcdef0123456789abcdef0123456789abcdef"
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            let payload = """
            {"data":{"id":"sl_1","label":"Dr. Schmidt","rangeStart":"2026-03-01T00:00:00Z",\
            "rangeEnd":null,"resourceTypes":[],"allowFhirApi":false,"expiresAt":"2026-07-01T00:00:00Z",\
            "createdAt":"2026-06-05T00:00:00Z","revokedAt":null,"lastAccessAt":null,"accessCount":0,\
            "active":true,"token":"\(token)"},"error":null}
            """
            let http = HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }

        let repo = ShareLinkRepository(api: api)
        let link = try await repo.create(
            CreateShareLinkBody(
                label: "Dr. Schmidt",
                rangeStart: "2026-03-01T00:00:00Z",
                rangeEnd: nil,
                expiresAt: "2026-07-01T00:00:00Z",
                selection: ReportSelection(leaves: ["WEIGHT"])
            )
        )

        #expect(capturedPath == "/api/share-links")
        #expect(capturedMethod == "POST")
        #expect(link.id == "sl_1")
        #expect(link.token == token)
        #expect(link.active == true)
    }

    // MARK: - Create response decode (passphrase-2FA, v1.18.7)

    @Test("create decodes passphrase + shareUrl + qrUrl + protected from the create response")
    func createDecodesPassphraseQR() async throws {
        let api = makeAPI()
        let token = "hls_0123456789abcdef0123456789abcdef0123456789abcdef"
        let passphrase = "ABCD-EFGH-IJKL-MNOP"
        let shareURL = "https://test.healthlog.local/c/\(token)"
        let qrURL = "\(shareURL)#k=\(passphrase)"
        MockURLProtocol.handler = { req in
            let payload = """
            {"data":{"id":"sl_2","label":"Dr. Protected","rangeStart":"2026-03-01T00:00:00Z",\
            "rangeEnd":null,"resourceTypes":[],"allowFhirApi":false,"expiresAt":"2026-07-01T00:00:00Z",\
            "createdAt":"2026-06-05T00:00:00Z","revokedAt":null,"lastAccessAt":null,"accessCount":0,\
            "active":true,"protected":true,"token":"\(token)","passphrase":"\(passphrase)",\
            "shareUrl":"\(shareURL)","qrUrl":"\(qrURL)"},"error":null}
            """
            let http = HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }

        let repo = ShareLinkRepository(api: api)
        let link = try await repo.create(
            CreateShareLinkBody(
                label: "Dr. Protected",
                rangeStart: "2026-03-01T00:00:00Z",
                rangeEnd: nil,
                expiresAt: "2026-07-01T00:00:00Z",
                selection: ReportSelection(leaves: ["WEIGHT"])
            )
        )

        #expect(link.protected == true)
        #expect(link.passphrase == passphrase)
        #expect(link.shareUrl == shareURL)
        #expect(link.qrUrl == qrURL)
    }

    @Test("legacy list rows decode protected == false and passphrase/qr == nil")
    func legacyRowDefaultsUnprotected() throws {
        let json = """
        {"id":"sl_old","label":"Legacy","rangeStart":"2026-03-01T00:00:00Z","rangeEnd":null,\
        "resourceTypes":[],"allowFhirApi":false,"expiresAt":"2026-07-01T00:00:00Z",\
        "createdAt":"2026-06-05T00:00:00Z","revokedAt":null,"lastAccessAt":null,"accessCount":0,"active":true}
        """
        let dto = try JSONDecoder().decode(ShareLinkDTO.self, from: Data(json.utf8))
        #expect(dto.protected == false)
        #expect(dto.passphrase == nil)
        #expect(dto.shareUrl == nil)
        #expect(dto.qrUrl == nil)
    }

    // MARK: - Retired links (migration 0275) + documentOnly

    /// The fixture the acceptance criterion names: a row the server retired
    /// during the v2-selection migration. Before CU-12 `needsReselection` was
    /// not decoded at all, so this row was indistinguishable from a live one.
    @Test("CU-12: a needsReselection row decodes as retired (and stays revoked)")
    func needsReselectionRowDecodes() throws {
        let json = """
        {"id":"sl_migrated","label":"Dr. Schmidt","rangeStart":"2026-01-01T00:00:00Z","rangeEnd":null,\
        "resourceTypes":[],"allowFhirApi":false,"expiresAt":"2026-09-01T00:00:00Z",\
        "createdAt":"2026-05-05T00:00:00Z","revokedAt":"2026-07-01T00:00:00Z","lastAccessAt":null,\
        "accessCount":4,"active":false,"needsReselection":true,"documentOnly":false}
        """
        let dto = try JSONDecoder().decode(ShareLinkDTO.self, from: Data(json.utf8))
        #expect(dto.needsReselection)
        #expect(!dto.active)
        #expect(dto.revokedAt != nil)
    }

    @Test("CU-12: documentOnly decodes (runtime-only key, absent from the OpenAPI schema)")
    func documentOnlyDecodes() throws {
        let json = """
        {"id":"sl_docs","label":"Documents","rangeStart":"2026-01-01T00:00:00Z","rangeEnd":null,\
        "expiresAt":"2026-09-01T00:00:00Z","createdAt":"2026-05-05T00:00:00Z","revokedAt":null,\
        "lastAccessAt":null,"accessCount":0,"active":true,"documentOnly":true}
        """
        let dto = try JSONDecoder().decode(ShareLinkDTO.self, from: Data(json.utf8))
        #expect(dto.documentOnly)
        #expect(!dto.needsReselection)
    }

    @Test("CU-12: a row from a server that sends neither flag decodes as false/false")
    func missingFlagsDefaultFalse() throws {
        let json = """
        {"id":"sl_old","label":"Legacy","rangeStart":"2026-03-01T00:00:00Z","rangeEnd":null,\
        "resourceTypes":[],"allowFhirApi":false,"expiresAt":"2026-07-01T00:00:00Z",\
        "createdAt":"2026-06-05T00:00:00Z","revokedAt":null,"lastAccessAt":null,"accessCount":0,"active":true}
        """
        let dto = try JSONDecoder().decode(ShareLinkDTO.self, from: Data(json.utf8))
        #expect(!dto.needsReselection)
        #expect(!dto.documentOnly)
    }

    // MARK: - Selection refusals (422 share-link.selection.*)

    /// The acceptance criterion's third leg. Without the mapping, `HLError`
    /// surfaces a 4xx message verbatim and the user reads the literal wire code.
    @Test("CU-12: 422 forbidden_leaf maps to ShareLinkError.forbiddenLeaf with readable copy")
    func forbiddenLeafMapsToTypedError() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            let payload = #"{"data":null,"error":"share-link.selection.forbidden_leaf"}"#
            let http = HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        let repo = ShareLinkRepository(api: api)
        await #expect(throws: ShareLinkError.forbiddenLeaf) {
            _ = try await repo.create(
                CreateShareLinkBody(
                    label: "Dr. Schmidt",
                    rangeStart: "2026-03-01T00:00:00Z",
                    rangeEnd: nil,
                    expiresAt: "2026-07-01T00:00:00Z",
                    selection: ReportSelection(leaves: ["INSURANCE"])
                )
            )
        }
        // Readable, and never the wire code.
        let copy = ShareLinkError.forbiddenLeaf.userFacingDescription
        #expect(!copy.contains("share-link.selection"))
        #expect(!copy.contains("forbidden_leaf"))
        #expect(copy.count > 20)
    }

    @Test("CU-12: another share-link.selection.* 422 maps to selectionRejected, still readable")
    func otherSelectionRefusalMapsToTypedError() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            let payload = #"{"data":null,"error":"share-link.selection.unknown_leaf"}"#
            let http = HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        let repo = ShareLinkRepository(api: api)
        await #expect(throws: ShareLinkError.selectionRejected) {
            _ = try await repo.create(
                CreateShareLinkBody(
                    label: "Dr. Schmidt",
                    rangeStart: "2026-03-01T00:00:00Z",
                    rangeEnd: nil,
                    expiresAt: "2026-07-01T00:00:00Z",
                    selection: ReportSelection(leaves: ["WHAT_IS_THIS"])
                )
            )
        }
        let copy = ShareLinkError.selectionRejected.userFacingDescription
        #expect(!copy.contains("share-link.selection"))
        #expect(copy.count > 20)
    }

    /// The mapping must not swallow unrelated failures — a rate limit stays a
    /// rate limit, a 422 about something else stays an `HLError`.
    @Test("CU-12: a 422 that is not about the selection passes through untouched")
    func unrelated422PassesThrough() async {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            let payload = #"{"data":null,"error":"Label must be 1–120 characters"}"#
            let http = HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        let repo = ShareLinkRepository(api: api)
        await #expect(throws: HLError.self) {
            _ = try await repo.create(
                CreateShareLinkBody(
                    label: "",
                    rangeStart: "2026-03-01T00:00:00Z",
                    rangeEnd: nil,
                    expiresAt: "2026-07-01T00:00:00Z",
                    selection: .empty
                )
            )
        }
    }

    // MARK: - QR code generation (deterministic)

    @Test("QRCodeImage.makeCGImage is deterministic — same qrUrl → non-nil CGImage of expected size")
    func qrCodeDeterministicNonNil() throws {
        let qrURL = "https://test.healthlog.local/c/hls_deadbeef#k=ABCD-EFGH-IJKL-MNOP"
        let a = try #require(QRCodeImage.makeCGImage(from: qrURL))
        let b = try #require(QRCodeImage.makeCGImage(from: qrURL))
        // Deterministic: identical payload → identical pixel dimensions.
        #expect(a.width == b.width)
        #expect(a.height == b.height)
        // A QR module grid is square and non-trivially sized after the 12x scale.
        #expect(a.width == a.height)
        #expect(a.width >= 100)
    }

    @Test("QRCodeImage.makeCGImage returns nil for an empty payload")
    func qrCodeEmptyPayloadNil() {
        #expect(QRCodeImage.makeCGImage(from: "") == nil)
    }

    // MARK: - List decode (token-less)

    @Test("list decodes data.shareLinks[] with token == nil")
    func listDecodesWithoutToken() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            let payload = """
            {"data":{"shareLinks":[{"id":"sl_1","label":"Dr. A","rangeStart":"2026-03-01T00:00:00Z",\
            "rangeEnd":null,"resourceTypes":["Observation"],"allowFhirApi":false,\
            "expiresAt":"2026-07-01T00:00:00Z","createdAt":"2026-06-05T00:00:00Z","revokedAt":null,\
            "lastAccessAt":null,"accessCount":3,"active":true}]},"error":null}
            """
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        let repo = ShareLinkRepository(api: api)
        let links = try await repo.list()
        #expect(links.count == 1)
        #expect(links[0].token == nil)
        #expect(links[0].accessCount == 3)
        #expect(links[0].resourceTypes == ["Observation"])
    }

    // MARK: - 404 revoke = success

    @Test("revoke maps a 404 (already revoked / gone) to success — no throw")
    func revoke404IsSuccess() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            let payload = #"{"data":null,"error":"Share link not found"}"#
            let http = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        let repo = ShareLinkRepository(api: api)
        // Must NOT throw — a re-revoke / unknown id is success-equivalent.
        try await repo.revoke(id: "sl_gone")
    }

    @Test("revoke surfaces a genuine non-404 server error")
    func revokeOtherErrorThrows() async {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            let payload = #"{"data":null,"error":"boom"}"#
            let http = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        let repo = ShareLinkRepository(api: api)
        await #expect(throws: HLError.self) {
            try await repo.revoke(id: "sl_1")
        }
    }

    // MARK: - Token never logged

    @Test("LogSanitizer redacts an hls_ share token so it never reaches the log sink")
    func tokenNeverLogged() {
        let token = "hls_0123456789abcdef0123456789abcdef0123456789abcdef"
        let line = "share-link created token=\(token) for user"
        let redacted = LogSanitizer.redact(line)
        #expect(!redacted.contains(token))
        #expect(!redacted.contains("0123456789abcdef0123456789abcdef"))
        #expect(redacted.contains("[redacted-token]"))
    }
}
