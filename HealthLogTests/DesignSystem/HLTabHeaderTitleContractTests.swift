@testable import HealthLog
import SwiftUI
import Testing

/// A page head keeps its title whole and its circles equal: a long word
/// sends the actions under the title instead of being cut off, and every
/// circle of a head has the size of a bar icon button at every text size.
@MainActor
@Suite("Page heads keep long titles whole and their circles equal")
struct HLTabHeaderTitleContractTests {
    /// Three circles, as on a metric page: info, gear, coach.
    private static let threeCircles: CGFloat = 3 * HLLayout.iconButton + 2 * HLTabHeaderMetrics.actionGap

    @Test("a long word does not fit beside three circles, a short one does")
    func besideOrUnder() {
        let long = HLTabHeaderMetrics.naturalWidth(of: "Pulswellengeschwindigkeit", typeSize: .large)
        let short = HLTabHeaderMetrics.naturalWidth(of: "Blutdruck", typeSize: .large)
        #expect(!HLTabHeaderMetrics.actionsBesideTitle(width: 370, actionsWidth: Self.threeCircles, longestWordWidth: long))
        #expect(HLTabHeaderMetrics.actionsBesideTitle(width: 370, actionsWidth: Self.threeCircles, longestWordWidth: short))
        #expect(HLTabHeaderMetrics.actionsBesideTitle(width: 370, actionsWidth: 0, longestWordWidth: long))
    }

