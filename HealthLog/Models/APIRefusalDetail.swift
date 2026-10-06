import Foundation

/// A refusal whose `meta` carries detail the surface that asked has to show —
/// more than ``HLError/server(status:code:message:)`` can hold.
///
/// Two routes need it today:
/// - `PUT /api/auth/me/report-selection` (#110): `422
///   report-selection.leaves.unknown` names the refused ids in
///   `meta.unknownLeaves`.
/// - `POST /api/settings/{webhook,ntfy}/test` (#112, server v1.38.21+): a
///   failed test answers `502` with `meta.errorCode` plus `upstreamStatus` /
///   `smtpCode` / `upstreamBody`, and a private-origin refusal answers `422`
///   with its own code.
///
/// **Opt-in per route, like ``APIRefusal``.** Promoting every refusal that
/// carries a `meta` would change the error type under callers that pattern-match
/// on `HLError.server` (the integration test routes answer `502` with the same
/// code vocabulary, and their callers read `.server`). So the transport throws
/// this only for the paths and codes listed in ``detail(path:status:meta:message:)``;
/// everything else keeps arriving as `HLError.server`, exactly as before.
public struct APIRefusalDetail: Error, Sendable, Equatable {
    public let status: Int
    /// `meta.errorCode`.
    public let code: String
    /// The envelope's `error` sentence (server prose, English).
    public let message: String
    public let meta: APIEnvelopeMeta

    public init(status: Int, code: String, message: String, meta: APIEnvelopeMeta) {
        self.status = status
        self.code = code
        self.message = message
        self.meta = meta
    }

    static let reportSelectionPath = "/api/auth/me/report-selection"
    static let unknownLeavesCode = "report-selection.leaves.unknown"
    static let channelTestPaths = ["/api/settings/webhook/test", "/api/settings/ntfy/test"]
    /// The test routes' own policy refusals (`422`), beside the `502` family.
    static let privateOriginCodes: Set<String> = [
        "private_origin_not_approved",
        "private_origin_not_grantable"
    ]

    /// The detailed refusal for this response, or `nil` when the route/code pair
    /// is not opted in (the caller then throws its generic `HLError.server`).
    /// `path` is matched as a suffix so a server mounted under a sub-path still
    /// matches.
    static func detail(path: String, status: Int, meta: APIEnvelopeMeta?, message: String) -> Self? {
        guard let meta, let code = meta.errorCode, !code.isEmpty else { return nil }
        if path.hasSuffix(reportSelectionPath), code == unknownLeavesCode {
            return Self(status: status, code: code, message: message, meta: meta)
        }
        if channelTestPaths.contains(where: { path.hasSuffix($0) }),
           status == 502 || privateOriginCodes.contains(code)
        {
            return Self(status: status, code: code, message: message, meta: meta)
        }
        return nil
    }
}
