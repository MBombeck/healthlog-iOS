import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// `GET`/`PATCH /api/user/profile` payload with an arbitrary `gender` literal
/// (already JSON-quoted, or `null`) so one fixture serves both directions.
/// Free function, not a method, so the `MockURLProtocol` handler closures below
/// don't have to capture the suite.
private func profilePayload(gender: String) -> Data {
    Data("""
    {"data":{
        "username":"anna","displayName":"Anna","email":"anna@example.com",
        "avatarUrl":null,"dateOfBirth":null,"gender":\(gender),"heightCm":175,
        "locale":"de","timezone":"Europe/Berlin","moodReminderEnabled":false,
        "timeFormat":"AUTO","dateFormat":"AUTO"
    }}
    """.utf8)
}

/// CU-17 / GH #71 — pins the **three-valued** `gender` contract in both
/// directions against the verified server source.
///
/// The read side was already safe (every decode site holds `gender` as a plain
/// `String?`), so the load-bearing half of this suite is the **write** side.
/// `src/lib/validations/auth.ts:55-64` declares
/// `gender: z.preprocess(v => v === "" ? null : v, z.enum(["MALE","FEMALE","OTHER"]).nullable().optional())`
/// and `docs/api/openapi.yaml` publishes the same uppercase enum on the PATCH
/// body and on every read projection. iOS emitted lowercase, which 422'd
/// `applyProfileUpdate` — and because that handler `safeParse`s the whole body
/// and writes one transaction, the rejection took every sibling edit of the
/// same auto-save window with it.
///
/// Uses the real `APIClient` over `MockURLProtocol` (no mock server) so a
/// spelling drift is caught at the wire boundary, not in a helper.
@Suite("gender — three-valued wire contract (#71)", .serialized)
struct GenderThreeValueWireTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    // MARK: - Write direction (the actual #71 fix)

    @Test(
        "Profile PATCH sends the server's uppercase literal for every option",
        arguments: [
            (GenderOption.male, "MALE"),
            (GenderOption.female, "FEMALE"),
            (GenderOption.other, "OTHER")
        ]
    )
    func patchSendsUppercaseLiteral(option: GenderOption, expected: String) async throws {
        let repo = SettingsRepository(api: makeAPI())
        nonisolated(unsafe) var method: String?
        nonisolated(unsafe) var path: String?
        nonisolated(unsafe) var bodyJSON: [String: Any]?
        MockURLProtocol.handler = { req in
            method = req.httpMethod
            path = req.url?.path
            if let data = req.profileBodyOrStream() {
                bodyJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                profilePayload(gender: "\"\(expected)\"")
            )
        }

        let updated = try await repo.patchProfile(ProfilePatch(gender: .some(option.serverValue)))

        #expect(method == "PATCH")
        #expect(path == "/api/user/profile")
        let sent = bodyJSON?["gender"] as? String
        #expect(sent == expected)
        // Guard the exact class of bug #71: never the pre-CU-17 lowercase
        // spelling, which `z.enum(["MALE","FEMALE","OTHER"])` rejects with 422.
        #expect(sent != expected.lowercased())
        #expect(updated.gender == expected)
    }

    @Test("\"Prefer not to say\" clears the field with an explicit JSON null")
    func unspecifiedSendsNull() async throws {
        let repo = SettingsRepository(api: makeAPI())
        nonisolated(unsafe) var bodyJSON: [String: Any]?
        MockURLProtocol.handler = { req in
            if let data = req.profileBodyOrStream() {
                bodyJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                profilePayload(gender: "null")
            )
        }

        // This is what `EditProfileScreen.buildPatch()` builds for `.unspecified`.
        let updated = try await repo.patchProfile(
            ProfilePatch(gender: .some(GenderOption.unspecified.serverValue))
        )

        #expect(bodyJSON?.keys.contains("gender") == true)
        // Explicit null, never the empty string — the server folds `""` to null
        // since v1.34.x, but we do not lean on that normalisation.
        #expect(bodyJSON?["gender"] is NSNull)
        #expect(bodyJSON?["gender"] as? String == nil)
        #expect(updated.gender == nil)
    }

    @Test("serverValue is exactly the published enum, or nil")
    func serverValueVocabulary() {
        #expect(GenderOption.male.serverValue == "MALE")
        #expect(GenderOption.female.serverValue == "FEMALE")
        #expect(GenderOption.other.serverValue == "OTHER")
        #expect(GenderOption.unspecified.serverValue == nil)
    }

    // MARK: - Read direction

    @Test("GET /api/user/profile decodes gender: \"OTHER\" and maps to .other")
    func profileGetDecodesOther() async throws {
        let repo = SettingsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                profilePayload(gender: "\"OTHER\"")
            )
        }
        let profile = try await repo.profile()
        #expect(profile.gender == "OTHER")
        #expect(GenderOption(serverValue: profile.gender) == .other)
    }

    @Test("Insights-targets profile block decodes gender: \"OTHER\"")
    func insightsTargetsDecodesOther() async throws {
        let repo = InsightsTargetsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{
              "targets":[],
              "pageSummary":{"targetsMetThisWeek":0,"totalTargets":0,"streakHighlight":null},
              "bpDiastolic":null,
              "profile":{"heightCm":180,"age":42,"gender":"OTHER","glucoseUnit":"mmol/L"}
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let response = try await repo.fetch()
        #expect(response.profile?.gender == "OTHER")
    }

    @Test(
        "Every published literal round-trips, and the decode stays case-tolerant",
        arguments: [
            ("MALE", GenderOption.male), ("male", GenderOption.male),
            ("FEMALE", GenderOption.female), ("female", GenderOption.female),
            ("OTHER", GenderOption.other), ("other", GenderOption.other)
        ]
    )
    func decodeIsCaseTolerant(raw: String, expected: GenderOption) {
        #expect(GenderOption(serverValue: raw) == expected)
    }

    @Test("Encode → decode is symmetric for all three stored values")
    func encodeDecodeSymmetry() {
        for option in [GenderOption.male, .female, .other] {
            #expect(GenderOption(serverValue: option.serverValue) == option)
        }
    }

    @Test(
        "Absent / empty / unrecognised gender degrades to .unspecified, never to .male",
        arguments: [nil, "", "  ", "NON_BINARY", "space-alien"] as [String?]
    )
    func unknownDegradesToUnspecified(raw: String?) {
        let option = GenderOption(serverValue: raw)
        #expect(option == .unspecified)
        #expect(option != .male)
        #expect(option.serverValue == nil)
    }

    // MARK: - UI offers all three

    @Test("The picker vocabulary offers all three stored values plus \"no answer\"")
    func pickerOffersThirdValue() {
        // `EditProfileScreen` / `BaselineProfileStep` both iterate `allCases`.
        #expect(GenderOption.allCases == [.male, .female, .other, .unspecified])
        #expect(GenderOption.allCases.contains(.other))
    }
}

private extension URLRequest {
    /// URLSession moves a PATCH body onto `httpBodyStream` before a
    /// `URLProtocol` sees it, so prefer `httpBody` then drain the stream.
    func profileBodyOrStream() -> Data? {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return nil }
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
}

// swiftlint:enable force_unwrapping
