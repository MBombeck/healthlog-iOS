@testable import HealthLog
import SwiftUI
import Testing

/// The target forms of rows, values, status, facts and empty notes. Each
/// block names its fonts through the tokens, and the laid-out block is
/// measured against plain text in those tokens, so a block that goes back
/// to a size of its own is caught even when its font property still says
/// the right thing.
@MainActor
@Suite("Target forms of the building blocks")
struct HLTargetFormContractTests {
    // MARK: - Helpers

    private func lineHeight(
        _ font: Font,
        _ text: String = "Build 302",
        typeSize: DynamicTypeSize = .large
    ) throws -> CGFloat {
        try DesignContractMeasure.size(of: Text(verbatim: text).font(font), width: nil, typeSize: typeSize).height
    }

    private func near(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 1) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    // MARK: - Values

    @Test("each value size names its number and unit fonts through the tokens")
    func valueSizeFonts() {
        #expect(HLValueSize.row.numberFont == Font.hlSubhead.weight(.medium))
        #expect(HLValueSize.row.unitFont == Font.hlSubhead)
        #expect(HLValueSize.compact.numberFont == Font.hlMetric(.body))
        #expect(HLValueSize.compact.unitFont == Font.hlCaption)
        #expect(HLValueSize.tile.numberFont == Font.hlMetric(.title))
        #expect(HLValueSize.tile.unitFont == Font.hlSubhead)
        #expect(HLValueSize.hero.numberFont == Font.hlMetric(.largeTitle))
        #expect(HLValueSize.hero.unitFont == Font.hlSubhead)
    }

    @Test("a value in a row is no taller than the row title")
    func rowValueMatchesTitle() throws {
        let value = try DesignContractMeasure.size(of: HLValueText(64, unit: .beatsPerMinute), width: nil)
        let title = try lineHeight(HLRowTitle.font, "Pulse")
        #expect(near(value.height, title), "\(value.height) pt against a title of \(title) pt")
        let number = try lineHeight(HLValueSize.row.numberFont, "64 bpm")
        #expect(near(value.height, number))
    }

    @Test("the value sizes rise from row over compact and tile to hero")
    func valueSizesRise() throws {
        func height(_ size: HLValueSize) throws -> CGFloat {
            try DesignContractMeasure.size(of: HLValueText(72.4, unit: .kilograms, size: size), width: nil).height
        }
        let row = try height(.row)
        let compact = try height(.compact)
        let tile = try height(.tile)
        let hero = try height(.hero)
        #expect(row < compact)
        #expect(compact < tile)
        #expect(tile < hero)
        #expect(try near(compact, lineHeight(.hlMetric(.body), "72,4")))
        #expect(try near(hero, lineHeight(.hlMetric(.largeTitle), "72,4")))
    }

    @Test("a compact value moves its unit under the number at the largest type when it does not fit")
    func compactValueStacks() throws {
        let narrow: CGFloat = 220
        let short = try DesignContractMeasure.size(
            of: HLValueText(1, unit: .plain, size: .compact), width: narrow, typeSize: .accessibility5
        )
        let pair = try DesignContractMeasure.size(
            of: HLValueText(128, 82, unit: .millimetersOfMercury, size: .compact),
            width: narrow,
            typeSize: .accessibility5
        )
        #expect(pair.height > short.height * 1.3, "\(pair.height) pt against \(short.height) pt for one line")
    }

    // MARK: - Row value

    @Test("a row value names its fonts through the tokens")
    func rowValueFonts() {
        #expect(HLRowValue.Emphasis.reading.font == Font.hlSubhead.weight(.medium))
        #expect(HLRowValue.Emphasis.setting.font == Font.hlSubhead)
        #expect(HLRowValue.Emphasis.setting.tint == HLText.secondary)
        #expect(HLRowValue.Emphasis.reading.tint == HLText.primary)
    }

    @Test("a row value is as tall as the row title", arguments: [HLRowValue.Emphasis.reading, .setting])
    func rowValueHeight(emphasis: HLRowValue.Emphasis) throws {
        let value = try DesignContractMeasure.size(of: HLRowValue("1,3 mg/L", emphasis: emphasis), width: nil)
        let title = try lineHeight(HLRowTitle.font, "INR")
        #expect(near(value.height, title), "\(value.height) pt against a title of \(title) pt")
    }

