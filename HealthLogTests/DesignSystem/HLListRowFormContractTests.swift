@testable import HealthLog
import SwiftUI
import Testing

/// One list row for every list: a one-line title and a detail of at most two
/// lines on the left (a cut hint hid what the row is for), value and one
/// status line on the right, at most one accessory, no chevron on data rows.
/// Only the accessibility sizes let the lines wrap freely and stack.
@MainActor
@Suite("The list row keeps to two lines")
struct HLListRowFormContractTests {
    private func lineHeight(
        _ font: Font,
        _ text: String,
        typeSize: DynamicTypeSize = .large
    ) throws -> CGFloat {
        try DesignContractMeasure.size(of: Text(verbatim: text).font(font), width: nil, typeSize: typeSize).height
    }

    private static let longTitle =
        "Findings of the general practice, full blood count and urine test with the reference ranges of the lab"
    private static let longDetail =
        "12 Nov 2026, PDF, 240 KB, general practice, linked to the visit of 3 November, uploaded from the iPhone"

    /// One more caption line: what a detail may add at most.
    private func detailLine(_ typeSize: DynamicTypeSize = .large) throws -> CGFloat {
        try lineHeight(.hlCaption, "PDF", typeSize: typeSize)
    }

    @Test("a list row keeps its title to one line and its detail to two at the standard sizes", arguments: [
        DynamicTypeSize.large, .xxxLarge
    ])
    func rowKeepsTwoLines(typeSize: DynamicTypeSize) throws {
        let short = try DesignContractMeasure.size(
            of: HLRow(title: Text(verbatim: "Findings"), detail: Text(verbatim: "PDF")), typeSize: typeSize
        )
        let longTitle = try DesignContractMeasure.size(
            of: HLRow(title: Text(verbatim: Self.longTitle), detail: Text(verbatim: "PDF")),
            typeSize: typeSize
        )
        #expect(longTitle.height == short.height, "a long title added a line")

        let long = try DesignContractMeasure.size(
            of: HLRow(title: Text(verbatim: Self.longTitle), detail: Text(verbatim: Self.longDetail)),
            typeSize: typeSize
        )
        let line = try detailLine(typeSize)
        #expect(long.height > short.height, "a long detail was cut to one line")
        #expect(long.height <= short.height + line + 1, "a long detail took more than two lines")

        let grid = try DesignContractMeasure.size(
            of: HLRowLayout(title: Text(verbatim: Self.longTitle), subtitle: Text(verbatim: Self.longDetail)),
            typeSize: typeSize
        )
        #expect(grid.height == long.height, "the shared row grid and the row differ")
    }

    @Test("at the accessibility sizes title and detail wrap")
    func rowWrapsAtAccessibilitySizes() throws {
        let short = try DesignContractMeasure.size(
            of: HLRow(title: Text(verbatim: "Findings"), detail: Text(verbatim: "PDF")), typeSize: .accessibility3
        )
        let long = try DesignContractMeasure.size(
            of: HLRow(title: Text(verbatim: Self.longTitle), detail: Text(verbatim: Self.longDetail)),
            typeSize: .accessibility3
        )
        #expect(long.height > short.height * 2)
    }

    @Test("a row's value and status take one line each at the standard sizes")
    func rowRightSideKeepsTwoLines() throws {
        let short = try DesignContractMeasure.size(of: HLRow(
            title: Text(verbatim: "INR"),
            value: Text(verbatim: "1.3"),
            status: HLRowStatus("High", icon: "arrow.up", tone: .warning)
        ))
        let long = try DesignContractMeasure.size(of: HLRow(
            title: Text(verbatim: "INR"),
            value: Text(verbatim: "1.3 and a value far too long to stand beside its title on one line"),
            status: HLRowStatus("Above the reference range of the laboratory that measured it", tone: .warning)
        ))
        #expect(long.height == short.height)
    }

