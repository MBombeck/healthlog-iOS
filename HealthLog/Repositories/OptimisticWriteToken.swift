import Foundation

// CU-20 (#69) — optimistic concurrency (`baseUpdatedAt`) for the eight guarded
// routes. Server contract verified against
// `<server-repo>/src/lib/optimistic-lock.ts`
// (`takeBaseToken` :51, `invalidBaseTokenError` :78, `guardedRowUpdate` :107,
// `guardedUserUpdate` :148).
//
// The contract in three lines:
//
// | Client sends              | Server does                                     |
// |---------------------------|-------------------------------------------------|
// | field **omitted**         | 200, UNCONDITIONAL write, echoes fresh `updatedAt` |
// | valid ISO-8601 string     | guarded write: 200 (fresh token) or 409          |
// | `null` / number / garbage | **422 `invalid_base_updated_at`**                |
//
// A 409 means **nothing was written** and the body carries NO fresh token
// (`optimistic-lock.ts:139` calls `run.freshToken()` only on the success arm),
// so the only way back in is a re-GET.

// MARK: - Falle 1 — a `null` token is a 422, not a tokenless write

/// A guarded write body: `Payload`'s own JSON object **plus** an optional
/// top-level `baseUpdatedAt` key.
///
/// **Why this type exists at all.** The server's `takeBaseToken` branches on
/// `"baseUpdatedAt" in record` and then on `typeof baseUpdatedAt !== "string"`
/// (`optimistic-lock.ts:51-72`). A JSON `null` therefore does **not** mean "no
/// token" — it is a hard `422 invalid_base_updated_at`. The field must be
/// *absent from the JSON*, not present-and-null.
///
/// That is exactly the distinction a Swift `Encodable` gets wrong by default:
/// the synthesized `encode(to:)` for an `Optional` property emits
/// `"baseUpdatedAt": null`, and even a hand-written encoder gets it wrong the
/// moment someone reaches for `encode` instead of `encodeIfPresent`. Rather
/// than rely on every one of the eight call sites remembering that, the key is
/// only ever written *inside* an `if let` here — there is no code path in this
/// type that can emit a null token, so the mistake is structurally impossible
/// rather than merely discouraged.
///
/// **How the merge works.** `payload.encode(to: encoder)` writes the payload's
/// own keys into the encoder's keyed container; re-entering
/// `encoder.container(keyedBy:)` with a different key type addresses the *same*
/// underlying object storage, so the token lands as a sibling of the payload's
/// fields rather than nested under one. `Payload` must therefore encode as a
/// JSON **object** — all eight guarded bodies do (seven structs plus the
/// coach-prefs `[String: HLJSONValue]` dictionary, which encodes into a keyed
/// container too). An array/scalar payload would be a programmer error and is
/// documented as unsupported.
public struct OptimisticWriteBody<Payload: Encodable & Sendable>: Encodable, Sendable {
    /// The route's own request body, encoded verbatim.
    public let payload: Payload
    /// The token echoed from the last GET / write response. `nil` means the
    /// caller has no token yet (never-saved surface, or a token invalidated by
    /// a DELETE reset) — the key is then **omitted** and the server performs
    /// the documented unconditional write.
    public let baseUpdatedAt: String?

    public init(payload: Payload, baseUpdatedAt: String?) {
        self.payload = payload
        self.baseUpdatedAt = baseUpdatedAt
    }

    private enum TokenKey: String, CodingKey {
        case baseUpdatedAt
    }

    public func encode(to encoder: Encoder) throws {
        try payload.encode(to: encoder)
        // The ONLY write of this key in the codebase, and it is unreachable
        // when the token is absent. No `encodeNil`, no `encode(Optional)`.
        guard let baseUpdatedAt else { return }
        var container = encoder.container(keyedBy: TokenKey.self)
        try container.encode(baseUpdatedAt, forKey: .baseUpdatedAt)
    }
}

// MARK: - Conflict identification

/// The eight guarded routes and the `meta.errorCode` each returns on 409.
/// Verified pairwise against the server routes (WIRE-SHAPES-v134 §7).
/// `APIClient` already lifts `meta.errorCode` into `HLError.server(code:)`.
public enum OptimisticConflictCode {
    public static let coachPrefs = "coach_prefs_conflict"
    public static let modules = "modules_conflict"
    public static let notificationPrefs = "notification_prefs_conflict"
    public static let aboutMe = "about_me_conflict"
    public static let dashboardLayout = "dashboard_layout_conflict"
    public static let insightsLayout = "insights_layout_conflict"
    public static let medicationLayout = "medication_layout_conflict"
    public static let moodTagLayout = "mood_tag_layout_conflict"
    /// v1.35.0 (GH #83) — `PATCH /api/auth/me/health-score-config`, guarding the
    /// same `User.updatedAt` column as the seven above.
    public static let healthScoreConfig = "health_score_config_conflict"

    /// The single 422 code the server returns for a malformed token. Should be
    /// unreachable from this client (see ``OptimisticWriteBody``); treated as a
    /// non-retriable bug signal if it ever fires.
    public static let invalidBaseToken = "invalid_base_updated_at"
}

public extension HLError {
    /// `409` + the given route's conflict `errorCode` — i.e. the guarded write
    /// was rejected and **nothing was persisted**.
    func isOptimisticConflict(_ code: String) -> Bool {
        if case .server(409, code, _) = self { return true }
        return false
    }

