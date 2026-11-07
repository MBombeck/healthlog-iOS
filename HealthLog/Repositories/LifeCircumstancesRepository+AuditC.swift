import Foundation

/// **AUDITC (1.5.0, #132 with the tightenings of 16.10.)** — the AUDIT-C
/// writes.
///
/// - `POST /api/anamnesis/audit-c`: the three answers. `locale` is the
///   instrument's `locale` exactly as the read route offered it (never the
///   device language): the server refuses any other wording with 422,
///   because the cut-off belongs to the wording that was answered.
///   `takenAt` is the moment of the first attempt, never later than now.
///   `externalId` makes a retry safe: the server answers a replay with 200
///   and the stored result, which counts as success.
/// - `DELETE /api/anamnesis/audit-c/{id}`: removes one entry, also one whose
///   answers the server can no longer open.
///
/// No outbox, like every other life-circumstance write: a failed attempt
/// stays on the form with its reason, and the retry carries the same
/// `externalId`.
public extension LifeCircumstancesRepository {
    internal static let auditCPath = "/api/anamnesis/audit-c"

    /// Sends the answers and returns the result the server scored.
    func submitAuditC(_ submission: AuditCSubmission) async throws -> AuditCResult {
        let request: APIRequest<AuditCResultEnvelope> = try .post(Self.auditCPath, body: AuditCBody(submission))
        return try await api.send(request).result
    }

    func removeAuditC(id: String) async throws {
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? id
        let request: APIRequest<EmptyResponse> = .delete("\(Self.auditCPath)/\(escaped)")
        _ = try await api.send(request)
    }
}

/// One AUDIT-C submission, fixed at the first attempt so that a retry sends
/// the same entry.
public struct AuditCSubmission: Sendable, Equatable {
    /// Points per item, in item order.
    public let items: [Int]
    public let takenAt: Date
    public let timeZone: String
    /// The instrument's `locale`, unchanged.
    public let locale: String
    public let externalId: String

    public init(items: [Int], takenAt: Date, timeZone: String, locale: String, externalId: String) {
        self.items = items
        self.takenAt = takenAt
        self.timeZone = timeZone
        self.locale = locale
        self.externalId = externalId
    }
}

/// The wire body of `POST /api/anamnesis/audit-c`.
struct AuditCBody: Encodable {
    let items: [Int]
    let takenAt: String
    let tz: String
    let locale: String
    let source = "IOS"
    let externalId: String

    init(_ submission: AuditCSubmission) {
        items = submission.items
        // `2026-11-05T09:30:00.000Z` (UTC), the form the contract's pattern accepts.
        takenAt = ISO8601DateFormatter.fractional.string(from: submission.takenAt)
        tz = submission.timeZone
        locale = submission.locale
        externalId = submission.externalId
    }
}

/// `{ result }` of the 200 (replay) and the 201 (stored) answer alike.
struct AuditCResultEnvelope: Decodable {
    let result: AuditCResult
}
