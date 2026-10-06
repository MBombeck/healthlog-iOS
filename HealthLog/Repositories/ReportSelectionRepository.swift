import Foundation

/// `GET | PUT /api/auth/me/report-selection` — the owner's saved report
/// profile (CU-01).
///
/// ```
/// GET  → { "profile": SavedReportProfile | null }
/// PUT  ← { v: 2, leaves: [String], format, rangeDays, includeCharts }
///      → { "profile": SavedReportProfile }
/// ```
///
/// **PUT replaces, it does not merge.** A selection is a list of what was
/// chosen, so merging a partial over a stored one would re-introduce exactly the
/// failure the v2 shape removes: a leaf staying in because the caller never
/// mentioned it. There is no `PATCH`. All five body fields are mandatory and the
/// server schema is `.strict()` — an extra key is a `422`.
///
/// **`profile: null` is the honest "never saved" state**, not an empty default.
/// A caller that gets `nil` must let the user choose a scope (or apply a *named*
/// template visibly); it must not invent one, because a scope nobody chose is
/// the defect this whole shape exists to remove.
///
/// **Contract.** The wire shape above was first taken from the catch-up brief
/// (block A2); server v1.39.0 publishes the route in `docs/api/openapi.yaml`
/// (`src/lib/openapi/routes/profile.ts`), including the refusal shapes
/// ``ReportSelectionError`` maps.
///
/// The same selection is mirrored **read-only** onto `GET /api/auth/me` as
/// `reportSelection` — see ``AuthMeServerPrefs/reportSelection``, which picks it
/// up on the hydration round-trip the settings path already makes.
public actor ReportSelectionRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// The saved profile, or `nil` when this account has never saved one.
    public func fetch() async throws -> SavedReportProfile? {
        let req: APIRequest<ReportSelectionEnvelope> = .get("/api/auth/me/report-selection")
        do {
            return try await api.send(req).profile
        } catch {
            throw ReportSelectionError.mapped(error)
        }
    }

    /// Replace the saved profile wholesale. Returns the server's canonical
    /// echo — the server persists the catalogue ordering of `leaves`, not the
    /// caller's, so two clients that chose the same scope store the same bytes.
    /// Adopt the echo rather than the value you sent.
    ///
    /// - Throws: ``ReportSelectionError`` for the three documented refusal
    ///   classes (`400`/`422`); any other transport/server failure passes through as the
    ///   original ``HLError``.
    @discardableResult
    public func replace(_ profile: SavedReportProfile) async throws -> SavedReportProfile {
        let req: APIRequest<ReportSelectionEnvelope> = try .put(
            "/api/auth/me/report-selection",
            body: profile
        )
        do {
            guard let saved = try await api.send(req).profile else {
                // A 2xx on PUT always echoes the persisted profile. A null here
                // would mean the server accepted the write and then refused to
                // name what it stored — surfaced rather than swallowed.
                throw HLError.decoding("report-selection: PUT returned a null profile")
            }
            return saved
        } catch {
            throw ReportSelectionError.mapped(error)
        }
    }
}

/// Wire envelope of both verbs: `{ "profile": … | null }`. Tolerant — a missing
/// `profile` key reads as "never saved", same as an explicit `null`.
public struct ReportSelectionEnvelope: Decodable, Sendable, Equatable {
    public let profile: SavedReportProfile?

    public init(profile: SavedReportProfile?) {
        self.profile = profile
    }

    private enum CodingKeys: String, CodingKey {
        case profile
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = try c.decodeIfPresent(SavedReportProfile.self, forKey: .profile)
    }
}

/// The three refusal classes `PUT /api/auth/me/report-selection` distinguishes.
///
/// They are genuinely different failures and must not collapse into one banner:
/// - ``invalidJSON`` and ``invalidShape`` are **client bugs** — the body never
///   should have been sent. Surface them as a defect, do not offer "try again".
/// - ``unknownLeaves(ids:)`` is a **contract mismatch**: the app sent a leaf id
///   this server build does not know. The recovery is to re-read the live
///   vocabulary from `GET /api/meta/capabilities` (`share.leaves`) and let the
///   user re-choose — never to silently drop the offending ids, which would
///   narrow a scope the user did express.
///
/// **Wire detail (#110, verified against server v1.39.0
/// `src/app/api/auth/me/report-selection/route.ts`):**
/// - `invalid_json` is `400` since the release after v1.38.15 (it was `422`),
///   with `error: "Invalid JSON body"` and the token in `meta.errorCode`.
/// - `invalid_shape` stays `422`; the token rides in `meta.errorCode` **and**
///   (unchanged) as the `error` string, with `details.issues` beside it.
/// - `leaves.unknown` stays `422`, now with a sentence in `error`, the token in
///   `meta.errorCode` and the refused ids in `meta.unknownLeaves`. The
///   transport hands that one over as ``APIRefusalDetail`` so the ids survive.
///
/// ``mapped(_:)`` therefore accepts `400` **or** `422`, matches the code first
/// (which `HLError.server` already takes from `meta.errorCode` before the
/// top-level one) and the `error` string only as the fallback an older server
/// needs.
public enum ReportSelectionError: Error, Sendable, Equatable {
    /// `400 report-selection.body.invalid_json` (`422` before the release after
    /// v1.38.15) — the body was not JSON at all.
    case invalidJSON
    /// `422 report-selection.body.invalid_shape` — JSON, but not a valid v2
    /// profile (wrong `v`, missing/extra key, `rangeDays` out of 1…365, a leaf
    /// id outside 1…64 chars, more than 91 leaves …).
    case invalidShape
    /// `422 report-selection.leaves.unknown` — one or more leaf ids are not in
    /// the server's catalogue. `ids` are the ones the server named in
    /// `meta.unknownLeaves`; empty when an older server named none.
    case unknownLeaves(ids: [String])

    /// Wire codes, in the order they are matched.
    public var wireCode: String {
        switch self {
        case .invalidJSON: "report-selection.body.invalid_json"
        case .invalidShape: "report-selection.body.invalid_shape"
        case .unknownLeaves: "report-selection.leaves.unknown"
        }
    }

    /// The statuses a refusal class may arrive with: `invalid_json` moved from
    /// `422` to `400`, and an older server still answers `422`.
    static let refusalStatuses: Set<Int> = [400, 422]

    /// Recognise one of the three classes in a raw error, or return the error
    /// untouched. Never invents a class: anything that is not a `400`/`422`
    /// carrying one of the three codes passes through as-is, so transport
    /// failures, 401s and 5xx keep their existing handling (incl. Outbox
    /// eligibility).
    static func mapped(_ error: Error) -> Error {
        if let detail = error as? APIRefusalDetail,
           refusalStatuses.contains(detail.status),
           detail.code == APIRefusalDetail.unknownLeavesCode
        {
            return unknownLeaves(ids: detail.meta.unknownLeaves ?? [])
        }
        guard let hlError = error as? HLError,
              case let .server(status, code, message) = hlError,
              refusalStatuses.contains(status) else
        {
            return error
        }
        let classes: [Self] = [.invalidJSON, .invalidShape, .unknownLeaves(ids: [])]
        let match = classes.first { code == $0.wireCode } ?? classes.first { message == $0.wireCode }
        return match ?? error
    }
}