    @Test("a status under a row value is text, shorter than a capsule")
    func rowValueStatus() throws {
        let bare = try DesignContractMeasure.size(of: HLRowValue("1,3"), width: nil)
        let withText = try DesignContractMeasure.size(
            of: HLRowValue("1,3", status: HLRowStatus("Above range", icon: "arrow.up", tone: .warning)),
            width: nil
        )
        let withCapsule = try DesignContractMeasure.size(
            of: VStack(alignment: .trailing, spacing: HLSpace.xxs) {
                HLRowValue("1,3")
                HLBadge("Above range", icon: "arrow.up", tone: .warning)
            },
            width: nil
        )
        #expect(withText.height > bare.height)
        #expect(withText.height < withCapsule.height)
    }

    @Test("a value does not raise the row of a list row")
    func listRowValueKeepsRowHeight() throws {
        let plain = try DesignContractMeasure.size(
            of: HLListRow(title: "Resting pulse", subtitle: "30-day average 58 bpm", trailingSymbol: nil)
        )
        let withValue = try DesignContractMeasure.size(
            of: HLListRow(title: "Resting pulse", subtitle: "30-day average 58 bpm", value: "56 bpm", trailingSymbol: nil)
        )
        #expect(withValue.height == plain.height)
    }

    @Test("a settings value is as tall as the row title")
    func settingsValueHeight() throws {
        let value = try DesignContractMeasure.size(of: HLSettingsRowValueText(value: "175 cm"), width: nil)
        #expect(try near(value.height, lineHeight(HLRowTitle.font, "Height")))
    }

    @Test("a row of facts is one line of row text, and stacks at the accessibility sizes")
    func statRowHeight() throws {
        let stat = try DesignContractMeasure.size(of: HLSettingsStatRow(label: Text(verbatim: "Build"), value: "302"))
        #expect(try near(stat.height, lineHeight(HLRowTitle.font, "Build")))

        let large = try DesignContractMeasure.size(
            of: HLSettingsStatRow(label: Text(verbatim: "Build"), value: "302"), typeSize: .accessibility3
        )
        let line = try lineHeight(HLRowTitle.font, "Build", typeSize: .accessibility3)
        #expect(large.height > line * 1.8, "value stayed beside its label at an accessibility size")
    }

    // MARK: - Status

    @Test("both status forms name their fonts through the tokens")
    func badgeFonts() {
        #expect(HLBadge.Form.capsule.titleFont == Font.hlCaption.weight(.semibold))
        #expect(HLBadge.Form.text.titleFont == Font.hlCaption.weight(.medium))
        #expect(HLBadge.Form.text.iconFont == Font.hlCaption2.weight(.semibold))
        #expect(HLBadge.Form.capsule.iconFont == Font.hlCaption2.weight(.semibold))
    }

    @Test("a status as text has no capsule around it")
    func badgeTextForm() throws {
        let text = try DesignContractMeasure.size(of: HLBadge("In range", form: .text), width: nil)
        let capsule = try DesignContractMeasure.size(of: HLBadge("In range"), width: nil)
        #expect(try near(text.height, lineHeight(HLBadge.Form.text.titleFont, "In range")))
        #expect(near(capsule.height, text.height + 2 * HLSpace.xs))
        #expect(near(capsule.width, text.width + 2 * HLSpace.sm))
    }

    @Test("a neutral status as text reads in secondary ink, a signal keeps its colour")
    func badgeTextTint() {
        #expect(HLBadge("x", tone: .neutral, form: .text).textForeground == HLText.secondary)
        #expect(HLBadge("x", tone: .info, form: .text).textForeground == HLText.secondary)
        #expect(HLBadge("x", tone: .success, form: .text).textForeground == HLColor.statusOK)
        #expect(HLBadge("x", tone: .warning, form: .text).textForeground == HLColor.statusWarn)
        #expect(HLBadge("x", tone: .critical, form: .text).textForeground == HLColor.statusBad)
    }

