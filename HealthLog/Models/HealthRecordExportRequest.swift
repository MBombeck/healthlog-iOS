import Foundation

/// Request body for `POST /api/export/health-record`
/// (`src/lib/validations/health-record-export.ts`, server v1.32.39).
///
/// **CU-11 — the shape changed and both iOS callers were broken by it.** The
/// grouped `sections` object and `includeAiSummary` are **gone** server-side,
/// `selection` is **required**, and the schema is `.strict()`, so the two live
/// call sites failed for two different reasons and both answered `422`:
///
///   - ``DoctorReportService`` sent `{format, range, locale}` — no `selection`
///     at all, so it died on the required-field check.
///   - ``ExportService`` (via the health-record package screen) sent the removed
///     `sections` tree, so it died on the unknown-key check.
///
/// The scope now rides as the shared ``ReportSelection`` (CU-01): membership is
/// inclusion, absence is exclusion, and an empty `leaves` array is legal and
/// means *no health data*. The old `sections` tree resolved an absent key to
/// "included", which is precisely the defect the v2 selection removes — so
/// there is no compatibility arm here, and reintroducing `sections` is a
/// pinned test failure, not a silent regression.
///
/// **Fields verified against the live server schema** (the brief left this
/// open): `range` and `locale` are still accepted — both are `.optional()` on
/// `exportSelectionSchema`, and `docs/api/openapi.yaml` lists them inside the
/// same `additionalProperties: false` object. So are `practiceName`,
/// `includeCharts` and the FHIR-only `germanAtc`. Every absent optional is
/// omitted entirely (never `null`) so `.strict()` never sees a stray key.
///
/// `format: "package"` returns `application/zip` (report.pdf + bundle.json +
/// README.txt). `pdf` → `application/pdf`, `fhir` → `application/fhir+json`.
public struct HealthRecordExportRequest: Encodable, Sendable {
    /// The wire `format` enum. Same closed set the saved report profile speaks
    /// (`z.enum(["pdf","fhir","package"])`), so it is the CU-01 ``ReportFormat``
    /// rather than a second copy that could drift from it.
    public typealias Format = ReportFormat

    /// `range` — optional, `.strict()`: `startDate?` / `endDate?` (ISO+offset),
    /// `days?` int 1...365. (Note the 365 cap here is distinct from share-link's 90.)
    public struct Range: Encodable, Sendable {
        public let startDate: String?
        public let endDate: String?
        public let days: Int?

        public init(startDate: String? = nil, endDate: String? = nil, days: Int? = nil) {
            self.startDate = startDate
            self.endDate = endDate
            self.days = days
        }

        private enum CodingKeys: String, CodingKey {
            case startDate, endDate, days
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(startDate, forKey: .startDate)
            try c.encodeIfPresent(endDate, forKey: .endDate)
            try c.encodeIfPresent(days, forKey: .days)
        }
    }

    public let format: Format
    /// **Required.** The leaf inclusion list — a scope has to be stated. There
    /// is no server-side default and no "omit for everything" arm.
    public let selection: ReportSelection
    public let range: Range?
    public let locale: String?
    public let practiceName: String?
    public let includeCharts: Bool?
    /// FHIR only — derives from a German-region locale when omitted.
    public let germanAtc: Bool?

    public init(
        format: Format,
        selection: ReportSelection,
        range: Range? = nil,
        locale: String? = nil,
        practiceName: String? = nil,
        includeCharts: Bool? = nil,
        germanAtc: Bool? = nil
    ) {
        self.format = format
        self.selection = selection
        self.range = range
        self.locale = locale
        self.practiceName = practiceName
        self.includeCharts = includeCharts
        self.germanAtc = germanAtc
    }

    private enum CodingKeys: String, CodingKey {
        case format, selection, range, locale, practiceName, includeCharts, germanAtc
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // `format` + `selection` are required; every other field is omitted
        // entirely when unset so the server applies its documented defaults and
        // `.strict()` never sees a stray key (no `userId`, no nulls, and — the
        // whole point of CU-11 — no `sections`, no `includeAiSummary`).
        try c.encode(format, forKey: .format)
        try c.encode(selection, forKey: .selection)
        try c.encodeIfPresent(range, forKey: .range)
        try c.encodeIfPresent(locale, forKey: .locale)
        try c.encodeIfPresent(practiceName, forKey: .practiceName)
        try c.encodeIfPresent(includeCharts, forKey: .includeCharts)
        try c.encodeIfPresent(germanAtc, forKey: .germanAtc)
    }
}

/// The one `422` class `POST /api/export/health-record` distinguishes beyond a
/// plain schema rejection.
///
/// **Wire detail — verified against the server, and deliberately different from
/// the sibling route.** CU-01 found that the three `report-selection.*` codes
/// ride in the envelope's `error` *string*, because that route `throw`s
/// `HttpError(422, "<code>")` and `api-handler.ts` serialises a thrown
/// `HttpError` as `{ data: null, error: <message> }` with **no `meta`**.
///
/// This route does not throw. It returns
/// `apiError("Unknown selection leaf: …", 422, { errorCode: … })`, and
/// `buildJsonErrorResponse` (`api-response.ts:143-160`) attaches the meta
/// object, so the code really does arrive as `meta.errorCode` here — which
/// ``APIClient`` already prefers over the top-level key when building
/// ``HLError/server(status:code:message:)``.
///
/// ``mapped(_:)`` nonetheless matches **both** places, exactly as
/// ``ReportSelectionError`` does: the code in `meta.errorCode`, the code
/// verbatim in the `error` string, and today's human message prefix. Should the
/// route ever be rewritten to `throw` like its sibling — the plausible
/// direction, since that is the house style on the selection routes — the code
/// would silently move into the `error` string, and no iOS change would be
/// needed for iOS to keep recognising it.
public enum HealthRecordExportError: Error, Sendable, Equatable {
    /// `422 export.selection.unknown_leaf` — the app sent a leaf id this server
    /// build does not know. The recovery is to re-read the live vocabulary from
    /// `GET /api/meta/capabilities` (`share.leaves`) and rebuild the selection
    /// from it — never to guess, and never to fall back to a local list.
    case unknownLeaf

    /// Wire code as the route emits it.
    public var wireCode: String {
        "export.selection.unknown_leaf"
    }

    /// Recognise the class in a raw error, or return the error untouched.
    /// Anything that is not a `422` carrying the code passes through as-is, so
    /// transport failures, 401s and 5xx keep their existing handling.
    public static func mapped(_ error: Error) -> Error {
        guard let hlError = error as? HLError,
              case let .server(status, code, message) = hlError,
              status == 422 else
        {
            return error
        }
        let wireCode = Self.unknownLeaf.wireCode
        // Three places, in the order they are plausible: today's `meta.errorCode`,
        // the code carried verbatim in the `error` string (what a rewrite to
        // `throw HttpError` would produce, cf. the report-selection routes), and
        // today's human message.
        if code == wireCode || message == wireCode || message.hasPrefix("Unknown selection leaf") {
            return Self.unknownLeaf
        }
        return error
    }
}
