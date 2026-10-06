import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **Server v1.39.2 — the digest rail, the hero-kind list and the additive
/// fields**, against the real `APIClient` over the per-test mock session.
///
/// Wire shapes follow `docs/api/openapi.yaml` and the server code at the tag
/// `v1.39.2`: `buildPreventiveCareItem` / `buildUpcomingVisitItems`
/// (`src/lib/daily/digest.ts`) with the English bundle strings, the resolved
/// `DashboardLayout` (`coerceEnabledHeroItemKinds`, nine kinds with
/// `upcoming_visit`), `IllnessEpisode` with `bodySite` / `laterality`, and
/// `InboundDocument` with `sourceSystem` / `sourceId`. The illness PATCH body is
/// the one the server's own `body-site.test.ts` pins as "the shipped iPhone
/// app".
@Suite("Server v1.39.2 contract", .serialized, .mockURLSession)
struct ServerV1392ContractTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.1.0",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    private static func ok(_ request: URLRequest, _ json: String, status: Int = 200) -> (HTTPURLResponse, Data?) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
    }

    /// URLProtocol moves `httpBody` onto `httpBodyStream`; read either.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private final class BodyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Data?
        var value: Data? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                stored = newValue
            }
        }
    }

    // MARK: - Digest rail

    private static let checkupAction =
        #"{"labelKey":"daily.action.viewCheckups","intent":"checkup.view","href":"/checkups"}"#

    private static let digestJSON = """
    {"data":{"generatedAt":"2026-09-26T08:00:00.000Z","phase":"final","sleepPending":false,
     "score":{"value":74,"band":"green","delta":1.5,"configured":false},"topSignal":null,
     "briefingLead":null,"line":"A steady day so far.",
     "worthALook":[
      {"kind":"preventive_care","title":"Check-up due","body":"Due: Dentist, Skin check, Eye exam +2",
       "status":"info","actions":[\(checkupAction)]},
      {"kind":"upcoming_visit","title":"Appointment coming up","body":"Dr. Weber — today",
       "status":"info","actions":[\(checkupAction)]},
      {"kind":"upcoming_visit","title":"Appointment coming up","body":"Routine check-up — tomorrow",
       "status":"info","actions":[\(checkupAction)]}
     ],
     "ai":{"briefing":{"available":true,"reason":null,"onDeviceAllowed":true},
           "coach":{"available":true,"reason":null,"onDeviceAllowed":true},
           "reactionLines":{"available":true,"reason":null,"onDeviceAllowed":true}}},
     "error":null}
    """

    @Test("preventive_care names several check-ups verbatim; two upcoming_visit items both stay on the rail")
    func digestRailV1392() async throws {
        MockURLProtocol.install { req in
            #expect(req.url?.path == "/api/daily/digest")
            return Self.ok(req, Self.digestJSON)
        }
        let digest = try #require(try await DailyDigestRepository(api: makeAPI()).fetch())

        let rail = digest.rail
        #expect(rail.map(\.kind) == ["preventive_care", "upcoming_visit", "upcoming_visit"])
        #expect(rail[0].body == "Due: Dentist, Skin check, Eye exam +2")
        #expect(rail[0].kindToken == .preventiveCare)
        #expect(rail[1].body == "Dr. Weber — today")
        #expect(rail[2].body == "Routine check-up — tomorrow")
        // A visit renders without a kind icon, is not dismissible, and keeps its
        // one action (the rail is keyed by position, so two items of one kind
        // are two cards).
        #expect(rail[1].kindToken == nil)
        #expect(!rail[1].isDismissible)
        #expect(rail[1].boundedActions.map(\.intent) == ["checkup.view"])
    }

    // MARK: - Hero-kind list

    @Test("a stored hero-kind list with upcoming_visit keeps it through a picker save")
    func heroKindsKeepUpcomingVisit() throws {
        // What `GET /api/dashboard/widgets` answers after migration 0355 appended
        // the kind: the resolved list in catalogue order, all nine kinds.
        let json = #"""
        {"version":1,"widgets":[],"enabledHeroItemKinds":["coach_checkin","dose_window","preventive_care",
         "sync_issue","milestone","ecg_new_recording","tension_window","same_time_baseline","upcoming_visit"]}
        """#
        let stored = try JSONDecoder.hlDefault.decode(DashboardWidgetLayout.self, from: Data(json.utf8))
        #expect(stored.resolvedEnabledHeroItemKinds == HeroItemKind.allCases)

        let next = stored.settingEnabledHeroItemKinds(HeroItemKind.allCases.filter { $0 != .milestone })
        let body = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder.hlDefault.encode(next)) as? [String: Any]
        )
        let sent = try #require(body["enabledHeroItemKinds"] as? [String])
        #expect(sent.contains("upcoming_visit"))
        #expect(!sent.contains("milestone"))
    }

    // MARK: - Illness body site

    private static func episodeJSON(label: String) -> String {
        """
        {"id":"ep-1","label":"\(label)","type":"INJURY","lifecycle":"ACUTE",
         "onsetAt":"2026-06-01T00:00:00.000Z","resolvedAt":null,"parentConditionId":null,
         "note":"Physio twice a week","bodySite":"Knee","laterality":"LEFT",
         "createdAt":"2026-06-01T00:00:00.000Z","updatedAt":"2026-09-26T08:00:00.000Z"}
        """
    }

    @Test("an episode with bodySite/laterality decodes, and the app's edit body never names them")
    func illnessEditLeavesBodySiteAlone() async throws {
        let captured = BodyBox()
        MockURLProtocol.install { req in
            #expect(req.httpMethod == "PATCH")
            #expect(req.url?.path == "/api/illness/episodes/ep-1")
            captured.value = Self.body(of: req)
            return Self.ok(req, "{\"data\":\(Self.episodeJSON(label: "Meniscus tear, medial")),\"error\":null}")
        }
        let repo = try IllnessRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
        // What `EditEpisodeSheet.save()` builds for a label change on an open,
        // top-level episode with a note.
        let patch = IllnessEpisodePatch(
            label: "Meniscus tear, medial",
            resolvedAt: nil,
            parentConditionId: nil,
            note: "Physio twice a week"
        )

        let updated = try await repo.updateEpisode(id: "ep-1", patch)

        #expect(updated.label == "Meniscus tear, medial")
        let data = try #require(captured.value)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(body.keys) == ["label", "resolvedAt", "parentConditionId", "note"])
        #expect(body["bodySite"] == nil)
        #expect(body["laterality"] == nil)
    }

    // MARK: - Documents

    @Test("an imported document with an unknown sourceSystem still decodes; the upload envelope is unchanged")
    func documentSourceFieldsAreTolerated() async throws {
        let listItem = #"""
        {"id":"d1","kind":"LAB_RESULT","title":"Befund","filename":"befund.pdf","mimeType":"application/pdf",
         "byteSize":2048,"status":"STORED","providerType":null,"reportDate":null,"documentDate":"2026-09-20",
         "errorReason":null,"factCount":0,"pendingCount":0,"conditionLinks":[],"servingClass":"inline",
         "hasContentIndex":false,"contentIndexSource":null,"lastIndexAttemptAt":null,"lastIndexOutcome":null,
         "hasThumbnail":false,"sourceSystem":"NEXTCLOUD","sourceId":"4711",
         "createdAt":"2026-09-26T08:00:00.000Z","updatedAt":"2026-09-26T08:00:00.000Z"}
        """#
        let decoded = try JSONDecoder.hlDefault.decode(InboundDocument.self, from: Data(listItem.utf8))
        #expect(decoded.id == "d1")
        #expect(decoded.kind == .labResult)

        // The app's own upload sends no source key, so the answer is the full
        // `InboundDocument` in the `DocumentUploadEnvelope`, as before.
        let uploaded = listItem.replacingOccurrences(
            of: #""sourceSystem":"NEXTCLOUD","sourceId":"4711""#,
            with: #""sourceSystem":null,"sourceId":null"#
        )
        MockURLProtocol.install { req in
            let form = String(data: Self.body(of: req), encoding: .utf8) ?? ""
            #expect(!form.contains("sourceSystem"))
            #expect(!form.contains("sourceId"))
            return Self.ok(req, "{\"data\":\(uploaded),\"error\":null}", status: 201)
        }
        let lease = DocumentAIConsentLease(ownerUserID: "test-user", bearerToken: "test-token", scope: .serverManaged)
        let repo = DocumentsRepository(api: makeAPI(), externalAIConsent: DocumentAIConsentLeaseProvider { lease })
        let outcome = try await repo.upload(
            DocumentUploadDraft(data: Data([1, 2, 3]), filename: "befund.pdf", mimeType: "application/pdf"),
            usage: nil
        )
        #expect(outcome.document.id == "d1")
        #expect(!outcome.isDuplicate)
    }
}