    @Test(
        "a status pill is a badge with the state's symbol and tone",
        arguments: [
            HLStatusPill.State.connected(label: "Connected"),
            .error(label: "Token expired"),
            .disconnected(label: "Not connected"),
            .unknown(label: "Checking"),
            .warning(label: "Delayed"),
        ]
    )
    func statusPillWrapsBadge(state: HLStatusPill.State) throws {
        let pill = HLStatusPill(state)
        let expectedTone: HLBadge.Tone = switch state {
        case .connected: .success
        case .error: .critical
        case .disconnected, .unknown: .neutral
        case .warning: .warning
        }
        #expect(pill.tone == expectedTone)

        let badge = HLBadge(pill.label, icon: pill.symbol, tone: pill.tone)
        #expect(try DesignContractMeasure.size(of: pill, width: nil) == DesignContractMeasure.size(of: badge, width: nil))

        let textPill = HLStatusPill(state, form: .text)
        let textBadge = HLBadge(pill.label, icon: pill.symbol, tone: pill.tone, form: .text)
        #expect(
            try DesignContractMeasure.size(of: textPill, width: nil)
                == DesignContractMeasure.size(of: textBadge, width: nil)
        )
    }

    // MARK: - Symbol column

    @Test("a bare row symbol stands in a column as wide as the symbol chip, with or without a symbol")
    func rowGlyphColumn() throws {
        #expect(HLRowGlyph.columnWidth(forScaled: 10) == HLLayout.rowIcon)
        #expect(HLRowGlyph.columnWidth(forScaled: 500) == HLSettingsIconChip.maxSide)

        let narrow = try DesignContractMeasure.size(of: HLRowGlyph(symbol: "figure.walk"), width: nil)
        let wide = try DesignContractMeasure.size(of: HLRowGlyph(symbol: "heart.text.square.fill"), width: nil)
        let empty = try DesignContractMeasure.size(of: HLRowGlyph(symbol: nil), width: nil)
        #expect(narrow.width == HLLayout.rowIcon)
        #expect(wide.width == HLLayout.rowIcon)
        #expect(empty.width == HLLayout.rowIcon)

        let chip = try DesignContractMeasure.size(
            of: HLSettingsIconChip(symbol: "ruler", tint: HLText.primary), width: nil, typeSize: .accessibility5
        )
        let glyph = try DesignContractMeasure.size(
            of: HLRowGlyph(symbol: "figure.walk"), width: nil, typeSize: .accessibility5
        )
        #expect(glyph.width == chip.width, "the column left the chip's line at the largest type")
    }

    @Test("rows with a bare symbol, without one and with a chip are equally wide, so their text starts at one place")
    func rowGlyphAlignsText() throws {
        func rowWidth(_ leading: some View) throws -> CGFloat {
            try DesignContractMeasure.size(
                of: HLRowLayout(title: Text(verbatim: "Walk")) { EmptyView() } leading: { leading },
                width: nil
            ).width
        }
        let chip = try rowWidth(HLSettingsIconChip(symbol: "figure.walk", tint: HLText.primary))
        #expect(try rowWidth(HLRowGlyph(symbol: "figure.walk")) == chip)
        #expect(try rowWidth(HLRowGlyph(symbol: "heart.text.square.fill")) == chip)
        #expect(try rowWidth(HLRowGlyph(symbol: nil)) == chip)
    }

    // MARK: - Facts

    @Test("a fact row names its fonts through the tokens")
    func factRowFonts() {
        #expect(HLFactRow.labelFont == Font.hlSubhead)
        #expect(HLFactRow.valueFont == Font.hlSubhead)
        #expect(HLFactGroup<EmptyView>.spacing == HLSpace.xs)
    }

    @Test("a fact row is one line of body text and stacks at the accessibility sizes")
    func factRowStacks() throws {
        let row = HLFactRow(label: Text(verbatim: "Supply"), value: Text(verbatim: "24"))
        let regular = try DesignContractMeasure.size(of: row)
        #expect(try near(regular.height, lineHeight(HLFactRow.labelFont, "Supply")))

        let large = try DesignContractMeasure.size(of: row, typeSize: .accessibility3)
        let line = try lineHeight(HLFactRow.labelFont, "Supply", typeSize: .accessibility3)
        #expect(large.height > line * 1.8, "the value stayed beside its label at an accessibility size")
    }

    @Test("rows of one fact group stand the group gap apart")
    func factGroupSpacing() throws {
        let one = try DesignContractMeasure.size(of: HLFactGroup {
            HLFactRow(label: Text(verbatim: "Supply"), value: Text(verbatim: "24"))
        })
        let two = try DesignContractMeasure.size(of: HLFactGroup {
            HLFactRow(label: Text(verbatim: "Supply"), value: Text(verbatim: "24"))
            HLFactRow(label: Text(verbatim: "Next"), value: Text(verbatim: "08:00"))
        })
        #expect(near(two.height, 2 * one.height + HLSpace.xs))
    }

    // MARK: - Empty note

    @Test("an empty note is one line of secondary body text across the card")
    func emptyNote() throws {
        #expect(HLEmptyNote.font == Font.hlSubhead)
        let note = try DesignContractMeasure.size(of: HLEmptyNote(verbatim: "No intakes yet."))
        #expect(note.width == 320, "the note takes the width of the card")
        #expect(try near(note.height, lineHeight(HLEmptyNote.font, "No intakes yet.")))

        let largest = try DesignContractMeasure.size(of: HLEmptyNote(verbatim: "No intakes yet."), typeSize: .accessibility5)
        #expect(largest.height > note.height, "the note did not grow with the text")
    }
}
