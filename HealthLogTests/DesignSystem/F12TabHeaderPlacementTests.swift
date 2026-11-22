@testable import HealthLog
import SwiftUI
import Testing

/// On a phone every tab root keeps its actions beside the large title, so the
/// title stands on the page's top line and the bar stays empty; a regular
/// width keeps them in the system bar.
@Suite("F12 tab header placement by size class")
@MainActor
struct F12TabHeaderPlacementTests {
    private nonisolated static let placements: [HLTabHeaderActionPlacement] = [.inline, .bar, .hidden]

    @Test("in a compact width every requested placement stands beside the title", arguments: placements)
    func compactIsInline(requested: HLTabHeaderActionPlacement) {
        #expect(requested.resolved(sizeClass: .compact) == .inline)
    }

    @Test("in a regular width the requested placement stays", arguments: placements)
    func regularKeepsRequest(requested: HLTabHeaderActionPlacement) {
        #expect(requested.resolved(sizeClass: .regular) == requested)
    }

    @Test("every Insights page, on screen or not, shows its actions beside the title on a phone")
    func pagerOnPhone() {
        for isActive in [true, false] {
            let placement = InsightsPagedScroll<EmptyView>.actionPlacement(isActive: isActive)
            #expect(placement.resolved(sizeClass: .compact) == .inline)
        }
    }

    @Test("on an iPad only the Insights page on screen writes into the bar")
    func pagerOnPad() {
        #expect(InsightsPagedScroll<EmptyView>.actionPlacement(isActive: true).resolved(sizeClass: .regular) == .bar)
        #expect(InsightsPagedScroll<EmptyView>.actionPlacement(isActive: false).resolved(sizeClass: .regular) == .hidden)
    }

    private func header(_ title: LocalizedStringResource) -> some View {
        HLTabHeader(title, actions: [
            .settings(label: "Settings", identifier: "test.settings") {},
            .coach {}
        ])
    }

    @Test("on a phone a tab header with actions stays one title line high", arguments: [
        "Insights", "Medikamente", "Blutdruck", "Mehr"
    ])
    func compactHeaderKeepsTitleLine(title: String) throws {
        let view = header(LocalizedStringResource(String.LocalizationValue(title)))
            .environment(\.horizontalSizeClass, .compact)
        let size = try DesignContractMeasure.size(of: view, width: 402)
        #expect(size.height == HLTabHeaderMetrics.titleLineHeight)
    }

    @Test("a list row header shows its actions on a phone: as high as the inline form")
    func listRowHeaderOnPhone() throws {
        let inline = try DesignContractMeasure.size(
            of: header("Mehr").environment(\.hlTabHeaderActionPlacement, .inline),
            width: 402,
            typeSize: .accessibility2
        )
        let rowForm = try DesignContractMeasure.size(
            of: header("Mehr")
                .environment(\.hlTabHeaderActionPlacement, .hidden)
                .environment(\.horizontalSizeClass, .compact),
            width: 402,
            typeSize: .accessibility2
        )
        let regularRow = try DesignContractMeasure.size(
            of: header("Mehr")
                .environment(\.hlTabHeaderActionPlacement, .hidden)
                .environment(\.horizontalSizeClass, .regular),
            width: 402,
            typeSize: .accessibility2
        )
        #expect(rowForm == inline)
        // In accessibility sizes the inline actions stand under the title;
        // without them in the row the regular header is lower.
        #expect(regularRow.height < inline.height)
    }
}

/// A length of time in a key figure tile stands on two lines, "6 Std." over
/// "47 Min.", instead of being cut after the hours.
@Suite("F12 stat tile duration lines")
@MainActor
struct F12StatTileLineTests {
    @Test("a plain value keeps one line")
    func plainValue() {
        #expect(HLStatTile.valueLineLimit("118") == 1)
    }

    @Test("a duration written over two lines keeps both")
    func durationValue() {
        let cell = MetricDurationFormat.cell(hours: 6 + 47.0 / 60, locale: Locale(identifier: "de_DE"))
        #expect(HLStatTile.valueLineLimit(cell) == 2)
    }
}

/// The score rings' prism drifts once around while the rings move and starts
/// and rests on the still frame's colours, so the overview opens with the
/// same ring colours every time.
@Suite("F12 ring hue counts from the motion's start")
@MainActor
struct F12RingHueTests {
    private let origin: TimeInterval = 800_000_000

    @Test("the motion opens and rests on the still frame's hue")
    func opensAndRestsOnStillHue() {
        let still = PrismRimOverlay.stillHueDegrees
        #expect(PrismRimOverlay.hueDegrees(origin, origin: origin) == still)
        #expect(PrismRimOverlay.hueDegrees(0, origin: origin) == still)
        let end = PrismRimOverlay.hueDegrees(origin + WellnessTileMotion.activeSeconds, origin: origin)
        #expect(abs(end - still) < 0.001)
    }

    @Test("it drifts a quarter turn in three seconds")
    func drifts() {
        let quarter = PrismRimOverlay.hueDegrees(origin + 3, origin: origin)
        #expect(abs(quarter - (PrismRimOverlay.stillHueDegrees + 90).truncatingRemainder(dividingBy: 360)) < 0.001)
    }
}
