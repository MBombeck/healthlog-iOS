import Foundation

/// The **v2 report selection** — the one inclusion list every report-shaped
/// server route now speaks (CU-01 / server v1.32.39).
///
/// ```
/// { "v": 2, "leaves": ["WEIGHT", "LAB_RESULTS", …] }
/// ```
///
/// **Membership is inclusion, absence is exclusion.** An empty `leaves` array is
/// legal and means *no health data* — it is never a "send everything" default.
/// That inversion is the whole point of the shape: the flat preferences object
/// it replaces resolved an *absent* key to "included", so a caller who sent
/// nothing received the entire record.
///
/// **Deliberately standalone.** Two later units consume this type — the
/// health-record export (`POST /api/export/health-record`) and clinician share
/// links (`POST /api/share-links`) — so it must not depend on either. It knows
/// nothing about formats, ranges or UI; it is the scope and only the scope.
/// ``SavedReportProfile`` below is what wraps it with presentation choices.
///
/// **The leaf vocabulary is NOT hardcoded here, on purpose.** A leaf id is
/// either a `MeasurementType` member or one of the server's structured
/// sections, and the authoritative list is served live as
/// ``ServerCapabilities/share`` → ``ServerCapabilities/Share/leaves``. Baking a
/// copy into the app would recreate the "doc says N, server ships M" drift the
/// capabilities route exists to retire. ``validate(against:)`` therefore takes
/// the vocabulary as an argument; call it with the live capabilities set, or
/// omit it to check only the shape-level invariants.
public struct ReportSelection: Codable, Sendable, Equatable, Hashable {
    /// The wire/stored grammar version. Constant `2` — bumped server-side only
    /// when the leaf grammar itself changes, and the server schema pins it with
    /// `z.literal(2)`, so anything else is refused with `422
    /// report-selection.body.invalid_shape`.
    public static let currentVersion = 2

    /// Upper bound on `leaves`, straight off the server schema
    /// (`z.array(...).max(ALL_LEAF_IDS.length)` — 77 `MeasurementType` members
    /// plus 14 structured sections). This is a *cardinality* bound, not a
    /// vocabulary: it says how many ids may ride, never which ones.
    public static let maxLeafCount = 91

    /// Per-id length bound from the server schema (`z.string().min(1).max(64)`).
    public static let leafIdLengthRange = 1 ... 64

    /// Grammar version. Always ``currentVersion`` for a selection this app
    /// mints; decoded verbatim so a foreign/legacy blob can be *recognised* as
    /// unsupported (see ``validate(against:)``) instead of silently passing.
    public let v: Int

    /// The chosen leaf ids. Order is not significant — the server persists its
    /// own canonical catalogue ordering, so two clients that chose the same
    /// scope store the same bytes.
    public let leaves: [String]

    /// Mint a current-version selection.
    public init(leaves: [String]) {
        v = Self.currentVersion
        self.leaves = leaves
    }

    /// The empty selection: nothing chosen, so nothing is served. Legal, and
    /// explicitly *not* a fallback for "the user hasn't decided yet" — that
    /// state is `nil`, not empty.
    public static let empty = ReportSelection(leaves: [])

    /// Internal seam for decoding a blob whose `v` is not ``currentVersion``.
    init(v: Int, leaves: [String]) {
        self.v = v
        self.leaves = leaves
    }

    private enum CodingKeys: String, CodingKey {
        case v, leaves
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        leaves = try c.decode([String].self, forKey: .leaves)
    }

    // MARK: - Membership

    /// Whether this selection admits a leaf. The one question every gate asks.
    public func has(_ leaf: String) -> Bool {
        leaves.contains(leaf)
    }

    /// True iff the selection admits nothing at all.
    public var isEmpty: Bool {
        leaves.isEmpty
    }

    // MARK: - Validation

    /// A shape or vocabulary violation the server would answer with a `422`.
    /// Surfaced pre-flight so a caller can refuse locally rather than burn a
    /// round-trip on a rejection it could see coming.
    public enum ValidationIssue: Sendable, Equatable, Hashable {
        /// `v` is not ``ReportSelection/currentVersion``. Server: `422
        /// report-selection.body.invalid_shape`.
        case unsupportedVersion(Int)
        /// More than ``ReportSelection/maxLeafCount`` ids. Server: `422
        /// …invalid_shape`.
        case tooManyLeaves(count: Int, max: Int)
        /// An id outside ``ReportSelection/leafIdLengthRange``. Server: `422
        /// …invalid_shape`.
        case leafIdLengthOutOfRange(String)
        /// The same id appears more than once. The server tolerates this (it
        /// de-duplicates while minting), but it always indicates a caller bug,
        /// so we name it.
        case duplicateLeaves([String])
        /// Ids the *server's live catalogue* does not know. Only ever produced
        /// when a vocabulary was supplied to ``validate(against:)`` — this
        /// client has no opinion of its own about which ids exist. Server:
        /// `422 report-selection.leaves.unknown` (or
        /// `export.selection.unknown_leaf` on the export route).
        case unknownLeaves([String])
    }

