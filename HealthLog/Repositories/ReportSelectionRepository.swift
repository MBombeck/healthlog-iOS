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
/// **This route is not in the OpenAPI.** The wire shape above is taken verbatim
/// from the catch-up brief (block A2) and cross-checked against the server
/// route; nothing is inferred beyond it.
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
    /// - Throws: ``ReportSelectionError`` for the three documented `422`
    ///   classes; any other transport/server failure passes through as the
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

/// The three `422` classes `PUT /api/auth/me/report-selection` distinguishes.
///
/// They are genuinely different failures and must not collapse into one banner:
/// - ``invalidJSON`` and ``invalidShape`` are **client bugs** — the body never
///   should have been sent. Surface them as a defect, do not offer "try again".
/// - ``unknownLeaves`` is a **contract mismatch**: the app sent a leaf id this
///   server build does not know. The recovery is to re-read the live vocabulary
///   from `GET /api/meta/capabilities` (`share.leaves`) and let the user
///   re-choose — never to silently drop the offending ids, which would narrow a
///   scope the user did express.
///
/// **Wire detail (verified against the server):** these codes ride in the
/// envelope's top-level `error` **string**, not in `meta.errorCode` — the route
/// throws `HttpError(422, "<code>")` and the handler serialises that message
/// verbatim. ``mapped(_:)`` therefore matches `HLError.server`'s `code` *and*
/// `message`, so a later server change that promotes the code into
/// `meta.errorCode` needs no iOS change.
public enum ReportSelectionError: Error, Sendable, Equatable {
    /// `422 report-selection.body.invalid_json` — the body was not JSON at all.
    case invalidJSON
    /// `422 report-selection.body.invalid_shape` — JSON, but not a valid v2
    /// profile (wrong `v`, missing/extra key, `rangeDays` out of 1…365, a leaf
    /// id outside 1…64 chars, more than 91 leaves …).
    case invalidShape
    /// `422 report-selection.leaves.unknown` — one or more leaf ids are not in
    /// the server's catalogue. The server names them in its log, not in the
    /// response body, so the ids are not recoverable client-side.
    case unknownLeaves

    /// Wire codes, in the order they are matched.
    public var wireCode: String {
        switch self {
        case .invalidJSON: "report-selection.body.invalid_json"
        case .invalidShape: "report-selection.body.invalid_shape"
        case .unknownLeaves: "report-selection.leaves.unknown"
        }
    }

    /// Recognise one of the three classes in a raw error, or return the error
    /// untouched. Never invents a class: anything that is not a `422` carrying
    /// one of the three codes passes through as-is, so transport failures,
    /// 401s and 5xx keep their existing handling (incl. Outbox eligibility).
    static func mapped(_ error: Error) -> Error {
        guard let hlError = error as? HLError,
              case let .server(status, code, message) = hlError,
              status == 422 else
        {
            return error
        }
        let match = [Self.invalidJSON, .invalidShape, .unknownLeaves]
            .first { code == $0.wireCode || message == $0.wireCode }
        return match ?? error
    }
}
