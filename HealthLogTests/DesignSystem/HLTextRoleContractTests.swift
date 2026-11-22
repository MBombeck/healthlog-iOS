@testable import HealthLog
import SwiftUI
import Testing

/// The text roles are a contract with the role table of F9: a new role or a
/// changed size breaks this test, and with it the table.
@Suite("HLTextRole contract")
struct HLTextRoleContractTests {
    private struct Row {
        let style: Font.TextStyle
        let weight: HLTextRoleSpec.Weight
        let tone: HLTextRoleSpec.Tone
        let design: HLTextRoleSpec.Design
        let digits: Bool
        let before: CGFloat
        let after: CGFloat

        init(
            _ style: Font.TextStyle,
            _ weight: HLTextRoleSpec.Weight,
            _ tone: HLTextRoleSpec.Tone,
            _ design: HLTextRoleSpec.Design,
            _ digits: Bool,
            _ before: CGFloat,
            _ after: CGFloat
        ) {
            self.style = style
            self.weight = weight
            self.tone = tone
            self.design = design
            self.digits = digits
            self.before = before
            self.after = after
        }
    }

    private static let table: [HLTextRole: Row] = [
        .pageTitle: Row(.largeTitle, .bold, .primary, .standard, false, 12, 2),
        .pageSubtitle: Row(.subheadline, .regular, .secondary, .standard, false, 2, 0),
        .columnHeader: Row(.headline, .semibold, .primary, .standard, false, 0, 2),
        .areaHeader: Row(.headline, .semibold, .primary, .standard, false, 24, 8),
        .groupHeader: Row(.footnote, .semibold, .secondary, .standard, false, 24, 8),
        .tableColumnTitle: Row(.footnote, .semibold, .secondary, .standard, false, 24, 8),
        .objectName: Row(.headline, .semibold, .primary, .standard, false, 16, 12),
        .cardTitle: Row(.subheadline, .semibold, .primary, .standard, false, 16, 12),
        .tileLabel: Row(.caption, .semibold, .secondary, .standard, false, 16, 4),
        .heroValue: Row(.largeTitle, .bold, .primary, .rounded, true, 16, 4),
        .tileValue: Row(.title, .bold, .primary, .rounded, true, 4, 8),
        .compactValue: Row(.body, .bold, .primary, .rounded, true, 0, 0),
        .valueUnit: Row(.subheadline, .regular, .secondary, .standard, false, 0, 0),
        .compactUnit: Row(.caption, .regular, .secondary, .standard, false, 0, 0),
        .rowTitle: Row(.subheadline, .semibold, .primary, .standard, false, 0, 0),
        .rowSubtitle: Row(.caption, .regular, .secondary, .standard, false, 2, 0),
        .rowValue: Row(.subheadline, .medium, .primary, .standard, true, 0, 0),
        .rowStatus: Row(.caption, .regular, .secondary, .standard, false, 0, 0),
        .factLabel: Row(.subheadline, .regular, .secondary, .standard, false, 0, 0),
        .factValue: Row(.subheadline, .regular, .primary, .standard, false, 0, 0),
        .prose: Row(.subheadline, .regular, .primary, .standard, false, 0, 0),
        .note: Row(.footnote, .regular, .secondary, .standard, false, 4, 0),
        .footnote: Row(.caption, .regular, .tertiary, .standard, false, 4, 0),
        .chartAxis: Row(.caption, .regular, .secondary, .standard, false, 0, 0),
        .chartUnit: Row(.caption, .semibold, .secondary, .standard, false, 0, 0),
        .chartMark: Row(.caption2, .medium, .secondary, .standard, false, 0, 0),
        .emptyTitle: Row(.headline, .semibold, .primary, .standard, false, 0, 0),
        .emptyMessage: Row(.subheadline, .regular, .secondary, .standard, false, 0, 0)
    ]