    /// Check the selection against the wire contract.
    ///
    /// - Parameter vocabulary: the live leaf ids from
    ///   `GET /api/meta/capabilities` → `share.leaves`. Pass `nil` (the
    ///   default) to check only the shape-level invariants — never pass a
    ///   locally-authored list.
    /// - Returns: every issue found, empty when the selection would be accepted.
    public func validate(against vocabulary: Set<String>? = nil) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if v != Self.currentVersion {
            issues.append(.unsupportedVersion(v))
        }
        if leaves.count > Self.maxLeafCount {
            issues.append(.tooManyLeaves(count: leaves.count, max: Self.maxLeafCount))
        }
        for leaf in leaves where !Self.leafIdLengthRange.contains(leaf.count) {
            issues.append(.leafIdLengthOutOfRange(leaf))
        }
        let duplicates = Self.duplicates(in: leaves)
        if !duplicates.isEmpty {
            issues.append(.duplicateLeaves(duplicates))
        }
        if let vocabulary {
            let unknown = leaves.filter { !vocabulary.contains($0) }
            if !unknown.isEmpty {
                issues.append(.unknownLeaves(unknown))
            }
        }
        return issues
    }

    /// Convenience for the common gate: would the server accept this?
    public func isValid(against vocabulary: Set<String>? = nil) -> Bool {
        validate(against: vocabulary).isEmpty
    }

    /// Drop every id the live catalogue does not know, preserving order.
    ///
    /// Mirrors the server's **stored-blob** policy (unknown ids are dropped),
    /// NOT its request policy (unknown ids are refused). Use it when replaying
    /// a selection this build persisted earlier against a server that has since
    /// retired a leaf — never to paper over a fresh user choice, because that
    /// would silently narrow a scope the user did express.
    public func filtered(to vocabulary: Set<String>) -> ReportSelection {
        ReportSelection(leaves: leaves.filter { vocabulary.contains($0) })
    }

    private static func duplicates(in ids: [String]) -> [String] {
        var seen = Set<String>()
        var dupes: [String] = []
        for id in ids where !seen.insert(id).inserted && !dupes.contains(id) {
            dupes.append(id)
        }
        return dupes
    }
}

/// Output format a saved report profile renders to. Mirrors the server's closed
/// `z.enum(["pdf", "fhir", "package"])` on
/// `PUT /api/auth/me/report-selection` — deliberately closed, because this is a
/// *request* vocabulary the server validates on write, so it can never store a
/// fourth value that a read would then have to tolerate.
public enum ReportFormat: String, Codable, Sendable, CaseIterable, Equatable, Hashable {
    case pdf
    case fhir
    case package
}

/// The owner's **saved report profile** — the selection plus the presentation
/// choices the export panel restores.
///
/// Wire shape of both `GET` and `PUT /api/auth/me/report-selection`
/// (inside `{ "profile": … | null }`), and of the read-only `reportSelection`
/// mirror on `GET /api/auth/me`:
///
/// ```
/// { "v": 2, "leaves": [String], "format": "pdf"|"fhir"|"package",
///   "rangeDays": 1…365, "includeCharts": Bool }
/// ```
///
/// **All five fields are mandatory and the server schema is `.strict()`** — an
/// extra key is a `422`, a missing key is a `422`. `format` / `rangeDays` /
/// `includeCharts` are presentation, not scope: no gate reads them, which is
/// why they ride *alongside* the selection rather than inside it.
///
/// This route is **not in the OpenAPI**; the shape above is taken verbatim from
/// the catch-up brief (block A2) and verified against the server route.
public struct SavedReportProfile: Codable, Sendable, Equatable, Hashable {
    /// Server-side range bound (`z.number().int().min(1).max(365)`).
    public static let rangeDaysRange = 1 ... 365

    public let v: Int
    public let leaves: [String]
    public let format: ReportFormat
    /// Look-back window in days, 1…365.
    public let rangeDays: Int
    public let includeCharts: Bool

    /// The scope half of the profile, as the shared ``ReportSelection`` value
    /// the export and share-link units both consume.
    public var selection: ReportSelection {
        ReportSelection(v: v, leaves: leaves)
    }

    public init(
        selection: ReportSelection,
        format: ReportFormat,
        rangeDays: Int,
        includeCharts: Bool
    ) {
        v = selection.v
        leaves = selection.leaves
        self.format = format
        self.rangeDays = rangeDays
        self.includeCharts = includeCharts
    }

    private enum CodingKeys: String, CodingKey {
        case v, leaves, format, rangeDays, includeCharts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        leaves = try c.decode([String].self, forKey: .leaves)
        format = try c.decode(ReportFormat.self, forKey: .format)
        rangeDays = try c.decode(Int.self, forKey: .rangeDays)
        includeCharts = try c.decode(Bool.self, forKey: .includeCharts)
    }

    /// Pre-flight check: the selection's own issues plus the profile-level
    /// `rangeDays` bound. Same contract as ``ReportSelection/validate(against:)``
    /// — pass the live capabilities vocabulary or nothing.
    public func validate(against vocabulary: Set<String>? = nil) -> [ValidationIssue] {
        var issues = selection.validate(against: vocabulary).map(ValidationIssue.selection)
        if !Self.rangeDaysRange.contains(rangeDays) {
            issues.append(.rangeDaysOutOfRange(rangeDays))
        }
        return issues
    }

    public enum ValidationIssue: Sendable, Equatable, Hashable {
        case selection(ReportSelection.ValidationIssue)
        /// `rangeDays` outside 1…365. Server: `422
        /// report-selection.body.invalid_shape`.
        case rangeDaysOutOfRange(Int)
    }
}
