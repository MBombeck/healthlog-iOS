// swiftlint:disable force_unwrapping
import Foundation
@testable import HealthLog
import Testing

/// **CU-32 — `AnamnesisFactsStore` über den echten Transportweg.**
///
/// Der Store entscheidet POST gegen PATCH aus dem Zustand und lädt nach jedem
/// Schreibvorgang neu, weil eine Korrektur eine neue Revisions-ID erzeugt. Beides
/// wird hier gegen `MockURLProtocol` gepinnt — inklusive der vier Fehlerbilder,
/// die zu vier verschiedenen Meldungen führen müssen.
@MainActor
@Suite("AnamnesisFactsStore", .serialized)
struct AnamnesisFactsStoreTests {
    private func makeStore() -> AnamnesisFactsStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let api = APIClient(
            environment: env,
            keychain: InMemoryKeychain(),
            sessionConfiguration: .mock()
        )
        return AnamnesisFactsStore(repo: AnamnesisRepository(api: api))
    }

    private nonisolated static func respond(_ request: URLRequest, _ status: Int, _ json: String)
        -> (HTTPURLResponse, Data?)
    {
        let http = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (http, Data(json.utf8))
    }

    /// Nichts erfasst — alle drei `current`-Schlüssel `null`.
    private nonisolated static let emptyFacts = """
    {"data":{"current":{"SMOKING_STATUS":null,"ALCOHOL_PATTERN":null,"SHIFT_SCHEDULE":null},
      "history":[]},"error":null}
    """

    private nonisolated static func revision(
        id: String,
        kind: String,
        value: String,
        provenance: String = "USER_REPORTED",
        validFrom: String = "2026-07-30T12:00:00.000Z"
    ) -> String {
        """
        {"id":"\(id)","kind":"\(kind)","value":"\(value)","unreadable":false,\
        "validFrom":"\(validFrom)","validUntil":null,"provenance":"\(provenance)",\
        "supersededByRevisionId":null,"createdAt":"\(validFrom)"}
        """
    }

    private nonisolated static func factsWithSmoking(_ value: String, id: String = "rev-1") -> String {
        let row = revision(id: id, kind: "SMOKING_STATUS", value: value)
        return """
        {"data":{"current":{"SMOKING_STATUS":\(row),"ALCOHOL_PATTERN":null,\
        "SHIFT_SCHEDULE":null},"history":[\(row)]},"error":null}
        """
    }

    // MARK: - Load

    @Test("an empty payload is 'never recorded' for all three kinds — never NONE")
    func emptyIsNeverRecorded() async {
        let store = makeStore()
        MockURLProtocol.handler = { Self.respond($0, 200, Self.emptyFacts) }

        await store.load()

        #expect(store.didLoad)
        #expect(!store.loadFailed)
        #expect(store.isEmpty)
        for kind in AnamnesisFactKind.allCases {
            #expect(store.state(for: kind) == .neverRecorded)
            // Der entscheidende Punkt: Abwesenheit hat keinen Wert. Ein `NONE`
            // hier wäre eine erfundene Aussage.
            #expect(store.state(for: kind).value == nil)
        }
    }

    @Test("an explicit NONE is recorded — and is a different state from never recorded")
    func declaredNoneIsNotAbsence() async {
        let store = makeStore()
        let row = Self.revision(id: "rev-alc", kind: "ALCOHOL_PATTERN", value: "NONE")
        MockURLProtocol.handler = { request in
            let json = """
            {"data":{"current":{"SMOKING_STATUS":null,"ALCOHOL_PATTERN":\(row),\
            "SHIFT_SCHEDULE":null},"history":[\(row)]},"error":null}
            """
            return Self.respond(request, 200, json)
        }

        await store.load()

        #expect(store.state(for: .alcoholPattern).value == .declaredNone)
        #expect(store.state(for: .alcoholPattern).isRecorded)
        #expect(store.state(for: .smokingStatus) == .neverRecorded)
        #expect(!store.state(for: .smokingStatus).isRecorded)
        #expect(store.state(for: .alcoholPattern) != store.state(for: .smokingStatus))
    }

    @Test("a load failure is reported, not silently rendered as an empty anamnesis")
    func loadFailureIsHonest() async {
        let store = makeStore()
        MockURLProtocol.handler = { Self.respond($0, 500, #"{"data":null,"error":"x"}"#) }

        await store.load()

        #expect(store.loadFailed)
        #expect(store.loadError != nil)
        #expect(store.didLoad)
    }

    // MARK: - Verb choice

    @Test("with nothing recorded, setValue POSTs; the roundtrip then shows the new value")
    func firstEntryUsesPost() async {
        let store = makeStore()
        nonisolated(unsafe) var methods: [String] = []
        MockURLProtocol.handler = { request in
            let method = request.httpMethod ?? ""
            methods.append(method)
            switch method {
            case "POST":
                return Self.respond(
                    request, 201,
                    "{\"data\":\(Self.revision(id: "rev-1", kind: "SMOKING_STATUS", value: "NEVER")),\"error\":null}"
                )
            default:
                return Self.respond(
                    request, 200,
                    methods.contains("POST") ? Self.factsWithSmoking("NEVER") : Self.emptyFacts
                )
            }
        }

        await store.load()
        await store.setValue(.never, for: .smokingStatus)

        #expect(methods == ["GET", "POST", "GET"])
        #expect(store.state(for: .smokingStatus).value == .never)
        #expect(store.writeError == nil)
        #expect(store.pendingKind == nil)
    }

    @Test("with a value already recorded, setValue PATCHes the current revision id")
    func correctionUsesPatchOnTheCurrentId() async {
        let store = makeStore()
        nonisolated(unsafe) var patchedPath: String?
        nonisolated(unsafe) var methods: [String] = []
        MockURLProtocol.handler = { request in
            let method = request.httpMethod ?? ""
            methods.append(method)
            if method == "PATCH" {
                patchedPath = request.url?.path
                let successor = Self.revision(
                    id: "rev-2", kind: "SMOKING_STATUS", value: "FORMER",
                    provenance: "USER_CORRECTION"
                )
                return Self.respond(request, 200, "{\"data\":\(successor),\"error\":null}")
            }
            return Self.respond(
                request, 200,
                methods.contains("PATCH")
                    ? Self.factsWithSmoking("FORMER", id: "rev-2")
                    : Self.factsWithSmoking("CURRENT", id: "rev-1")
            )
        }

        await store.load()
        await store.setValue(.former, for: .smokingStatus)

        #expect(methods == ["GET", "PATCH", "GET"])
        // Die ID der aktuellen Revision ist das Token — sie steht im Pfad.
        #expect(patchedPath == "/api/anamnesis/facts/rev-1")
        // Nach dem Reload trägt der Store die NEUE Revisions-ID.
        #expect(store.state(for: .smokingStatus).revision?.id == "rev-2")
    }

    @Test("an unreadable revision is corrected, not re-created (it still has an id)")
    func unreadableIsPatchedNotPosted() async {
        let store = makeStore()
        nonisolated(unsafe) var methods: [String] = []
        MockURLProtocol.handler = { request in
            let method = request.httpMethod ?? ""
            methods.append(method)
            if method == "PATCH" {
                let successor = Self.revision(
                    id: "rev-2", kind: "ALCOHOL_PATTERN", value: "WEEKLY",
                    provenance: "USER_CORRECTION"
                )
                return Self.respond(request, 200, "{\"data\":\(successor),\"error\":null}")
            }
            let unreadable = """
            {"id":"rev-1","kind":"ALCOHOL_PATTERN","value":null,"unreadable":true,\
            "validFrom":"2026-01-01T00:00:00.000Z","validUntil":null,\
            "provenance":"USER_REPORTED","supersededByRevisionId":null,\
            "createdAt":"2026-01-01T00:00:00.000Z"}
            """
            let json = """
            {"data":{"current":{"SMOKING_STATUS":null,"ALCOHOL_PATTERN":\(unreadable),\
            "SHIFT_SCHEDULE":null},"history":[\(unreadable)]},"error":null}
            """
            return Self.respond(request, 200, json)
        }

        await store.load()
        await store.setValue(.weekly, for: .alcoholPattern)

        #expect(methods.contains("PATCH"))
        #expect(!methods.contains("POST"))
    }

    @Test("removeCurrent closes the revision and refreshes")
    func removeClosesTheRevision() async {
        let store = makeStore()
        nonisolated(unsafe) var methods: [String] = []
        MockURLProtocol.handler = { request in
            let method = request.httpMethod ?? ""
            methods.append(method)
            if method == "DELETE" {
                let json = """
                {"data":{"id":"rev-1","kind":"SMOKING_STATUS",\
                "removedAt":"2026-07-30T13:00:00.000Z"},"error":null}
                """
                return Self.respond(request, 200, json)
            }
            return Self.respond(
                request, 200,
                methods.contains("DELETE") ? Self.emptyFacts : Self.factsWithSmoking("CURRENT")
            )
        }

        await store.load()
        await store.removeCurrent(for: .smokingStatus)

        #expect(methods == ["GET", "DELETE", "GET"])
        #expect(store.state(for: .smokingStatus) == .neverRecorded)
    }

    // MARK: - Die vier Fehlerbilder ergeben vier verschiedene Zustände

    /// Jeder der vier Fehlercodes muss zu einer eigenen, verständlichen Meldung
    /// führen — und die drei Nebenläufigkeits-Fälle ziehen zusätzlich einen
    /// frischen `GET` nach, weil die alte Revisions-ID als Token tot ist.
    @Test(
        "each server failure yields its own message and the right reload behaviour",
        arguments: [
            (409, "anamnesis.fact.conflict", true),
            (409, "anamnesis.fact.currentExists", true),
            (422, "anamnesis.fact.invalidValue", false),
            (404, nil as String?, true)
        ]
    )
    func namedFailureStates(status: Int, code: String?, expectsReload: Bool) async throws {
        let store = makeStore()
        nonisolated(unsafe) var getCount = 0
        nonisolated(unsafe) var didWrite = false
        MockURLProtocol.handler = { request in
            if request.httpMethod == "GET" {
                getCount += 1
                return Self.respond(request, 200, Self.factsWithSmoking("CURRENT"))
            }
            didWrite = true
            let meta = code.map { #",\#n"meta":{"errorCode":"\#($0)"}"# } ?? ""
            return Self.respond(request, status, #"{"data":null,"error":"nope"\#(meta)}"#)
        }

        await store.load()
        #expect(getCount == 1)
        await store.setValue(.never, for: .smokingStatus)

        #expect(didWrite)
        let message = try #require(store.writeError)
        #expect(!message.isEmpty)
        #expect(getCount == (expectsReload ? 2 : 1))
        #expect(store.pendingKind == nil)
    }

    @Test("the four failure messages are pairwise distinct — no generic catch-all")
    func failureMessagesAreDistinct() {
        let messages = [
            AnamnesisFactFailure.conflict,
            .staleRevision,
            .invalidValue,
            .currentExists,
            .requestInFlight
        ].map(\.userFacingDescription)

        #expect(Set(messages).count == messages.count)
        for message in messages {
            #expect(!message.isEmpty)
            // Ein durchgereichter Katalog-Schlüssel wäre ein fehlender Eintrag.
            #expect(!message.hasPrefix("anamnesis."))
        }
    }

    @Test("the object-shaped idempotency 409 reaches the UI as its own message")
    func inFlightFailureIsSurfaced() async {
        let store = makeStore()
        MockURLProtocol.handler = { request in
            if request.httpMethod == "GET" {
                return Self.respond(request, 200, Self.emptyFacts)
            }
            let json = """
            {"data":null,"error":{"message":"A request with this Idempotency-Key is already in progress"}}
            """
            return Self.respond(request, 409, json)
        }

        await store.load()
        await store.setValue(.never, for: .smokingStatus)

        #expect(store.writeError == AnamnesisFactFailure.requestInFlight.userFacingDescription)
        #expect(store.writeError != AnamnesisFactFailure.currentExists.userFacingDescription)
    }

    @Test("clearWriteError dismisses the banner")
    func writeErrorCanBeDismissed() async {
        let store = makeStore()
        MockURLProtocol.handler = { request in
            request.httpMethod == "GET"
                ? Self.respond(request, 200, Self.emptyFacts)
                : Self.respond(request, 500, #"{"data":null,"error":"x"}"#)
        }

        await store.load()
        await store.setValue(.never, for: .smokingStatus)
        #expect(store.writeError != nil)

        store.clearWriteError()
        #expect(store.writeError == nil)
    }
}

// swiftlint:enable force_unwrapping