    @Test("every role is in the frozen table, and the table names no other")
    func rolesMatchTable() {
        #expect(Set(HLTextRole.allCases) == Set(Self.table.keys))
        #expect(HLTextRole.allCases.count == 28)
    }

    @Test("each role keeps its style, weight, colour, face and room", arguments: HLTextRole.allCases)
    func roleSpec(role: HLTextRole) throws {
        let row = try #require(Self.table[role])
        let spec = role.spec
        #expect(spec.style == row.style)
        #expect(spec.weight == row.weight)
        #expect(spec.tone == row.tone)
        #expect(spec.design == row.design)
        #expect(spec.fixedDigits == row.digits)
        #expect(spec.before == row.before)
        #expect(spec.after == row.after)
    }

    @Test("no role is set below the HIG minimum of caption 2")
    func noRoleBelowCaption2() {
        let allowed: Set<Font.TextStyle> = [.largeTitle, .title, .body, .headline, .subheadline, .footnote, .caption, .caption2]
        for role in HLTextRole.allCases {
            #expect(allowed.contains(role.spec.style), "\(role)")
        }
    }

    @Test("section ranks map onto the header roles")
    func rankRoles() {
        #expect(HLSectionRank.area.textRole == .areaHeader)
        #expect(HLSectionRank.group.textRole == .groupHeader)
    }
}

/// A detail column beside a list is part of the list's page: its sections
/// step one rank down; a pushed page keeps its ranks.
@Suite("HLColumnHeader rank")
struct HLColumnHeaderRankTests {
    @Test("embedded beside a list an area becomes a group")
    func embedded() {
        #expect(HLSectionRank.area.lowered(by: HLListDetail<EmptyView, EmptyView>.detailRankOffset) == .group)
        #expect(HLSectionRank.group.lowered(by: HLListDetail<EmptyView, EmptyView>.detailRankOffset) == .group)
    }

    @Test("pushed on its own the area stays an area")
    func pushed() {
        #expect(HLSectionRank.area.lowered(by: 0) == .area)
        #expect(EnvironmentValues().hlSectionRankOffset == 0)
        #expect(EnvironmentValues().hlIsDetailColumn == false)
    }

    @Test("the column header is the only 17 pt role in a detail column")
    func columnHeaderOutranksGroups() {
        #expect(HLTextRole.columnHeader.spec.style == .headline)
        #expect(HLSectionRank.area.lowered(by: 1).textRole.spec.style == .footnote)
    }
}

/// The rank change measured on the container itself: beside the list an area
/// header is set as a group header; where the detail is pushed instead, the
/// container shows the list alone and the pushed page keeps its area header.
@MainActor
@Suite("HLListDetail rank, measured")
struct HLListDetailRankMeasureTests {
    private func container(width: CGFloat) -> some View {
        HLListDetail(measuredWidth: width) { _ in
            Color.clear.frame(height: 1)
        } detail: {
            HLSectionHeader("Latest measurement", rank: .area)
        }
    }

    @Test("beside the list at 1032 pt the detail's area header stands as a group header")
    func besideTheList() throws {
        let measured = try DesignContractMeasure.size(of: container(width: 1032), width: 1032)
        let group = try DesignContractMeasure.size(of: HLSectionHeader("Latest measurement", rank: .group), width: 400)
        let area = try DesignContractMeasure.size(of: HLSectionHeader("Latest measurement", rank: .area), width: 400)
        #expect(group.height < area.height)
        #expect(measured.height == group.height)
    }

    @Test("at 390 pt the list stands alone and a pushed page keeps the area rank")
    func pushedOnThePhone() throws {
        let measured = try DesignContractMeasure.size(of: container(width: 390), width: 390)
        #expect(measured.height == 1)
        let pushed = try DesignContractMeasure.size(of: HLSectionHeader("Latest measurement", rank: .area), width: 390)
        let area = try DesignContractMeasure.size(of: HLSectionHeader("Latest measurement", rank: .area), width: 390)
        #expect(pushed == area)
    }
}
