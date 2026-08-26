import Foundation

/// **v0.8.0 W11 — self-hosted avatar (server v1.5.5).**
///
/// Wraps the three avatar endpoints the server shipped to replace the
/// Gravatar third-party leak (v0.6.2 removed the email-hash egress):
///
///  - `POST   /api/user/avatar`          — multipart upload, field `file`.
///  - `DELETE /api/user/avatar`          — clears the stored bytes.
///  - `GET    /api/user/avatar/{userId}` — owner-scoped image bytes.
///
/// Every call rides the project's `APIClient`, so it inherits the **pinned**
/// `URLSession` (SPKI cert-pin for the managed host), the Bearer token from the
/// Keychain, and the `X-Device-Id` breadcrumb. The image bytes are
/// PHI-adjacent and the GET is owner-scoped + authenticated — fetching them
/// through `APIClient.download` (rather than a bare `URL` in `AsyncImage`)
/// is what keeps auth + cert-pinning on the read leg. A plain `AsyncImage`
/// would carry neither.
///
/// The upload POST gets an `Idempotency-Key` automatically (`APIClient`
/// stamps every POST/PUT/PATCH) so a retried upload after a flaky response
/// doesn't double-write.
public actor AvatarRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// Result of a successful upload — mirrors the server's `UploadResponse`
    /// (`{ avatarUrl, contentType, updatedAt }`). `avatarUrl` carries the
    /// fresh `?v=<updatedAtMs>` cache-buster so the caller can invalidate the
    /// previously-cached bytes and refetch.
    public struct UploadResult: Decodable, Sendable, Equatable {
        public let avatarUrl: String
        public let contentType: String?
        public let updatedAt: Date?
    }

    /// Multipart upload of `imageData` (already-encoded JPEG/PNG/WebP bytes).
    /// `mimeType` is informational on the wire — the server sniffs the magic
    /// bytes — but we send the honest type so a correct multipart part is
    /// produced.
    ///
    /// Server limits: ≤ 2 MiB, ≤ 2048×2048, `image/jpeg|png|webp`. The caller
    /// (`AvatarUploadController`) downscales + recompresses before handing the
    /// bytes here so a normal pick stays well inside the cap.
    @discardableResult
    public func upload(imageData: Data, mimeType: String, fileName: String = "avatar.jpg") async throws -> UploadResult {
        let boundary = "HLAvatarBoundary-\(UUID().uuidString)"
        let body = Self.multipartBody(
            fieldName: "file",
            fileName: fileName,
            mimeType: mimeType,
            payload: imageData,
            boundary: boundary
        )
        let req: APIRequest<UploadResult> = APIRequest(
            method: .post,
            path: "/api/user/avatar",
            body: body,
            // Overrides APIClient's default `application/json` Content-Type for
            // the body — applied after the JSON default in `buildURLRequest`,
            // so the multipart boundary wins. `Accept: application/json` so the
            // `{ data: UploadResult }` envelope decodes.
            extraHeaders: [
                "Content-Type": "multipart/form-data; boundary=\(boundary)"
            ]
        )
        return try await api.send(req)
    }

    /// Clears the stored avatar (`DELETE /api/user/avatar`). Server returns
    /// 204 (no body); `sendVoid` treats any 2xx as success.
    public func delete() async throws {
        let req: APIRequest<EmptyPayload> = .delete("/api/user/avatar")
        try await api.sendVoid(req)
    }

    /// Fetches the raw avatar bytes for `avatarUrl` (the relative path the
    /// profile / `/me` payload returns, e.g.
    /// `/api/user/avatar/{userId}?v=1716800000000`). Goes through
    /// `APIClient.download` so the pinned session + Bearer token apply.
    ///
    /// Returns `nil` when the server has no avatar for the user (404) — the
    /// caller then paints the initials monogram. Other transport errors are
    /// rethrown so genuine failures aren't masked as "no avatar".
    public func fetchImageData(avatarURLPath: String) async throws -> Data? {
        guard let (path, query) = Self.splitPathAndQuery(avatarURLPath) else {
            return nil
        }
        let req: APIRequest<Data> = APIRequest(
            method: .get,
            path: path,
            query: query,
            extraHeaders: ["Accept": "image/*"]
        )
        do {
            let (data, _) = try await api.download(req)
            return data.isEmpty ? nil : data
        } catch let HLError.server(status, _, _) where status == 404 {
            // No avatar stored for this user — fall back to initials.
            return nil
        }
    }

    // MARK: - Helpers (pure, nonisolated for testability)

    /// Splits a relative URL path string into `(path, [(name, value)])` so it
    /// can be reconstructed as an `APIRequest` against the configured
    /// `baseURL`. Only relative paths are accepted — an absolute URL (someone
    /// handing us an attacker-controlled host) returns `nil` so the fetch is
    /// never re-pointed off the pinned origin.
    nonisolated static func splitPathAndQuery(_ raw: String) -> (String, [(String, String)])? {
        // Reject absolute URLs outright — the avatar path must stay relative
        // to the pinned baseURL. `URLComponents(string:)` on "/api/..." yields
        // a nil scheme/host, which is exactly what we require.
        guard let comps = URLComponents(string: raw), comps.scheme == nil, comps.host == nil else {
            return nil
        }
        let path = comps.path
        guard path.hasPrefix("/") else { return nil }
        let query = comps.queryItems?.map { ($0.name, $0.value ?? "") } ?? []
        return (path, query)
    }

    /// Builds a single-part `multipart/form-data` body. CRLF line endings per
    /// RFC 7578.
    nonisolated static func multipartBody(
        fieldName: String,
        fileName: String,
        mimeType: String,
        payload: Data,
        boundary: String
    ) -> Data {
        var body = Data()
        let crlf = "\r\n"
        body.append(Data("--\(boundary)\(crlf)".utf8))
        body.append(Data(
            "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\(crlf)".utf8
        ))
        body.append(Data("Content-Type: \(mimeType)\(crlf)\(crlf)".utf8))
        body.append(payload)
        body.append(Data("\(crlf)--\(boundary)--\(crlf)".utf8))
        return body
    }
}