    @Test("at the accessibility sizes the right side stacks under the left")
    func rowStacksRightUnderLeft() throws {
        func height(_ typeSize: DynamicTypeSize, value: Bool) throws -> CGFloat {
            try DesignContractMeasure.size(
                of: HLRow(
                    title: Text(verbatim: "INR"),
                    detail: Text(verbatim: "2 results"),
                    value: value ? Text(verbatim: "1.3") : nil,
                    accessory: .chevron
                ),
                typeSize: typeSize
            ).height
        }
        #expect(try height(.large, value: true) == height(.large, value: false), "the value left the row's line")
        let withValue = try height(.accessibility3, value: true)
        let withoutValue = try height(.accessibility3, value: false)
        let valueLine = try lineHeight(HLRowValue.Emphasis.reading.font, "1.3", typeSize: .accessibility3)
        #expect(withValue >= withoutValue + valueLine, "the value did not move under the title")
    }

    @Test("a row is as high as the grid row with the same content")
    func rowMatchesGrid() throws {
        let row = try DesignContractMeasure.size(of: HLRow(
            title: Text(verbatim: "INR"), detail: Text(verbatim: "2 results"), value: Text(verbatim: "1.3"),
            accessory: .chevron
        ))
        let grid = try DesignContractMeasure.size(of: HLRowLayout(
            title: Text(verbatim: "INR"), subtitle: Text(verbatim: "2 results"), indicator: .disclosure
        ) {
            HLRowValue("1.3")
        })
        #expect(row == grid)
    }

    @Test("a switch row keeps the row grid, its detail at most two lines")
    func toggleRow() throws {
        let row = try DesignContractMeasure.size(
            of: HLRow(
                title: Text(verbatim: Self.longTitle),
                detail: Text(verbatim: Self.longDetail),
                accessory: .toggle(.constant(true))
            )
        )
        let short = try DesignContractMeasure.size(
            of: HLRow(title: Text(verbatim: "Report"), detail: Text(verbatim: "Mondays"), accessory: .toggle(.constant(true)))
        )
        #expect(try row.height <= short.height + detailLine() + 1)
        #expect(short.height >= HLLayout.rowMinHeight)
    }

    @Test("side facts share one detail line, joined by a comma")
    func detailJoin() {
        #expect(HLRowDetail.joined(["12 Nov 2026", nil, " PDF ", "", "240 KB"]) == "12 Nov 2026, PDF, 240 KB")
        #expect(HLRowDetail.joined([nil, ""]) == nil)
        #expect(HLRowDetail.text([nil]) == nil)
    }

    @Test("a switch's description and a statement still wrap: they explain, they are no list detail")
    func explanationsWrap() throws {
        let short = try DesignContractMeasure.size(
            of: HLSettingsToggleRow(title: "Research", description: "Off", isOn: .constant(true))
        )
        let long = try DesignContractMeasure.size(
            of: HLSettingsToggleRow(
                title: "Research",
                description: "Not a medical measurement and not therapy advice. You can turn this off anytime.",
                isOn: .constant(true)
            )
        )
        #expect(long.height > short.height)
    }

    @Test("a data row carries no chevron unless one is chosen")
    func chevronIsOptIn() throws {
        let plain = try DesignContractMeasure.size(of: HLRow(title: Text(verbatim: "Magnesium")), width: nil)
        let chevron = try DesignContractMeasure.size(
            of: HLRow(title: Text(verbatim: "Magnesium"), accessory: .chevron), width: nil
        )
        #expect(chevron.width > plain.width, "the default row drew a chevron")

        let listRow = try DesignContractMeasure.size(of: HLListRow(title: "Resting pulse", value: "56 bpm"), width: nil)
        let listRowChevron = try DesignContractMeasure.size(
            of: HLListRow(title: "Resting pulse", value: "56 bpm", trailingSymbol: "chevron.right"), width: nil
        )
        #expect(listRowChevron.width > listRow.width, "the list row drew a chevron by default")
    }

