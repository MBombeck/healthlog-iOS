import Foundation

// swiftlint:disable force_unwrapping
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// W-SERVER-SYNC — locks the wire contract for the server-first Settings
/// toggle wired in this wave:
///
/// - **moodReminderEnabled** → `PATCH /api/user/profile { moodReminderEnabled }`
///   (`SettingsRepository.patchProfile`), reflected back in the GET profile.
///
/// D-12-05-A — the second toggle this suite guarded was Research Mode. The
/// server retired it in `0160052289e4` and iOS followed; its two cases went
/// with the repository they exercised.
///
/// Uses the real `APIClient` + stubbed `URLProtocol` (no mock server) so a
/// schema / method / path drift is caught at the wire boundary.
@Suite("Settings toggles — server-first wire contract", .serialized)
struct SettingsTogglesWireTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private func profilePayload(moodReminderEnabled: Bool) -> Data {
        Data("""
        {"data":{
            "username":"anna","displayName":"Anna","email":"anna@example.com",
            "dateOfBirth":null,"gender":null,"heightCm":175,"locale":"de",
            "timezone":"Europe/Berlin","moodReminderEnabled":\(moodReminderEnabled)
        }}
        """.utf8)
    }

    // MARK: - moodReminderEnabled

    @Test("Mood-reminder toggle PATCHes /api/user/profile with the bool")
    func moodReminderPatchesProfile() async throws {
        let repo = SettingsRepository(api: makeAPI())
        nonisolated(unsafe) var method: String?
        nonisolated(unsafe) var path: String?
        nonisolated(unsafe) var bodyJSON: [String: Any]?
        MockURLProtocol.handler = { req in
            method = req.httpMethod
            path = req.url?.path
            if let data = req.bodyOrStream() {
                bodyJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                profilePayload(moodReminderEnabled: true)
            )
        }
        let updated = try await repo.patchProfile(ProfilePatch(moodReminderEnabled: true))

        #expect(method == "PATCH")
        #expect(path == "/api/user/profile")
        #expect(bodyJSON?["moodReminderEnabled"] as? Bool == true)
        // Server response is reflected back into the model.
        #expect(updated.moodReminderEnabled == true)
    }

    @Test("Disabling the mood reminder sends false on the wire")
    func moodReminderDisableSendsFalse() async throws {
        let repo = SettingsRepository(api: makeAPI())
        nonisolated(unsafe) var bodyJSON: [String: Any]?
        MockURLProtocol.handler = { req in
            if let data = req.bodyOrStream() {
                bodyJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                profilePayload(moodReminderEnabled: false)
            )
        }
        let updated = try await repo.patchProfile(ProfilePatch(moodReminderEnabled: false))
        #expect(bodyJSON?["moodReminderEnabled"] as? Bool == false)
        #expect(updated.moodReminderEnabled == false)
    }
}

private extension URLRequest {
    /// URLSession moves a POST/PATCH body onto `httpBodyStream` by the time a
    /// `URLProtocol` sees the request, so prefer `httpBody` then drain the
    /// stream synchronously.
    func bodyOrStream() -> Data? {
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
