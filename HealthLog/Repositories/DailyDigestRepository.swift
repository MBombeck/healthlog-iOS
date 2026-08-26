import Foundation

/// Wraps `GET /api/daily/digest` (server `src/app/api/daily/digest/route.ts`) —
/// the read seam for the unified daily-value system (`TodayHeroCard`).
///
/// The route returns the `DailyDigest` DTO assembled from ALREADY-CACHED data;
/// no AI/provider call is reachable from it and nothing warms on mount, so this
/// repo is a pure read + two tiny lifecycle writes (dismiss + coach check-in).
///
/// **Cache strategy: none.** The digest is `Cache-Control: no-store` (though
/// bfcache-friendly on web); it is cheap and must reflect a fresh dismiss /
/// keep / let-go, so it is fetched directly every call rather than routed
/// through the SWR ladder.
///
/// **`nil` arms → hide the hero.** A `403` (`insights` module disabled), `404`
/// (route not deployed) or `422` maps to `nil` so the store degrades to nothing
/// rather than surfacing an error. A `200` body decodes tolerantly.
public actor DailyDigestRepository {
    private let api: APIClientProtocol

    /// ISO-8601 formatter for the coach check-in `reviewDate` re-arm. A shared,
    /// immutable `ISO8601DateFormatter` is thread-safe for formatting; the
    /// `nonisolated(unsafe)` opt-out is the sanctioned pattern for a `let`
    /// formatter (PROJECT_GUIDE.md concurrency note).
    private nonisolated(unsafe) static let iso8601 = ISO8601DateFormatter()

    /// Days pushed onto a kept plan's review checkpoint — one source of truth,
    /// mirroring the server `COACH_CHECKIN_REVIEW_DAYS` (7) the PATCH route uses.
    private static let coachCheckinReviewDays: TimeInterval = 7

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// Fetches the daily digest. Returns `nil` on the `insights` module being
    /// gated off (`403 module.disabled` → typed `HLError.moduleDisabled`) or on a
    /// `403`/`404`/`422` (route absent / rejected) so the hero hides, never errors.
    public func fetch() async throws -> DailyDigest? {
        do {
            let req: APIRequest<DailyDigest> = .get("/api/daily/digest")
            return try await api.send(req)
        } catch HLError.moduleDisabled {
            // The `insights` module is off — the daily digest's host surface.
            return nil
        } catch let HLError.server(status, _, _) where status == 403 || status == 404 || status == 422 {
            return nil
        }
    }

    /// Dismiss / mark-seen for an OBSERVATIONAL rail item (`milestone` /
    /// `ecg_new_recording` / `tension_window`). Idempotent server-side upsert.
    public func dismiss(itemKey: String) async throws {
        let req: APIRequest<EmptyResponse> = try .post(
            "/api/daily/digest/dismiss",
            body: DismissBody(itemKey: itemKey)
        )
        _ = try await api.send(req)
    }

    /// Coach check-in **keep** — re-arm the plan: `status: active` +
    /// `reviewDate` pushed out one more cycle. Recovers the plan id the caller
    /// sliced from the `coach.checkin.keep:<id>` intent.
    public func coachCheckinKeep(planId: String) async throws {
        let reviewDate = Self.iso8601.string(
            from: Date().addingTimeInterval(Self.coachCheckinReviewDays * 86400)
        )
        try await patchPlan(planId, body: PlanLifecycleBody(status: "active", reviewDate: reviewDate))
    }

    /// Coach check-in **let-go** — guilt-free retirement: `status: abandoned`,
    /// a terminal, respected outcome. The card leaves the rail on the next read.
    public func coachCheckinLetGo(planId: String) async throws {
        try await patchPlan(planId, body: PlanLifecycleBody(status: "abandoned", reviewDate: nil))
    }

    // MARK: - Private

    private func patchPlan(_ id: String, body: PlanLifecycleBody) async throws {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let req: APIRequest<EmptyResponse> = try .patch("/api/coach/plans/\(encoded)", body: body)
        _ = try await api.send(req)
    }

    private struct DismissBody: Encodable {
        let itemKey: String
    }

    /// Mirrors the server plan-lifecycle PATCH body (`status` + optional
    /// `reviewDate`). `reviewDate` is omitted when `nil` (let-go) so the server
    /// clears it via its own default path.
    private struct PlanLifecycleBody: Encodable {
        let status: String
        let reviewDate: String?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(status, forKey: .status)
            if let reviewDate { try c.encode(reviewDate, forKey: .reviewDate) }
        }

        enum CodingKeys: String, CodingKey { case status, reviewDate }
    }
}
