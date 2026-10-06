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

    /// The key for the `index`-th request of ONE logical write that the client
    /// splits into several POSTs to the same path (blood pressure: systolic,
    /// then diastolic).
    ///
    /// The server's replay cache is keyed on `(user, key, method, path)` and
    /// not on the body, so two such POSTs under one key collapse into the
    /// first one's response (T3 / public #15). Part 0 is the key itself, so a
    /// single-request write and an already-queued outbox entry are sent exactly
    /// as before; every later part derives a key from it that is just as stable
    /// across retries. `:` is in the server's key alphabet
    /// (`[A-Za-z0-9_\-:.]{8,128}`).
    func part(_ index: Int) -> IdempotencyKey {
        guard index > 0, !raw.isEmpty else { return self }
        return IdempotencyKey(raw: "\(raw):p\(index)")
    }
}