    @Test("a row as a button takes the size of its row")
    func rowButtonKeepsSize() throws {
        let row = HLRow(title: Text(verbatim: "Magnesium"), value: Text(verbatim: "212 mg"))
        let button = HLRowButton(action: {}, label: { row })
        #expect(try DesignContractMeasure.size(of: button) == DesignContractMeasure.size(of: row))
    }

    @Test("each accessory names one indicator, and the external one is no trend arrow")
    func accessoryIndicators() {
        #expect(HLRowAccessory.none.indicator == .hidden)
        #expect(HLRowAccessory.chevron.indicator == .disclosure)
        #expect(HLRowAccessory.external.indicator == .symbol("arrow.up.right"))
        #expect(HLRowAccessory.expand(true).indicator == .expand(true))
        #expect(HLRowAccessory.toggle(.constant(true)).indicator == .hidden)
        #expect(HLSettingsActionRow<EmptyView, EmptyView>.trailingSymbol(for: .external) == HLRowIndicator.externalSymbol)
    }

    @Test("an open row turns its chevron, in the chevron's own column")
    func expandKeepsColumn() throws {
        let closed = try DesignContractMeasure.size(
            of: HLRow(title: Text(verbatim: "More"), accessory: .expand(false)), width: nil
        )
        let chevron = try DesignContractMeasure.size(
            of: HLRow(title: Text(verbatim: "More"), accessory: .chevron), width: nil
        )
        #expect(closed.width == chevron.width)
        #expect(closed.height == chevron.height)
    }

    @Test("a history entry is a list row with its value on the right")
    func historyRow() throws {
        let history = try DesignContractMeasure.size(of: HLHistoryRow(
            date: Text(verbatim: "Today, 08:15"),
            detail: Text(verbatim: Self.longDetail),
            value: Text(verbatim: "128/82 mmHg"),
            status: HLRowStatus("High", icon: "arrow.up", tone: .warning)
        ))
        let row = try DesignContractMeasure.size(of: HLRow(
            title: Text(verbatim: "Today, 08:15"),
            detail: Text(verbatim: "Apple Health"),
            value: Text(verbatim: "128/82 mmHg"),
            status: HLRowStatus("High", icon: "arrow.up", tone: .warning)
        ))
        #expect(try history.height <= row.height + detailLine() + 1, "the detail took more than two lines")

        let dated = try DesignContractMeasure.size(
            of: HLHistoryRow(date: Date(timeIntervalSince1970: 1_700_000_000), value: Text(verbatim: "72.4 kg"))
        )
        #expect(dated.height >= HLLayout.rowMinHeight)
    }

    @Test("a drill row is a menu row: chevron, the count as its detail line, no value")
    func drillRow() throws {
        let drill = try DesignContractMeasure.size(
            of: HLDrillRow(title: Text(verbatim: "Show all"), count: 248)
        )
        let reference = try DesignContractMeasure.size(
            of: HLRow(
                title: Text(verbatim: "Show all"),
                detail: Text(verbatim: "248 entries in the period"),
                accessory: .chevron
            )
        )
        #expect(drill.height == reference.height)
        #expect(HLDrillRow(title: Text(verbatim: "Show all"), count: 248).detail == .inPeriod(248))
    }

    @Test("a row that is a link keeps the size of the row, in a card and in a list")
    func rowLinkKeepsSize() throws {
        let row = HLRow(title: Text(verbatim: "Magnesium"), value: Text(verbatim: "212 mg"))
        let plain = try DesignContractMeasure.size(of: row)
        let card = try DesignContractMeasure.size(of: row.hlRowLink { EmptyView() })
        let list = try DesignContractMeasure.size(of: row.hlRowLink(inList: true) { EmptyView() })
        #expect(card.height == plain.height)
        #expect(list.height == plain.height)
    }
}