    @Test("a word shrinks to four fifths at most, then the circles move or the word breaks")
    func shrinkFloor() {
        let room = 370 - Self.threeCircles - HLTabHeaderMetrics.titleActionGap
        let widest = room / HLTabHeaderMetrics.minimumTitleScale
        #expect(HLTabHeaderMetrics.minimumTitleScale == HLButton.titleMinimumScale)
        #expect(HLTabHeaderMetrics.actionsBesideTitle(
            width: 370, actionsWidth: Self.threeCircles, longestWordWidth: widest - 1
        ))
        // A word that would have to stand at three quarters of its size.
        #expect(!HLTabHeaderMetrics.actionsBesideTitle(
            width: 370, actionsWidth: Self.threeCircles, longestWordWidth: room / 0.75
        ))
        #expect(HLTabHeaderMetrics.wordFitsLine(370 / HLTabHeaderMetrics.minimumTitleScale - 1, width: 370))
        #expect(!HLTabHeaderMetrics.wordFitsLine(370 / 0.75, width: 370))
    }

    @Test("with a long word the circles stand under the title", arguments: [
        "Pulswellengeschwindigkeit", "Herzfrequenzvariabilität", "Blutsauerstoffsättigung"
    ])
    func longWordStacks(word: String) throws {
        let header = HLTabHeader(LocalizedStringResource(String.LocalizationValue(word))) {
            HLIconButton(systemImage: "info.circle", label: "Info", style: .bar) {}
            HLIconButton(systemImage: "slider.horizontal.3", label: "Settings", style: .bar) {}
            HLIconButton(systemImage: "sparkles", label: "Coach", style: .bar) {}
        }
        .environment(\.hlTabHeaderActionPlacement, .inline)
        let size = try DesignContractMeasure.size(of: header, width: 370)
        #expect(size.height >= HLTabHeaderMetrics.titleLineHeight + HLTabHeaderMetrics.stackedGap + HLLayout.iconButton)
    }

    @Test("with a short word the circles keep the title's line")
    func shortWordBeside() throws {
        let header = HLTabHeader("Blutdruck") {
            HLIconButton(systemImage: "info.circle", label: "Info", style: .bar) {}
            HLIconButton(systemImage: "slider.horizontal.3", label: "Settings", style: .bar) {}
            HLIconButton(systemImage: "sparkles", label: "Coach", style: .bar) {}
        }
        .environment(\.hlTabHeaderActionPlacement, .inline)
        let size = try DesignContractMeasure.size(of: header, width: 370)
        #expect(size.height == HLTabHeaderMetrics.titleLineHeight)
    }

    @Test("one circle keeps the title's line up to the largest standard size", arguments: [
        DynamicTypeSize.large, .xxxLarge
    ])
    func oneCircleBeside(typeSize: DynamicTypeSize) throws {
        let plain = try DesignContractMeasure.size(of: HLTabHeader("Coach"), width: 370, typeSize: typeSize)
        let withCircle = try DesignContractMeasure.size(
            of: HLTabHeader("Coach") {
                HLIconButton(systemImage: "sparkles", label: "Coach", style: .bar) {}
            }
            .environment(\.hlTabHeaderActionPlacement, .inline),
            width: 370,
            typeSize: typeSize
        )
        let circle = try DesignContractMeasure.size(
            of: HLIconButton(systemImage: "sparkles", label: "Coach", style: .bar) {},
            width: nil,
            typeSize: typeSize
        )
        #expect(withCircle.height == max(plain.height, circle.height))
    }

    @Test("in an accessibility size the circle stands under the title, by design")
    func oneCircleUnderInAccessibilitySizes() throws {
        let plain = try DesignContractMeasure.size(of: HLTabHeader("Coach"), width: 370, typeSize: .accessibility1)
        let withCircle = try DesignContractMeasure.size(
            of: HLTabHeader("Coach") {
                HLIconButton(systemImage: "sparkles", label: "Coach", style: .bar) {}
            }
            .environment(\.hlTabHeaderActionPlacement, .inline),
            width: 370,
            typeSize: .accessibility1
        )
        #expect(withCircle.height > plain.height + HLTabHeaderMetrics.stackedGap)
    }

    @Test("with its actions in the bar the header is as high as without any", arguments: [
        DynamicTypeSize.large, .accessibility1
    ])
    func actionsInBarLeaveTheTitleAlone(typeSize: DynamicTypeSize) throws {
        let plain = try DesignContractMeasure.size(of: HLTabHeader("Coach"), width: 370, typeSize: typeSize)
        let inBar = try DesignContractMeasure.size(
            of: HLTabHeader("Coach") {
                HLIconButton(systemImage: "sparkles", label: "Coach", style: .bar) {}
            },
            width: 370,
            typeSize: typeSize
        )
        #expect(inBar.height == plain.height)
    }

    @Test("a word too wide for the whole line in the largest size may break once")
    func widestWord() {
        let width = HLTabHeaderMetrics.naturalWidth(of: "Pulswellengeschwindigkeit", typeSize: .accessibility5)
        #expect(!HLTabHeaderMetrics.wordFitsLine(width, width: 370))
        #expect(HLTabHeaderMetrics.wordFitsLine(
            HLTabHeaderMetrics.naturalWidth(of: "Medikamente", typeSize: .accessibility5),
            width: 370
        ))
    }

    @Test("the info circle and a menu circle are as large as a bar icon button", arguments: [
        DynamicTypeSize.large, .accessibility3
    ])
    func equalCircles(typeSize: DynamicTypeSize) throws {
        let content = HLInfoContent(
            title: "T",
            identifier: "t",
            topic: .metric(.bloodPressure),
            sections: [HLInfoContent.Section.method(topic: .bloodPressureClassification)].compactMap(\.self)
        )
        let bar = try DesignContractMeasure.size(
            of: HLIconButton(systemImage: "gearshape", label: "Settings", style: .bar) {},
            width: nil,
            typeSize: typeSize
        )
        let info = try DesignContractMeasure.size(
            of: HLInfoButton(content: content, style: .circle, accessibilityIdentifier: "t"),
            width: nil,
            typeSize: typeSize
        )
        let menu = try DesignContractMeasure.size(
            of: Menu { Button("Edit") {} } label: { Image(systemName: "slider.horizontal.3").hlHeaderCircle() },
            width: nil,
            typeSize: typeSize
        )
        #expect(info == bar)
        #expect(menu == bar)
        if typeSize == .accessibility3 {
            #expect(bar.width > HLLayout.iconButton, "the circles should grow with the text")
        }
    }

    @Test("the line under the title makes a page head taller and no wider")
    func lineUnderTitle() throws {
        let plain = try DesignContractMeasure.size(
            of: HLTabHeader("Workouts", titleIdentifier: "insights.page.header.title.workouts"),
            width: 370
        )
        let withLine = try DesignContractMeasure.size(
            of: HLTabHeader("Workouts", subtitle: "12 workouts", titleIdentifier: "insights.page.header.title.workouts"),
            width: 370
        )
        #expect(plain.height == HLTabHeaderMetrics.titleLineHeight)
        #expect(withLine.height > plain.height + HLTabHeaderMetrics.subtitleGap)
        #expect(withLine.width == plain.width)
    }
}
