import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **v0.8.0 W11 — AvatarRepository contract.**
///
/// Drives the real `APIClient` (not a mock-server) through `MockURLProtocol`
/// so the multipart upload, owner-scoped GET, and DELETE go over the exact
/// request-building path production uses — catching header / idempotency /
/// envelope-decode drift the way the 0.2.0 audit demands.
@Suite("AvatarRepository", .serialized)
struct AvatarRepositoryTests {
    private func makeClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    // MARK: - Upload

    @Test("Upload POSTs multipart with field 'file' + Idempotency-Key and decodes UploadResult")
    func uploadMultipart() async throws {
        let api = makeClient()
        let repo = AvatarRepository(api: api)

        nonisolated(unsafe) var capturedMethod: String?
        nonisolated(unsafe) var capturedContentType: String?
        nonisolated(unsafe) var capturedIdem: String?
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.handler = { req in
            capturedMethod = req.httpMethod
            capturedContentType = req.value(forHTTPHeaderField: "Content-Type")
            capturedIdem = req.value(forHTTPHeaderField: "Idempotency-Key")
            // URLProtocol strips httpBody into the stream; read it back.
            capturedBody = req.httpBody ?? Self.readStream(req.httpBodyStream)
            let json = #"{"data":{"avatarUrl":"/api/user/avatar/u1?v=1716800000000","contentType":"image/jpeg","updatedAt":"2026-05-28T10:00:00Z"}}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }

        let result = try await repo.upload(imageData: Data("JPEGBYTES".utf8), mimeType: "image/jpeg")

        #expect(capturedMethod == "POST")
        #expect(capturedContentType?.hasPrefix("multipart/form-data; boundary=") == true)
        #expect(capturedIdem != nil)
        let bodyString = String(bytes: capturedBody ?? Data(), encoding: .utf8) ?? ""
        #expect(bodyString.contains("name=\"file\""))
        #expect(bodyString.contains("Content-Type: image/jpeg"))
        #expect(bodyString.contains("JPEGBYTES"))
        #expect(result.avatarUrl == "/api/user/avatar/u1?v=1716800000000")
        #expect(result.contentType == "image/jpeg")
    }

    // MARK: - Delete

    @Test("Delete sends DELETE to /api/user/avatar and succeeds on 204")
    func deleteAvatar() async throws {
        let api = makeClient()
        let repo = AvatarRepository(api: api)

        nonisolated(unsafe) var capturedMethod: String?
        nonisolated(unsafe) var capturedPath: String?
        MockURLProtocol.handler = { req in
            capturedMethod = req.httpMethod
            capturedPath = req.url?.path
            return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, nil)
        }

        try await repo.delete()
        #expect(capturedMethod == "DELETE")
        #expect(capturedPath == "/api/user/avatar")
    }

    // MARK: - Fetch

    @Test("Fetch returns image bytes through the authenticated session")
    func fetchBytes() async throws {
        let api = makeClient()
        let repo = AvatarRepository(api: api)
        let payload = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02]) // JPEG-ish magic

        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedQuery: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedQuery = req.url?.query
            return (
                HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/jpeg"]
                )!,
                payload
            )
        }

        let data = try await repo.fetchImageData(avatarURLPath: "/api/user/avatar/u1?v=1716800000000")
        #expect(data == payload)
        #expect(capturedPath == "/api/user/avatar/u1")
        #expect(capturedQuery == "v=1716800000000")
    }

    @Test("Fetch returns nil on 404 so the caller falls back to initials")
    func fetch404FallsBack() async throws {
        let api = makeClient()
        let repo = AvatarRepository(api: api)
        MockURLProtocol.handler = { req in
            let json = #"{"data":null,"error":"Avatar not found"}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }
        let data = try await repo.fetchImageData(avatarURLPath: "/api/user/avatar/u1?v=1")
        #expect(data == nil)
    }

    @Test("Fetch rejects an absolute URL so the read can't be re-pointed off the pinned origin")
    func fetchRejectsAbsoluteURL() async throws {
        let api = makeClient()
        let repo = AvatarRepository(api: api)
        MockURLProtocol.handler = { req in
            Issue.record("No request should fire for an absolute URL")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let data = try await repo.fetchImageData(avatarURLPath: "https://evil.example.com/api/user/avatar/u1?v=1")
        #expect(data == nil)
    }

    // MARK: - Helpers

    @Test("splitPathAndQuery splits a relative avatar path")
    func splitPath() {
        let result = AvatarRepository.splitPathAndQuery("/api/user/avatar/u1?v=42")
        #expect(result?.0 == "/api/user/avatar/u1")
        #expect(result?.1.first?.0 == "v")
        #expect(result?.1.first?.1 == "42")
    }

    @Test("splitPathAndQuery rejects absolute + non-rooted inputs")
    func splitPathRejects() {
        #expect(AvatarRepository.splitPathAndQuery("https://x.test/a") == nil)
        #expect(AvatarRepository.splitPathAndQuery("relative/no/slash") == nil)
    }

    @Test("multipartBody embeds the field, filename, content-type and payload")
    func multipart() {
        let body = AvatarRepository.multipartBody(
            fieldName: "file",
            fileName: "avatar.jpg",
            mimeType: "image/png",
            payload: Data("ABC".utf8),
            boundary: "BNDRY"
        )
        let s = String(bytes: body, encoding: .utf8) ?? ""
        #expect(s.contains("--BNDRY\r\n"))
        #expect(s.contains("Content-Disposition: form-data; name=\"file\"; filename=\"avatar.jpg\""))
        #expect(s.contains("Content-Type: image/png"))
        #expect(s.contains("ABC"))
        #expect(s.hasSuffix("--BNDRY--\r\n"))
    }

    private static func readStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// swiftlint:enable force_unwrapping
