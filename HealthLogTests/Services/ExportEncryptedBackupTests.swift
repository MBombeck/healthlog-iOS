import Foundation
@testable import HealthLog
import Testing

/// 7.9 — passphrase-encrypted backup (`POST /api/export/encrypted`, HLX1
/// archive). Pins the request the ``ExportService`` builds: the POST path, the
/// `application/octet-stream` Accept, the `{ passphrase }` body, and the
/// Content-Disposition filename parse (+ `.hlx` fallback). The archive itself is
/// opaque binary the server seals — iOS only ships the passphrase and persists
/// the returned bytes.
@Suite("ExportService.encryptedBackup")
struct ExportEncryptedBackupTests {
    /// Captures the download request the service issues and returns a canned
    /// binary archive response. `@unchecked Sendable` — actor-driven, serial.
    private final class CapturingDownloadClient: APIClientProtocol, @unchecked Sendable {
        var capturedPath: String?
        var capturedMethod: HTTPMethod?
        var capturedAccept: String?
        var capturedBody: Data?
        let response: (Data, HTTPURLResponse)

        init(response: (Data, HTTPURLResponse)) {
            self.response = response
        }

        func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
            throw HLError.canceled
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

        func download(_ request: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            capturedPath = request.path
            capturedMethod = request.method
            capturedAccept = request.extraHeaders["Accept"]
            capturedBody = request.body
            return response
        }
    }

    private struct PassphraseBody: Decodable {
        let passphrase: String
    }

    private nonisolated static func archiveResponse(
        filename: String? = "healthlog-backup-2026-07-01.hlx"
    ) -> (Data, HTTPURLResponse) {
        var headers = ["Content-Type": "application/octet-stream"]
        if let filename {
            headers["Content-Disposition"] = "attachment; filename=\"\(filename)\""
        }
        // swiftlint:disable force_unwrapping
        let url = URL(string: "https://test.healthlog.local/api/export/encrypted")!
        let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!
        // swiftlint:enable force_unwrapping
        return (Data([0x48, 0x4C, 0x58, 0x31]), http) // (Data, HTTPURLResponse) — "HLX1" magic
    }

    @Test("POST /api/export/encrypted with octet-stream Accept + passphrase body")
    func requestShape() async throws {
        let client = CapturingDownloadClient(response: Self.archiveResponse())
        let service = ExportService(api: client)

        let backup = try await service.downloadEncryptedBackup(passphrase: "correct horse battery staple")

        #expect(client.capturedPath == "/api/export/encrypted")
        #expect(client.capturedMethod == .post)
        #expect(client.capturedAccept == "application/octet-stream")

        let body = try #require(client.capturedBody)
        let decoded = try JSONDecoder().decode(PassphraseBody.self, from: body)
        #expect(decoded.passphrase == "correct horse battery staple")
        #expect(!backup.data.isEmpty)
    }

    @Test("Content-Disposition filename is used for the archive")
    func filenameFromDisposition() async throws {
        let client = CapturingDownloadClient(
            response: Self.archiveResponse(filename: "healthlog-backup-2026-06-02.hlx")
        )
        let service = ExportService(api: client)
        let backup = try await service.downloadEncryptedBackup(passphrase: "pw")
        #expect(backup.suggestedFilename == "healthlog-backup-2026-06-02.hlx")
    }

    @Test("Missing Content-Disposition falls back to a deterministic .hlx name")
    func filenameFallback() async throws {
        let client = CapturingDownloadClient(response: Self.archiveResponse(filename: nil))
        let service = ExportService(api: client)
        let backup = try await service.downloadEncryptedBackup(passphrase: "pw")
        #expect(backup.suggestedFilename.hasPrefix("healthlog-backup-"))
        #expect(backup.suggestedFilename.hasSuffix(".hlx"))
    }
}
