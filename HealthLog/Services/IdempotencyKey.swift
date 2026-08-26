import Foundation

/// Deterministischer Idempotency-Key-Manager.
/// Per Operation einmal generiert + persistiert (siehe `OutboxStore`), bis 2xx-Response.
public struct IdempotencyKey: Sendable, Hashable {
    public let raw: String

    public init(raw: String = UUID().uuidString.lowercased()) {
        self.raw = raw
    }
}

public extension IdempotencyKey {
    var headerValue: String {
        raw
    }

    /// **No key at all** — the request goes out without an `Idempotency-Key`
    /// header.
    ///
    /// For routes that state they do not evaluate one and whose payload carries
    /// its own identity instead. `POST /api/insights/ecg` (GH #74, server
    /// v1.35.3) is the first: an ECG recording is identified by its
    /// `externalRecordingId` plus a unique index on
    /// `(userId, source, recordedAt, samplingFrequency)`, so a retry lands on
    /// the same row structurally — stronger than a cached response, and it
    /// makes the header pure overhead.
    ///
    /// ``APIClient`` omits the header for an empty value rather than sending a
    /// blank one, so this is genuinely "absent", not "present and useless".
    static let notSent = IdempotencyKey(raw: "")
}
