import Foundation

/// The labs list's presentation from `GET /api/settings/module-list-layout`
/// (`lists.labs`, server v1.47.1, #164). Only the two choices the app
/// reads: whether the list stands under its categories (`groupBy`) and which
/// categories start open (`groupsOpen`). Both are the person's own, saved on
/// the web; the app follows them and does not write them.
public struct LabsListLayout: Sendable, Equatable {
    public enum GroupBy: String, Sendable, Equatable, TolerantServerEnum {
        /// The flat list (wire `none`, the server default).
        case flat = "none"
        case category
        case unknown = "__UNKNOWN__"

        public static let unknownFallback = GroupBy.unknown
        public static let wireVocabulary: StaticString = "module list groupBy"
    }

    public enum GroupsOpen: String, Sendable, Equatable, TolerantServerEnum {
        /// Every category starts open (the server default).
        case expanded
        /// Only categories whose status is `below` or `above` start open.
        case flagged
        /// Every category starts closed.
        case collapsed
        case unknown = "__UNKNOWN__"

        public static let unknownFallback = GroupsOpen.unknown
        public static let wireVocabulary: StaticString = "module list groupsOpen"
    }

    /// `nil` when the server sends no `groupBy` (before v1.47.1): the list
    /// then groups whenever the overview says `grouped`, as it did before.
    public let groupBy: GroupBy?
    public let groupsOpen: GroupsOpen

    public init(groupBy: GroupBy?, groupsOpen: GroupsOpen = .expanded) {
        self.groupBy = groupBy
        self.groupsOpen = groupsOpen
    }

    /// Whether the list stands under the server's categories. The overview's
    /// own `grouped` still has the last word: one category, or only "other",
    /// stays flat whatever the choice.
    public func groups(overviewGrouped: Bool) -> Bool {
        guard overviewGrouped else { return false }
        return groupBy != .flat
    }

    /// Whether a category starts open under ``groupsOpen``. The server's
    /// status for the whole category decides `flagged`.
    public func startsOpen(status: LabRangeStatus) -> Bool {
        switch groupsOpen {
        case .expanded, .unknown: true
        case .collapsed: false
        case .flagged: status == .below || status == .above
        }
    }
}

/// `data` of `GET /api/settings/module-list-layout`: only `lists.labs` is read.
public struct ModuleListLayoutResponse: Decodable, Sendable, Equatable {
    public let labs: LabsListLayout?

    private enum CodingKeys: String, CodingKey {
        case lists
    }

    private enum ListKeys: String, CodingKey {
        case labs
    }

    private enum LabsKeys: String, CodingKey {
        case groupBy, groupsOpen
    }

    public init(labs: LabsListLayout?) {
        self.labs = labs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let lists = try? c.nestedContainer(keyedBy: ListKeys.self, forKey: .lists),
              let labs = try? lists.nestedContainer(keyedBy: LabsKeys.self, forKey: .labs) else
        {
            labs = nil
            return
        }
        let groupBy = try? labs.decodeIfPresent(LabsListLayout.GroupBy.self, forKey: .groupBy)
        let groupsOpen = (try? labs.decodeIfPresent(LabsListLayout.GroupsOpen.self, forKey: .groupsOpen)) ?? .expanded
        self.labs = LabsListLayout(groupBy: groupBy, groupsOpen: groupsOpen)
    }
}
