import Foundation

/// 1.2 V5 — `POST /api/insights/generate`, split out of
/// `DashboardRepository.swift` (file-length rule) together with its
/// rate-limit discipline.
extension InsightsRepository {
    /// How long the app holds off after a 429 that names no wait. The route's
    /// hourly limiter (`INSIGHTS_RATE_LIMIT_PER_HOUR`) counts per hour, and the
    /// daily token budget refusal (`insights.generate.budgetExceeded`) carries
    /// no `Retry-After` at all, so an hour is the shortest honest pause.
    static let generateCooldownWithoutRetryAfter: TimeInterval = 60 * 60

    /// Lazily generates (or returns the cached) Daily Briefing.
    ///
    /// **Endpoint:** `POST /api/insights/generate` (server-cached per-user-per-day).
    /// **Body shape:** `{ force: Bool, scope?: String, locale?: String }`. `scope` and
    /// `locale` default server-side; iOS only sets `force` to bypass the 24h cache
    /// on user-initiated refresh.
    /// **Response shape:** `{ insights: AIInsightResponse, cached: Bool, ... }` —
    /// the `insights` slot carries the strict-schema payload with the
    /// `dailyBriefing` block (see `src/lib/ai/schema.ts:299-313`).
    ///
    /// **Idempotency-Key:** required (server expects). `APIClient.send` already
    /// supplies one for every POST.
    ///
    /// **1.2 V5 — rate-limit discipline** (production 2026-10-07..09: bursts of
    /// four 429s within six seconds from 1.1.1, `insights.briefing.budget_exceeded`):
    /// - no in-request retry (`maxRetries: 0`): a generation is the most
    ///   expensive call the app makes, and a 429 without `Retry-After` used to
    ///   be re-sent three times on the transport's backoff;
    /// - after a 429 every further call is held locally until `Retry-After`
    ///   (or ``generateCooldownWithoutRetryAfter``) has passed, and fails with
    ///   the same `.rateLimited` the server would have sent;
    /// - concurrent non-forced callers share one request.
    public func generateBriefing(force: Bool = false) async throws -> AIInsightResponse {
        if let heldUntil = generateHeldUntil {
            let remaining = heldUntil.timeIntervalSince(now())
            if remaining > 0 { throw HLError.rateLimited(retryAfter: remaining) }
            generateHeldUntil = nil
        }
        if !force, let generateInFlight {
            generateJoinCount += 1
            return try await generateInFlight.value
        }
        let api = api
        let task = Task { try await Self.postGenerate(api: api, force: force) }
        if !force { generateInFlight = task }
        defer {
            if !force { generateInFlight = nil }
        }
        do {
            return try await task.value
        } catch let HLError.rateLimited(retryAfter) {
            let wait = retryAfter.flatMap { $0 > 0 ? $0 : nil } ?? Self.generateCooldownWithoutRetryAfter
            generateHeldUntil = now().addingTimeInterval(wait)
            throw HLError.rateLimited(retryAfter: retryAfter)
        }
    }

    private static func postGenerate(api: APIClientProtocol, force: Bool) async throws -> AIInsightResponse {
        struct Body: Encodable {
            let force: Bool
        }
        struct Envelope: Decodable {
            let insights: AIInsightResponse
            let cached: Bool?
        }
        let req: APIRequest<Envelope> = try .post(
            "/api/insights/generate",
            body: Body(force: force),
            maxRetries: 0
        )
        let envelope = try await api.send(req)
        return envelope.insights
    }
}