    /// `422 invalid_base_updated_at` — the client sent a token the server could
    /// not parse (a `null`, a number, an unparsable string). Structurally
    /// unreachable via ``OptimisticWriteBody``; surfaced so a regression is
    /// loud instead of silent.
    var isInvalidBaseToken: Bool {
        if case .server(422, OptimisticConflictCode.invalidBaseToken, _) = self { return true }
        return false
    }
}

// MARK: - Falle 2 — bounded retry, because a re-GET can hand back the SAME token

/// Outcome of a bounded guarded-write loop, for logging/telemetry at the call
/// site. Not user-facing.
public enum OptimisticRetryStop: String, Sendable {
    /// The re-GET returned the identical token we just conflicted on, so
    /// retrying would send the same request and get the same 409 forever.
    case tokenDidNotAdvance
    /// The attempt budget was spent.
    case attemptsExhausted
}

/// Runs a guarded write, and on a `409` re-reads and retries — **at most
/// `maxAttempts` times**, then fails honestly.
///
/// **Why this is bounded rather than a `while true`.** Seven of the eight
/// routes guard the *same* `User.updatedAt` column, so any unrelated write to
/// the user row rotates the token for all seven. Worse, three of the GETs
/// (`dashboard/widgets`, `insights/layout`, `medications/layout`) are served
/// from a 300 s server-side cache that is invalidated **only by their own**
/// writes (`src/lib/cache/invalidate.ts:230/260/270`). So a `PUT
/// /api/auth/me/coach-prefs` advances `User.updatedAt` without evicting the
/// widgets cache, and the client's post-409 re-GET can keep returning the very
/// same stale token for up to five minutes. The textbook
/// conflict → re-read → retry loop is an infinite loop under exactly that
/// condition.
///
/// **No client-side bypass exists** — this was checked against the server
/// source rather than assumed. All three cached GET handlers take no
/// `NextRequest` at all (`widgets/route.ts:182`, `insights/layout/route.ts:120`,
/// `medications/layout/route.ts:77`), so they cannot inspect headers or query
/// params; the read-through helper `cached(...)`
/// (`src/lib/cache/server-cache.ts:726`) exposes no force/bypass option, and
/// the cache key is the bare `user.id`, so the client cannot vary it into a
/// miss either. A forced refresh would need a server change.
///
/// So we do two things instead:
///
/// 1. **Short-circuit the useless retry.** If the re-GET hands back a token
///    equal to the one that just conflicted, the next attempt is provably
///    identical — stop immediately rather than burning the budget.
/// 2. **Fail visibly.** After the budget, throw ``HLError/writeConflictUnresolved(_:)``
///    so the surface tells the user their change was not saved. We deliberately
///    do **not** fall back to a tokenless (unconditional) write: that would
///    overwrite whatever the other session just wrote, which is precisely the
///    silent clobber this whole unit exists to stop. A visible failure the user
///    can retry beats a silent loop *and* beats a silent overwrite.
///
/// - Parameters:
///   - conflictCode: the route's `meta.errorCode` (see ``OptimisticConflictCode``).
///   - maxAttempts: total write attempts, including the first. Default 2.
///   - token: the token to send on the first attempt; `nil` = unconditional.
///   - write: performs the write with the supplied token and returns its result.
///     Re-invoked with a fresh token after a conflict, so it must re-derive its
///     body from whatever `reread` refreshed.
///   - reread: re-reads the surface after a conflict and returns the fresh
///     token, re-applying the pending change to the caller's state as a side
///     effect. Returning `nil` (surface reset / never-saved) makes the next
///     attempt unconditional.
///
/// The `isolation` parameter lets the closures run in the caller's actor
/// isolation, so a repository can mutate its own stored state inside them
/// without tripping Swift 6 strict concurrency.
public func withOptimisticConflictRetry<Value>(
    conflictCode: String,
    maxAttempts: Int = 2,
    token: String?,
    isolation: isolated (any Actor)? = #isolation,
    write: (String?) async throws -> Value,
    reread: () async throws -> String?
) async throws -> Value {
    var current = token
    var attempt = 0
    while true {
        attempt += 1
        do {
            return try await write(current)
        } catch let error as HLError where error.isOptimisticConflict(conflictCode) {
            guard attempt < max(1, maxAttempts) else {
                throw conflictGiveUp(conflictCode, stop: .attemptsExhausted)
            }
            let fresh = try await reread()
            guard fresh != current else {
                // The 300 s cache handed back the token we just conflicted on.
                // Retrying is provably the same request; stop now.
                throw conflictGiveUp(conflictCode, stop: .tokenDidNotAdvance)
            }
            current = fresh
        }
    }
}

private func conflictGiveUp(_ conflictCode: String, stop: OptimisticRetryStop) -> HLError {
    // Both values are fixed operator-grade literals from this file's own enums
    // (a route conflict code and a stop reason) — no user data, no identifiers.
    // swiftlint:disable:next hllog_public_privacy_interpolation
    HLLog.api.warning(
        "Optimistic write gave up: code=\(conflictCode, privacy: .public) stop=\(stop.rawValue, privacy: .public)"
    )
    return .writeConflictUnresolved(conflictCode)
}
