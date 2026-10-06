import Foundation

/// #112 (server v1.38.21) — why a notification-channel test failed, as the
/// server names it.
///
/// `POST /api/settings/{webhook,ntfy}/test` answers a refused send with `502`
/// and `meta: { errorCode, upstreamStatus?, upstreamBody?, smtpCode? }`
/// (`src/lib/notifications/test-delivery-failure.ts` at v1.39.0), and a
/// private-origin refusal with `422` and its own code. Before #112 the app saw
/// a bare `HLError.server(502, …)` and showed "Server error. We're looking into
/// it." — the one thing it was not.
public struct NotificationChannelTestFailure: Sendable, Equatable {
    public let reason: Reason
    /// The HTTP status the relay answered, when it answered one.
    public let upstreamStatus: Int?
    /// The SMTP reply code, for the email channel.
    public let smtpCode: Int?
    /// At most 200 characters of the relay's own error text, already cleaned
    /// server-side and never secret-shaped. Shown as plain text only.
    public let upstreamBody: String?

    public init(reason: Reason, upstreamStatus: Int? = nil, smtpCode: Int? = nil, upstreamBody: String? = nil) {
        self.reason = reason
        self.upstreamStatus = upstreamStatus
        self.smtpCode = smtpCode
        self.upstreamBody = upstreamBody
    }

    /// The failure a test call threw, or `nil` when it was not a named test
    /// refusal (transport errors, 401, 429 and friends keep their own path).
    public init?(_ error: Error) {
        guard let detail = error as? APIRefusalDetail else { return nil }
        let meta = detail.meta
        let body = meta.upstreamBody?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            reason: Reason(wireValue: detail.code),
            upstreamStatus: meta.upstreamStatus,
            smtpCode: meta.smtpCode,
            upstreamBody: (body?.isEmpty ?? true) ? nil : body
        )
    }

    /// `meta.errorCode` on a failed test. Server-owned vocabulary: a code this
    /// build does not know is ``unknown`` and reads as a plain "test failed".
    public enum Reason: String, Sendable, Equatable, CaseIterable, TolerantServerEnum {
        case credentialsRejected = "credentials_rejected"
        case endpointNotFound = "endpoint_not_found"
        case rateLimited = "rate_limited"
        case upstreamError = "upstream_error"
        case upstreamRejected = "upstream_rejected"
        case redirected
        case timeout
        case connectionFailed = "connection_failed"
        case privateOriginNotApproved = "private_origin_not_approved"
        case privateOriginNotGrantable = "private_origin_not_grantable"
        case unknown

        public static let unknownFallback: Reason = .unknown
        public static let wireVocabulary: StaticString = "NotificationChannelTestFailure.Reason"
    }
}
