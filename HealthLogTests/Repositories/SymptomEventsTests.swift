import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping file_length type_body_length

/// **SYMPTOM (1.5.0, #144, server #1237)** — symptoms on an illness
/// episode: the wire contract of `/api/symptoms/events` and
/// `/api/symptoms/definitions`, the read by link (never by time span), the
/// linking rule, the partial edit, the refusals, the placement gate (server
/// with and without the `episodeId` filter) and the section's states.
@Suite("SYMPTOM — symptoms on an illness episode (#144)", .serialized, .mockURLSession)
struct SymptomEventsTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.5.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private static func ok(_ req: URLRequest, _ data: String) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            Data(#"{"data":\#(data),"error":null}"#.utf8)
        )
    }

    private static func refusal(_ req: URLRequest, status: Int, code: String, message: String = "refused")
        -> (HTTPURLResponse, Data)
    {
        (
            HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
            Data(#"{"data":null,"error":"\#(message)","meta":{"errorCode":"\#(code)"}}"#.utf8)
        )
    }

    private static func eventJSON(_ id: String, definition: String = "def-cough", at: String, episode: String?) -> String {
        let link = episode.map { "\"\($0)\"" } ?? "null"
        return #"{"id":"\#(id)","definitionId":"\#(definition)","occurredAt":"\#(at)","intensity":5,"note":null,"#
            + #""episodeId":\#(link),"createdAt":"\#(at)","updatedAt":"\#(at)"}"#
    }

    private static func episode(_ id: String, onset: String, resolved: String?) -> IllnessEpisodeDTO {
        IllnessEpisodeDTO(
            id: id,
            label: id,
            type: .infection,
            lifecycle: .acute,
            onsetAt: onset,
            resolvedAt: resolved,
            parentConditionId: nil,
            note: nil,
            createdAt: onset,
            updatedAt: onset
        )
    }

    private static func date(_ raw: String) -> Date {
        ISO8601DateFormatter.plain.date(from: raw)!
    }

    private static func event(
        _ id: String = "ev-1",
        at: String = "2026-10-02T08:00:00Z",
        intensity: Int = 5,
        note: String? = nil,
        episode: String? = "ep-a"
    ) -> SymptomEvent {
        SymptomEvent(id: id, definitionId: "def-cough", occurredAt: at, intensity: intensity, note: note, episodeId: episode)
    }

    // MARK: - Wire contract

    @Test("decodes the server's occurrence, page and definition shapes")
    func decodesShapes() throws {
        let page = try JSONDecoder.hlDefault.decode(SymptomEventPage.self, from: Data(#"""
        {"events":[{"id":"e1","definitionId":"d1","occurredAt":"2026-10-02T08:00:00.000Z","intensity":7,
          "note":"nach dem Treppensteigen","episodeId":"ep-a","createdAt":"x","updatedAt":"y"}],
         "limit":500,"hasMore":true}
        """#.utf8))
        #expect(page.hasMore)
        let event = try #require(page.events.first)
        #expect(event.id == "e1")
        #expect(event.definitionId == "d1")
        #expect(event.intensity == 7)
        #expect(event.note == "nach dem Treppensteigen")
        #expect(event.episodeId == "ep-a")
        #expect(event.occurredDate == ISO8601DateFormatter.fractional.date(from: "2026-10-02T08:00:00.000Z"))

        let list = try JSONDecoder.hlDefault.decode(SymptomDefinitionList.self, from: Data(#"""
        {"definitions":[
          {"id":"d1","label":"Husten","icon":"Activity","sortOrder":0,"isActive":true,
           "recent":{"count30d":3,"maxIntensity30d":7,"lastOccurredAt":null}},
          {"id":"d2","label":null,"icon":null,"sortOrder":1,"isActive":false,
           "recent":{"count30d":0,"maxIntensity30d":null,"lastOccurredAt":null}}],"limit":8}
        """#.utf8))
        #expect(list.definitions.map(\.id) == ["d1", "d2"])
        #expect(list.definitions[0].label == "Husten")
        #expect(list.definitions[1].label == nil)
        #expect(!list.definitions[1].isActive)
    }

    @Test("an occurrence without a link and a page without events decode, nothing invented")
    func tolerantDecode() throws {
        let page = try JSONDecoder.hlDefault.decode(SymptomEventPage.self, from: Data(#"{"limit":500}"#.utf8))
        #expect(page.events.isEmpty)
        #expect(!page.hasMore)
        let bare = try JSONDecoder.hlDefault.decode(
            SymptomEvent.self,
            from: Data(#"{"id":"e","definitionId":"d","occurredAt":"2026-10-02T08:00:00Z","intensity":0}"#.utf8)
        )
        #expect(bare.episodeId == nil)
        #expect(bare.note == nil)
        #expect(bare.intensity == 0)
    }

    // MARK: - Read by link (server #1237)

    /// The fixture of #1237: a long-running condition and a short infection
    /// overlap. Each holds its own filed symptom, and one symptom inside both
    /// spans is filed against nothing. Each page shows exactly its own.
    @Test("two overlapping episodes each show only their filed symptoms (#1237)")
    func overlappingEpisodesShowOnlyTheirOwn() async throws {
        let repo = SymptomEventsRepository(api: makeAPI())
        let all = [
            ("e-chronic", "ep-chronic"),
            ("e-cold", "ep-cold"),
            ("e-loose", nil)
        ]
        let seen = LockedURLs()
        MockURLProtocol.install { req in
            seen.append(req.url!)
            let asked = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "episodeId" }?.value
            let filed = all.filter { $0.1 == asked }
                .map { Self.eventJSON($0.0, at: "2026-10-02T08:00:00.000Z", episode: $0.1) }
            return Self.ok(req, #"{"events":[\#(filed.joined(separator: ","))],"limit":500,"hasMore":false}"#)
        }
        #expect(try await repo.events(episodeId: "ep-chronic").map(\.id) == ["e-chronic"])
        #expect(try await repo.events(episodeId: "ep-cold").map(\.id) == ["e-cold"])
        let items = seen.all.compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        #expect(items.allSatisfy { $0.path == "/api/symptoms/events" })
        // Never by time span: no `from`, no `to` on a first page.
        for item in items {
            let names = Set(item.queryItems?.map(\.name) ?? [])
            #expect(names == ["episodeId", "limit"])
            #expect(item.queryItems?.first { $0.name == "limit" }?.value == "500")
        }
    }

    @Test("a wider answer (a server that ignores the filter) never shows another episode's symptom")
    func widerAnswerIsNarrowed() async throws {
        let repo = SymptomEventsRepository(api: makeAPI())
        MockURLProtocol.install { req in
            let rows = [
                Self.eventJSON("mine", at: "2026-10-03T08:00:00Z", episode: "ep-a"),
                Self.eventJSON("other", at: "2026-10-02T08:00:00Z", episode: "ep-b"),
                Self.eventJSON("loose", at: "2026-10-01T08:00:00Z", episode: nil)
            ]
            return Self.ok(req, #"{"events":[\#(rows.joined(separator: ","))],"limit":500,"hasMore":false}"#)
        }
        #expect(try await repo.events(episodeId: "ep-a").map(\.id) == ["mine"])
    }

    @Test("more than one page: pages on with `to` at the oldest time, the shared row once")
    func pagesOn() async throws {
        let repo = SymptomEventsRepository(api: makeAPI())
        let seen = LockedURLs()
        MockURLProtocol.install { req in
            seen.append(req.url!)
            let to = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "to" }?.value
            if to == nil {
                let rows = [
                    Self.eventJSON("e3", at: "2026-10-03T08:00:00Z", episode: "ep-a"),
                    Self.eventJSON("e2", at: "2026-10-02T08:00:00Z", episode: "ep-a")
                ]
                return Self.ok(req, #"{"events":[\#(rows.joined(separator: ","))],"limit":500,"hasMore":true}"#)
            }
            let rows = [
                Self.eventJSON("e2", at: "2026-10-02T08:00:00Z", episode: "ep-a"),
                Self.eventJSON("e1", at: "2026-10-01T08:00:00Z", episode: "ep-a")
            ]
            return Self.ok(req, #"{"events":[\#(rows.joined(separator: ","))],"limit":500,"hasMore":false}"#)
        }
        #expect(try await repo.events(episodeId: "ep-a").map(\.id) == ["e3", "e2", "e1"])
        let tos = seen.all.map {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "to" }?.value
        }
        #expect(tos == [nil, "2026-10-02T08:00:00Z"])
    }

    @Test("definitions are read with the hidden ones, whose occurrences stay listed")
    func definitionsIncludeHidden() async throws {
        let repo = SymptomEventsRepository(api: makeAPI())
        let seen = LockedURLs()
        MockURLProtocol.install { req in
            seen.append(req.url!)
            return Self.ok(req, #"{"definitions":[{"id":"d1","label":"Husten","sortOrder":0,"isActive":false}],"limit":8}"#)
        }
        let definitions = try await repo.definitions()
        #expect(definitions.map(\.id) == ["d1"])
        let url = try #require(seen.all.first)
        #expect(url.path == "/api/symptoms/definitions")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "includeHidden" }?.value == "true")
    }

    // MARK: - Linking rule

    @Test("open episodes always, ended ones only when their span holds the time")
    func linkingRule() {
        let open = Self.episode("ep-open", onset: "2026-09-01T08:00:00Z", resolved: nil)
        let ended = Self.episode("ep-ended", onset: "2026-10-01T08:00:00Z", resolved: "2026-10-05T08:00:00Z")
        let inside = Self.date("2026-10-03T08:00:00Z")
        let after = Self.date("2026-10-06T08:00:00Z")
        #expect(SymptomEpisodeLink.isLinkable(open, at: after))
        #expect(SymptomEpisodeLink.isLinkable(ended, at: inside))
        #expect(SymptomEpisodeLink.isLinkable(ended, at: Self.date("2026-10-05T08:00:00Z")))
        #expect(!SymptomEpisodeLink.isLinkable(ended, at: after))
        #expect(!SymptomEpisodeLink.isLinkable(ended, at: Self.date("2026-09-30T08:00:00Z")))

        #expect(SymptomEpisodeLink.options(from: [open, ended], at: inside).map(\.id) == ["ep-open", "ep-ended"])
        #expect(SymptomEpisodeLink.options(from: [open, ended], at: after).map(\.id) == ["ep-open"])
        // The stored link of an edited occurrence stays offered.
        #expect(SymptomEpisodeLink.options(from: [open, ended], at: after, keep: "ep-ended").map(\.id)
            == ["ep-open", "ep-ended"])
        // A choice the time moved away from is not sent.
        let options = SymptomEpisodeLink.options(from: [open, ended], at: after)
        #expect(SymptomEpisodeLink.effective(chosen: "ep-ended", options: options) == nil)
        #expect(SymptomEpisodeLink.effective(chosen: "ep-open", options: options) == "ep-open")
        #expect(SymptomEpisodeLink.effective(chosen: nil, options: options) == nil)
    }

    // MARK: - Write bodies

    @Test("the edit sends only what changed; a cleared note and a dropped link are null")
    func patchBody() throws {
        let original = Self.event(note: "abends", episode: "ep-a")
        let at = Self.date("2026-10-02T08:00:00Z")
        let none = SymptomEventPatch.between(original, occurredAt: at, intensity: 5, note: "abends", episodeId: "ep-a")
        #expect(none.isEmpty)
        #expect(try Self.json(none) == [:])

        let moved = SymptomEventPatch.between(original, occurredAt: at, intensity: 5, note: "abends", episodeId: "ep-b")
        #expect(try Self.json(moved) == ["episodeId": "ep-b"])

        let dropped = SymptomEventPatch.between(original, occurredAt: at, intensity: 7, note: "  ", episodeId: nil)
        let body = try Self.json(dropped)
        #expect(body["intensity"] as? Int == 7)
        #expect(body["note"]?.base is NSNull)
        #expect(body["episodeId"]?.base is NSNull)
        #expect(body.count == 3)

        let later = SymptomEventPatch.between(
            original,
            occurredAt: Self.date("2026-10-02T09:30:00Z"),
            intensity: 5,
            note: "abends",
            episodeId: "ep-a"
        )
        #expect(try Self.json(later) == ["occurredAt": "2026-10-02T09:30:00Z"])
    }

    @Test("logging sends the symptom, intensity, time and the preselected episode; an empty note is left out")
    func createBody() throws {
        let body = SymptomEventCreate(
            definitionId: "def-cough",
            occurredAt: Self.date("2026-10-02T08:00:00Z"),
            intensity: 0,
            note: " ",
            episodeId: "ep-a"
        )
        let json = try Self.json(body)
        #expect(json["definitionId"] as? String == "def-cough")
        #expect(json["occurredAt"] as? String == "2026-10-02T08:00:00Z")
        #expect(json["intensity"] as? Int == 0)
        #expect(json["episodeId"] as? String == "ep-a")
        #expect(json["note"] == nil)
        let unlinked = try Self.json(SymptomEventCreate(
            definitionId: "d",
            occurredAt: .now,
            intensity: 3,
            note: "x",
            episodeId: nil
        ))
        #expect(unlinked["episodeId"] == nil)
        #expect(unlinked["note"] as? String == "x")
    }

    private static func json(_ value: some Encodable) throws -> [String: AnyHashable] {
        let data = try JSONEncoder.hlDefault.encode(value)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return object.compactMapValues { $0 as? AnyHashable }
    }

    // MARK: - Writes and refusals

    @Test("change the link and back: PATCH on the occurrence with the new link, then the old one")
    func relinkAndBack() async throws {
        let repo = SymptomEventsRepository(api: makeAPI())
        let bodies = LockedBodies()
        MockURLProtocol.install { req in
            #expect(req.httpMethod == "PATCH")
            #expect(req.url?.path == "/api/symptoms/events/ev-1")
            let body = req.bodyData
            bodies.append(body)
            let sent = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["episodeId"] as? String
            return Self.ok(req, Self.eventJSON("ev-1", at: "2026-10-02T08:00:00Z", episode: sent))
        }
        let original = Self.event(episode: "ep-a")
        let at = Self.date("2026-10-02T08:00:00Z")
        let away = try await repo.update(
            id: "ev-1",
            SymptomEventPatch.between(original, occurredAt: at, intensity: 5, note: "", episodeId: "ep-b")
        )
        #expect(away.episodeId == "ep-b")
        let back = try await repo.update(
            id: "ev-1",
            SymptomEventPatch.between(away, occurredAt: at, intensity: 5, note: "", episodeId: "ep-a")
        )
        #expect(back.episodeId == "ep-a")
        #expect(bodies.all.count == 2)
    }

    @Test("a refused link (422 symptoms.episode.notOpen) says why")
    func refusedLink() async throws {
        let repo = SymptomEventsRepository(api: makeAPI())
        MockURLProtocol.install { req in
            Self.refusal(req, status: 422, code: "symptoms.episode.notOpen", message: "Episode did not run at that time")
        }
        do {
            try await repo.update(id: "ev-1", SymptomEventPatch(episodeId: .set("ep-ended")))
            Issue.record("expected a refusal")
        } catch {
            #expect(SymptomEventsRepository.isEpisodeNotOpen(error))
            #expect(SymptomEventSheet.message(for: error) == String(localized: "symptoms.error.episodeNotOpen"))
        }
    }

    @Test("delete: DELETE on the occurrence; a gone one is a 404 the page treats as done")
    func deleteAndGone() async throws {
        let repo = SymptomEventsRepository(api: makeAPI())
        let seen = LockedURLs()
        MockURLProtocol.install { req in
            seen.append(req.url!)
            #expect(req.httpMethod == "DELETE")
            return Self.ok(req, #"{"deleted":true}"#)
        }
        try await repo.delete(id: "ev-9")
        #expect(seen.all.map(\.path) == ["/api/symptoms/events/ev-9"])

        MockURLProtocol.install { req in
            Self.refusal(req, status: 404, code: "symptoms.event.notFound")
        }
        do {
            try await repo.delete(id: "ev-9")
            Issue.record("expected 404")
        } catch {
            #expect(SymptomEventsRepository.isGone(error))
            #expect(SymptomEventSheet.message(for: error) == String(localized: "symptoms.error.gone"))
        }
    }

    @Test("module off or a grant that does not reach it: a plain sentence, never the server's English")
    func refusalMessages() {
        let notAllowed = String(localized: "symptoms.error.notAllowed")
        #expect(SymptomEventSheet.message(for: HLError.moduleDisabled("illness")) == notAllowed)
        #expect(SymptomEventSheet.message(for: HLError.server(
            status: 403,
            code: "sharing.client.access.denied",
            message: "Selected record does not admit this request"
        )) == notAllowed)
        #expect(SymptomEventSheet.message(for: HLError.canceled) == nil)
        #expect(SymptomEventSheet.message(for: CancellationError()) == nil)
        #expect(SymptomEventSheet.message(for: HLError.offline) == HLError.offline.userFacingDescription)
    }

    // MARK: - Placement gate (Regel 10)

    @Test("only with a paired server that filters by link (v1.43.4 or later)")
    func placementGate() {
        #expect(!EpisodeSymptomsSection.isAvailable(isPaired: true, serverVersion: nil))
        #expect(!EpisodeSymptomsSection.isAvailable(isPaired: true, serverVersion: "1.43.3"))
        #expect(!EpisodeSymptomsSection.isAvailable(isPaired: true, serverVersion: "1.40.0"))
        #expect(EpisodeSymptomsSection.isAvailable(isPaired: true, serverVersion: "1.43.4"))
        #expect(EpisodeSymptomsSection.isAvailable(isPaired: true, serverVersion: "1.47.0"))
        #expect(!EpisodeSymptomsSection.isAvailable(isPaired: false, serverVersion: "1.47.0"))
    }

    // MARK: - Section state

    @Test("rows carry the definition's label; a hidden symptom keeps its name, an unknown one says so")
    @MainActor
    func sectionRows() async {
        let model = EpisodeSymptomsModel()
        await model.load(
            events: { [Self.event("e1"), SymptomEvent(
                id: "e2",
                definitionId: "def-gone",
                occurredAt: "2026-10-01T08:00:00Z",
                intensity: 2,
                note: nil,
                episodeId: "ep-a"
            )] },
            definitions: { [
                SymptomDefinition(id: "def-cough", label: "Husten", isActive: false),
                SymptomDefinition(id: "def-throat", label: "Halsschmerzen")
            ] }
        )
        guard case let .loaded(rows) = model.state else {
            Issue.record("expected rows, got \(model.state)")
            return
        }
        #expect(rows.map(\.label) == ["Husten", nil])
        #expect(model.activeDefinitions.map(\.id) == ["def-throat"])
        #expect(model.canLog)
        #expect(SymptomEventFormat.label(rows[1].label) == String(localized: "symptoms.unreadableLabel"))
        let spoken = SymptomEventFormat.spokenLabel(rows[0])
        #expect(spoken.contains("Husten"))
        #expect(spoken.contains("5"))
        #expect(!spoken.contains("symptoms."))
    }

    @Test("shown when there are rows, or while the episode runs and a symptom can be logged")
    func visibility() {
        let row = EpisodeSymptomsModel.Row(event: Self.event(), label: "Husten")
        #expect(EpisodeSymptomsModel.isVisible(rows: [row], episodeIsActive: false, canLog: false))
        #expect(EpisodeSymptomsModel.isVisible(rows: [], episodeIsActive: true, canLog: true))
        #expect(!EpisodeSymptomsModel.isVisible(rows: [], episodeIsActive: true, canLog: false))
        #expect(!EpisodeSymptomsModel.isVisible(rows: [], episodeIsActive: false, canLog: true))
    }

    @Test("a refusal is the disabled card with the server's reason; other failures retry; a cancel changes nothing")
    @MainActor
    func sectionFailures() async {
        let moduleOff = EpisodeSymptomsModel()
        await moduleOff.load(
            events: { throw HLError.moduleDisabled("illness") },
            definitions: { [] },
            offReason: { "Ausgeschaltet" }
        )
        #expect(moduleOff.state == .disabled("Ausgeschaltet"))

        let grant = EpisodeSymptomsModel()
        await grant.load(
            events: { throw HLError.server(status: 403, code: "sharing.access.denied", message: "") },
            definitions: { [] }
        )
        #expect(grant.state == .disabled(nil))

        for failure in [HLError.offline, HLError.server(status: 500, code: nil, message: ""), HLError.decoding("x")] {
            let broken = EpisodeSymptomsModel()
            await broken.load(events: { throw failure }, definitions: { [] })
            #expect(broken.state == .failed)
        }

        let definitionsFail = EpisodeSymptomsModel()
        await definitionsFail.load(events: { [] }, definitions: { throw HLError.offline })
        #expect(definitionsFail.state == .failed)

        #expect(EpisodeSymptomsModel.stateAfter(CancellationError(), offReason: nil) == nil)
        #expect(EpisodeSymptomsModel.stateAfter(HLError.canceled, offReason: nil) == nil)
    }

    @Test("retry after a failure shows the rows")
    @MainActor
    func retryRecovers() async {
        let attempts = LockedInts()
        let model = EpisodeSymptomsModel()
        await model.load(
            events: {
                attempts.append(1)
                if attempts.all.count == 1 { throw HLError.offline }
                return [Self.event()]
            },
            definitions: { [SymptomDefinition(id: "def-cough", label: "Husten")] }
        )
        #expect(model.state == .failed)
        await model.reload()
        #expect(model.state == .loaded([EpisodeSymptomsModel.Row(event: Self.event(), label: "Husten")]))
    }
}

// MARK: - Small thread-safe recorders

private final class LockedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func append(_ url: URL) {
        lock.withLock { urls.append(url) }
    }

    var all: [URL] {
        lock.withLock { urls }
    }
}

private final class LockedInts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func append(_ value: Int) {
        lock.withLock { values.append(value) }
    }

    var all: [Int] {
        lock.withLock { values }
    }
}

private final class LockedBodies: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []
    func append(_ body: Data) {
        lock.withLock { bodies.append(body) }
    }

    var all: [Data] {
        lock.withLock { bodies }
    }
}

private extension URLRequest {
    /// URLProtocol moves `httpBody` onto `httpBodyStream`; read either.
    var bodyData: Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
