import Foundation

/// **CU-35 (1) — the manual sync trigger's answer.**
///
/// `POST /api/{oura,polar,strava,nightscout}/sync` (server v1.32.28) takes no
/// body and no query. A 2xx answers with
/// `{ imported: Int, failed: Bool, outcome: "empty" | "failed" | "partial" | "success" }`
/// — the shape `resolveSyncOutcome` (`src/lib/outcome/written-outcome.ts`)
/// produces. Fitbit's older `/sync` answers the same object plus a `fullSync`
/// boolean, which decodes away harmlessly here.
///
/// **These routes are not in the OpenAPI.** Every field above was read off the
/// four route files and `written-outcome.ts` directly.
///
/// **The verdict is the server's, not ours.** `outcome` is resolved server-side
/// precisely so the web card and this client cannot drift on how the same run
/// reads — a run that imported nothing because every row was refused is NOT the
/// same answer as a quiet hour. So this type never recomputes `outcome` from
/// `imported`/`failed` when the server stated one; it only derives a value when
/// the server said nothing (an older build), and it says so in the code below.
public struct ManualSyncResult: Decodable, Sendable, Equatable {
    /// Rows that genuinely reached the database this run — not the ones
    /// re-confirmed. `0` is a normal number here.
    public let imported: Int
    /// True when any part of the run did not land: a row, a collection, a leg.
    public let failed: Bool
    /// The server's own reading of the two numbers above.
    public let outcome: ManualSyncOutcome

    public init(imported: Int, failed: Bool, outcome: ManualSyncOutcome) {
        self.imported = imported
        self.failed = failed
        self.outcome = outcome
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let imported = try c.decodeIfPresent(Int.self, forKey: .imported) ?? 0
        let failed = try c.decodeIfPresent(Bool.self, forKey: .failed) ?? false
        self.imported = imported
        self.failed = failed
        // Tolerant on a GROWING enum (the A6 sweep doctrine): a value this build
        // does not know must not hard-fail the decode of an otherwise perfectly
        // readable answer. An unknown / absent verdict falls back to the same
        // classification rule the server applies, so the row still reads
        // honestly instead of throwing.
        let raw = try c.decodeIfPresent(String.self, forKey: .outcome)
        outcome = raw.flatMap(ManualSyncOutcome.init(rawValue:))
            ?? ManualSyncOutcome.derived(imported: imported, failed: failed)
    }

    private enum CodingKeys: String, CodingKey {
        case imported, failed, outcome
    }
}

/// How a sync run reads. Mirrors the server's `WrittenOutcome` union verbatim.
///
/// ``empty`` is deliberately its own state and **not** a failure: a provider
/// that finds nothing new is an honest non-event, and rendering it as a failed
/// run would be a lie in the other direction.
public enum ManualSyncOutcome: String, Sendable, Equatable, CaseIterable {
    /// Nothing written, nothing refused — there was nothing to write.
    case empty
    /// Nothing written, but rows were refused. Never a success tone.
    case failed
    /// Some written, some refused. A warning, not a tick.
    case partial
    /// Everything the run fetched was written.
    case success

    /// The server's own rule (`classifyWrittenOutcome`), used ONLY when the
    /// answer carried no readable `outcome` — never to second-guess one it did.
    static func derived(imported: Int, failed: Bool) -> ManualSyncOutcome {
        if imported <= 0 { return failed ? .failed : .empty }
        return failed ? .partial : .success
    }

    /// Whether this outcome should be presented in a failure register. `empty`
    /// is pointedly NOT one of them.
    public var isSetback: Bool {
        switch self {
        case .failed, .partial: true
        case .empty, .success: false
        }
    }
}

/// **CU-35 (1) — what the "Sync now" button has to say afterwards.**
///
/// The three server answers are three genuinely different statements and must
/// not collapse into one red line:
///
/// - ``rateLimited`` (**429 `rate_limited_self`**) is neither the user's fault
///   nor a defect. It means *you just did*. It gets a calm, friendly sentence
///   that names when it works again — never an error tone.
/// - ``upstreamUnavailable`` (**502**) is a problem at the **provider**, not in
///   this app and not on the HealthLog server. Saying "failed" here would send
///   the user hunting for something they cannot repair, so the copy names where
///   the fault actually sits.
/// - ``finished`` carries the server's `imported` + `outcome` verbatim. An
///   `outcome == .empty` renders as the normal non-event it is.
///
/// Everything else lands on ``failed`` with the already-localized user-facing
/// text of the underlying error.
public enum ManualSyncState: Sendable, Equatable {
    case idle
    case running
    case finished(ManualSyncResult)
    /// 429 — the per-user 5-per-60s budget. `retryAfter` is whatever the
    /// transport could read off `X-RateLimit-Reset` / `Retry-After`; `nil` just
    /// means the copy stays unspecific ("in a moment") rather than wrong.
    case rateLimited(retryAfter: TimeInterval?)
    /// 502 — the provider did not answer. Nothing on this side is broken.
    case upstreamUnavailable
    /// Anything else. Carries already-localized copy.
    case failed(String)

    /// Classify a thrown error into one of the three honest registers.
    ///
    /// **Why 429 arrives as ``HLError/rateLimited(retryAfter:)`` and not as a
    /// `.server(429, "rate_limited_self", …)`:** `APIClient.execute` maps the
    /// status line before the envelope is ever decoded, so `meta.errorCode`
    /// never reaches a caller on this path. That is fine here and deliberately
    /// not worked around (the transport core is not ours to refactor): these
    /// four routes emit exactly ONE 429, the self rate-limit, so the status
    /// alone is an unambiguous discriminator. The `.server(429, …)` arm below
    /// is defensive — it recognises the code should the envelope ever surface.
    public static func classify(_ error: some Error) -> ManualSyncState {
        guard let hlError = error as? HLError else {
            return .failed(String(localized: "integration.sync.failed"))
        }
        switch hlError {
        case let .rateLimited(retryAfter):
            return .rateLimited(retryAfter: retryAfter)
        case let .server(status, code, _):
            if status == 429 || code == "rate_limited_self" {
                return .rateLimited(retryAfter: nil)
            }
            if status == 502 {
                return .upstreamUnavailable
            }
            return .failed(hlError.userFacingDescription)
        default:
            return .failed(hlError.userFacingDescription)
        }
    }

    /// The result of the last completed run, when there was one.
    public var result: ManualSyncResult? {
        if case let .finished(result) = self { return result }
        return nil
    }

    /// Whether anything at all should be rendered under the button.
    public var hasMessage: Bool {
        self != .idle && self != .running
    }
}
