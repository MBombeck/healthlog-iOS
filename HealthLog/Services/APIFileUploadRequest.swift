import Foundation

/// **Phase 09 / plan 09-02 — a request whose body is a file, not a `Data`.**
///
/// The Apple-Health import posts an archive that is routinely hundreds of
/// megabytes and may be 1.5 GiB. Expressed as an ``APIRequest``, that body has
/// to exist as `Data` in the process before the first byte reaches the socket,
/// and the multipart envelope built around it is a second copy of the same
/// bytes. This value carries the *address* of an already-assembled body
/// instead, so the transport can hand the file to `URLSession` and let the
/// loading system stream it.
///
/// Three fields are load-bearing and none of them is decoration:
///
/// * ``bodyFileURL`` must be a file the **app** owns. The caller is responsible
///   for creating, protecting and deleting it; the transport only reads it. A
///   security-scoped URL handed straight from a document picker is not
///   acceptable here — the scope may be released before the loading system gets
///   round to reading, and the failure would be intermittent.
/// * ``byteCount`` is the exact length of that file, so the request can state a
///   `Content-Length` up front. A chunked upload of a body this size is a
///   worse bet on every proxy in the path.
/// * ``contentType`` is set verbatim. The multipart boundary lives inside it and
///   has to match the envelope the caller wrote into the file, byte for byte.
///
/// There is deliberately no `maxRetries` and no `allowsAuthenticationRecovery`.
/// Both are fixed at "no" by construction: a body this size may not be replayed
/// by anything except a person who asked for it again — see
/// ``APIClientProtocol/uploadFile(_:)``.
public struct APIFileUploadRequest<Response: Sendable>: Sendable {
    public let method: HTTPMethod
    public let path: String
    /// The app-owned file whose **entire** contents are the request body.
    public let bodyFileURL: URL
    /// Exact byte length of ``bodyFileURL``, measured by the caller while it
    /// wrote the file.
    public let byteCount: Int
    /// Sent verbatim as `Content-Type`. For multipart this carries the boundary.
    public let contentType: String
    public let extraHeaders: [String: String]
    public let idempotencyKey: IdempotencyKey

    public init(
        method: HTTPMethod,
        path: String,
        bodyFileURL: URL,
        byteCount: Int,
        contentType: String,
        extraHeaders: [String: String] = [:],
        idempotencyKey: IdempotencyKey = IdempotencyKey()
    ) {
        self.method = method
        self.path = path
        self.bodyFileURL = bodyFileURL
        self.byteCount = byteCount
        self.contentType = contentType
        self.extraHeaders = extraHeaders
        self.idempotencyKey = idempotencyKey
    }
}
