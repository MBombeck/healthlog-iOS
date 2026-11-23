import Foundation

/// #130 (server v1.43) — `POST /api/biomarkers/{id}/merge`, where `{id}` is the
/// marker that stays. Only when `features.biomarkerMerge` is true.
public struct BiomarkerMergeRequest: Encodable, Sendable, Equatable {
    public let sourceIds: [String]
    public let dryRun: Bool

    public init(sourceIds: [String], dryRun: Bool) {
        self.sourceIds = sourceIds
        self.dryRun = dryRun
    }

    /// The server takes 1 to 10 sources per merge.
    public static let maxSources = 10
}

/// The merge answer, or its dry-run preview (`BiomarkerMergeResult`). Rendered
/// as delivered: the counts and every conversion or refusal are the server's.
public struct BiomarkerMergeResult: Decodable, Sendable, Equatable {
    public let dryRun: Bool
    public let target: BiomarkerDTO?
    public let sources: [Source]
    public let movedReadings: Int
    public let convertedReadings: Int
    public let aliasesAdded: [String]
    /// `nil` on a dry run.
    public let mergeId: String?
    /// The panel the kept marker takes over from a merged one when it had
    /// none (server v1.47.1, #164; also on a dry run). `nil` when nothing
    /// is adopted or on an older server.
    public let adoptedPanel: String?

    public init(
        dryRun: Bool,
        target: BiomarkerDTO? = nil,
        sources: [Source],
        movedReadings: Int,
        convertedReadings: Int,
        aliasesAdded: [String] = [],
        mergeId: String? = nil,
        adoptedPanel: String? = nil
    ) {
        self.dryRun = dryRun
        self.target = target
        self.sources = sources
        self.movedReadings = movedReadings
        self.convertedReadings = convertedReadings
        self.aliasesAdded = aliasesAdded
        self.mergeId = mergeId
        self.adoptedPanel = adoptedPanel
    }

    /// One source marker as the server sees it.
    public struct Source: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let unit: String
        public let readingCount: Int
        public let conversion: Conversion
        /// Why a `refused` source cannot be converted (`unknown_analyte`,
        /// `unknown_unit`, `not_finite`); `nil` otherwise.
        public let refusal: String?

        public init(id: String, name: String, unit: String, readingCount: Int, conversion: Conversion, refusal: String? = nil) {
            self.id = id
            self.name = name
            self.unit = unit
            self.readingCount = readingCount
            self.conversion = conversion
            self.refusal = refusal
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, unit, readingCount, conversion, refusal
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
            unit = (try? c.decodeIfPresent(String.self, forKey: .unit)) ?? ""
            readingCount = (try? c.decodeIfPresent(Int.self, forKey: .readingCount)) ?? 0
            conversion = (try? c.decodeIfPresent(Conversion.self, forKey: .conversion)) ?? .unknown
            refusal = try? c.decodeIfPresent(String.self, forKey: .refusal)
        }
    }

    public enum Conversion: String, Sendable, Equatable, TolerantServerEnum {
        case none
        case converted
        case refused
        case unknown = "__UNKNOWN__"

        public static let unknownFallback = Conversion.unknown
        public static let wireVocabulary: StaticString = "biomarker merge conversion"
    }

    private enum CodingKeys: String, CodingKey {
        case dryRun, target, sources, movedReadings, convertedReadings, aliasesAdded, mergeId, adoptedPanel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dryRun = (try? c.decodeIfPresent(Bool.self, forKey: .dryRun)) ?? false
        target = try? c.decodeIfPresent(BiomarkerDTO.self, forKey: .target)
        sources = (try? c.decodeIfPresent([Source].self, forKey: .sources)) ?? []
        movedReadings = (try? c.decodeIfPresent(Int.self, forKey: .movedReadings)) ?? 0
        convertedReadings = (try? c.decodeIfPresent(Int.self, forKey: .convertedReadings)) ?? 0
        aliasesAdded = (try? c.decodeIfPresent([String].self, forKey: .aliasesAdded)) ?? []
        mergeId = try? c.decodeIfPresent(String.self, forKey: .mergeId)
        let panel = (try? c.decodeIfPresent(String.self, forKey: .adoptedPanel))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        adoptedPanel = panel?.isEmpty == false ? panel : nil
    }

    /// A merge the server would refuse: any source it cannot convert. The
    /// confirm button stays off; the real call would answer 422 anyway.
    public var hasRefusal: Bool {
        sources.contains { $0.conversion == .refused || $0.conversion == .unknown }
    }
}
