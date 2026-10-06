import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **Build 9 (Server-Prefs) / C3** — repository contract for the coach seam:
/// `disable-coach` (GET/PATCH) and coach-prefs JSON-level read-modify-write.
///
/// Real `APIClient` + `MockURLProtocol` (never a mock server). Pins the exact
/// wire shapes AND — critically — that the RMW PUT is a faithful full-replace:
/// sibling fields survive value-equal and the key-absence sentinels
/// (`dataClusters` / `reminderSuggestions`) are preserved as absence, never
/// materialised into `[]`/`null` (plan §guard 2).
@Suite("AICoachSettingsRepository coach-prefs (Build 9)", .serialized, .mockURLSession)
struct AICoachSettingsRepositoryCoachPrefsTests {
    private func makeRepo() -> AICoachSettingsRepository {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return AICoachSettingsRepository(
            api: APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        )
    }

    nonisolated static func consumeStream(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var buf = Data()
        var raw = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&raw, maxLength: 4096)
            guard read > 0 else { break }
            buf.append(raw, count: read)
        }
        return buf.isEmpty ? nil : buf
    }

    // MARK: - disable-coach

    @Test("fetchDisableCoach GET decodes the flag")
    func fetchDisableCoach() async throws {
        nonisolated(unsafe) var capturedPath: String?
        MockURLProtocol.install { req in
            capturedPath = req.url?.path
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{"disableCoach":true},"error":null}"#.utf8)
            )
        }
        let value = try await makeRepo().fetchDisableCoach()
        #expect(capturedPath == "/api/auth/me/disable-coach")
        #expect(value == true)
    }

    @Test("fetchDisableCoach tolerates a payload that omits the field → false")
    func fetchDisableCoachTolerant() async throws {
        MockURLProtocol.install { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{},"error":null}"#.utf8)
            )
        }
        let value = try await makeRepo().fetchDisableCoach()
        #expect(value == false)
    }

    @Test("setDisableCoach PATCHes the exact body and echo-decodes the state")
    func setDisableCoach() async throws {
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.install { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            capturedBody = req.httpBody ?? req.httpBodyStream.flatMap(Self.consumeStream(_:))
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{"disableCoach":true},"error":null}"#.utf8)
            )
        }
        let echoed = try await makeRepo().setDisableCoach(true)
        #expect(capturedPath == "/api/auth/me/disable-coach")
        #expect(capturedMethod == "PATCH")
        let body = try #require(capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["disableCoach"] as? Bool == true)
        #expect(json.count == 1)
        #expect(echoed == true)
    }

    // MARK: - coach-prefs RMW

    /// Installs a GET that returns `getBody`, and captures the PUT body.
    private func installCoachPrefsRouter(getBody: String, capturedPut: @escaping @Sendable (Data?) -> Void) {
        MockURLProtocol.install { req in
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if req.httpMethod == "PUT" {
                capturedPut(req.httpBody ?? req.httpBodyStream.flatMap(Self.consumeStream(_:)))
                return (http, Data(#"{"data":{"ok":true},"error":null}"#.utf8))
            }
            return (http, Data(getBody.utf8))
        }
    }

    @Test("RMW preserves all sibling fields and materialises reminderSuggestions when absent")
    func rmwPreservesSiblingsAndDefaultsReminder() async throws {
        nonisolated(unsafe) var putBody: Data?
        installCoachPrefsRouter(
            getBody: #"""
            {"data":{"tone":"neutral","verbosity":"detailed","excludeMetrics":["bp"],
             "showEvidenceByDefault":true,"defaultWindow":"last30days","dataClusters":["cardio"]},"error":null}
            """#,
            capturedPut: { putBody = $0 }
        )
        _ = try await makeRepo().setReminderSuggestionsEnabled(false)

        let json = try #require(putBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        // Siblings survive value-equal.
        #expect(json["tone"] as? String == "neutral")
        #expect(json["verbosity"] as? String == "detailed")
        #expect(json["excludeMetrics"] as? [String] == ["bp"])
        #expect(json["showEvidenceByDefault"] as? Bool == true)
        #expect(json["defaultWindow"] as? String == "last30days")
        #expect(json["dataClusters"] as? [String] == ["cardio"])
        // reminderSuggestions materialised with the server-default shape + enabled=false.
        let reminder = try #require(json["reminderSuggestions"] as? [String: Any])
        #expect(reminder["enabled"] as? Bool == false)
        #expect(reminder["stopped"] as? Bool == false)
        #expect(reminder["dismissedCadences"] as? [String] == [])
        #expect(reminder["lastSuggestedAt"] is NSNull)
    }

    @Test("RMW keeps an existing reminderSuggestions blob (dismissedCadences preserved)")
    func rmwKeepsExistingReminderBlob() async throws {
        nonisolated(unsafe) var putBody: Data?
        installCoachPrefsRouter(
            getBody: #"""
            {"data":{"tone":"warm","verbosity":"brief","excludeMetrics":[],"showEvidenceByDefault":false,
             "defaultWindow":"last7days",
             "reminderSuggestions":{"enabled":true,"stopped":false,
             "dismissedCadences":["daily-weight"],"lastSuggestedAt":"2026-07-01T00:00:00Z"}},"error":null}
            """#,
            capturedPut: { putBody = $0 }
        )
        _ = try await makeRepo().setReminderSuggestionsEnabled(false)

        let json = try #require(putBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let reminder = try #require(json["reminderSuggestions"] as? [String: Any])
        #expect(reminder["enabled"] as? Bool == false) // flipped
        #expect(reminder["dismissedCadences"] as? [String] == ["daily-weight"]) // preserved
        #expect(reminder["lastSuggestedAt"] as? String == "2026-07-01T00:00:00Z") // preserved
    }

    @Test("RMW preserves dataClusters key-ABSENCE (never materialised to []/null)")
    func rmwPreservesDataClustersAbsence() async throws {
        nonisolated(unsafe) var putBody: Data?
        installCoachPrefsRouter(
            getBody: #"""
            {"data":{"tone":"neutral","verbosity":"detailed","excludeMetrics":[],
             "showEvidenceByDefault":true,"defaultWindow":"last30days"},"error":null}
            """#,
            capturedPut: { putBody = $0 }
        )
        _ = try await makeRepo().setReminderSuggestionsEnabled(true)

        let json = try #require(putBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        // Absent in the GET → still absent in the PUT (semantic sentinel, not []/null).
        #expect(json.keys.contains("dataClusters") == false)
        #expect(json["dataClusters"] == nil)
    }

    // MARK: - #115 R3 — server v1.39.4 `followUpChips`

    /// Server v1.39.4 added `followUpChips` to coach-prefs: absent means on,
    /// only `false` turns the Coach's follow-up chips off, and `PUT` replaces
    /// the whole object — a body without the key switches chips back ON. The
    /// app has no typed field for it, so the reminder toggle must carry it (and
    /// any other key it does not know) through verbatim.
    @Test("RMW keeps followUpChips:false and an unknown nested key untouched")
    func rmwKeepsFollowUpChipsAndUnknownKeys() async throws {
        nonisolated(unsafe) var putBody: Data?
        installCoachPrefsRouter(
            getBody: #"""
            {"data":{"tone":"neutral","verbosity":"detailed","excludeMetrics":[],
             "showEvidenceByDefault":true,"defaultWindow":"last30days",
             "followUpChips":false,"futureBlock":{"mode":"x","weights":[1,2.5,null]}},"error":null}
            """#,
            capturedPut: { putBody = $0 }
        )
        _ = try await makeRepo().setReminderSuggestionsEnabled(false)

        let json = try #require(putBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(json["followUpChips"] as? Bool == false, "chips would silently switch back on")
        let future = try #require(json["futureBlock"] as? [String: Any])
        #expect(future["mode"] as? String == "x")
        let weights = try #require(future["weights"] as? [Any])
        #expect(weights.count == 3)
        #expect(weights[2] is NSNull)
    }

    /// After a 409 the toggle is re-applied to the RE-READ object, so a
    /// `followUpChips` another session wrote in between survives the retry.
    @Test("409 retry re-applies onto the fresh object and keeps its followUpChips")
    func conflictRetryKeepsFreshFollowUpChips() async throws {
        nonisolated(unsafe) var reads = 0
        nonisolated(unsafe) var puts: [Data] = []
        MockURLProtocol.install { req in
            let url = req.url!
            if req.httpMethod == "PUT" {
                puts.append(req.httpBody ?? req.httpBodyStream.flatMap(Self.consumeStream(_:)) ?? Data())
                if puts.count == 1 {
                    let http = HTTPURLResponse(url: url, statusCode: 409, httpVersion: nil, headerFields: nil)!
                    let body = #"{"data":null,"error":"changed","meta":{"errorCode":"\#(OptimisticConflictCode.coachPrefs)"}}"#
                    return (http, Data(body.utf8))
                }
                let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (http, Data(#"{"data":{"tone":"warm","updatedAt":"T2"},"error":null}"#.utf8))
            }
            reads += 1
            // First read: chips on (absent). The other session then turns them off.
            let body = reads == 1
                ? #"{"data":{"tone":"warm","updatedAt":"T0"},"error":null}"#
                : #"{"data":{"tone":"warm","followUpChips":false,"updatedAt":"T1"},"error":null}"#
            let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(body.utf8))
        }
        _ = try await makeRepo().setReminderSuggestionsEnabled(false)

        #expect(puts.count == 2)
        let retry = try #require(try JSONSerialization.jsonObject(with: puts[1]) as? [String: Any])
        #expect(retry["followUpChips"] as? Bool == false)
        let reminder = try #require(retry["reminderSuggestions"] as? [String: Any])
        #expect(reminder["enabled"] as? Bool == false)
        #expect(retry["baseUpdatedAt"] as? String == "T1")
    }
}

// swiftlint:enable force_unwrapping
