import Foundation
@testable import HealthLog
import SwiftUI
import Testing
import UIKit

/// The board's rows at each density and text size, and what a line says
/// at a chosen day.
@Suite("Timeline — rows, text size and readings")
struct TimelineDensityTests {
    @Test("a window under 480 pt high gets the short rows; a phone held across fits lanes and three lines at once")
    func density() {
        #expect(TimelineDensity.forHeight(402) == .short)
        #expect(TimelineDensity.forHeight(874) == .regular)
        #expect(TimelineDensity.forHeight(0) == .regular)
        // iPhone 17 Pro across: 402 pt, less the bar at the top (44, with the
        // period in it) and the home indicator (21). On the page: its top
        // margin, the axis, two illness rows, five medications, two event
        // rows, the divider with its room and three lines.
        let short = TimelineDensity.short
        let used = HLSpace.xs + TimelineMetrics.axisHeight + 9 * short.laneRow + (2 * HLSpace.xs + 1) + 3 * short.valueRow
        #expect(used <= 402 - 44 - 21)
    }

    @Test(
        "the page height does not depend on where the period bar stands, so the density cannot feed back",
        arguments: [CGFloat(402), 440, 480, 520, 874]
    )
    func heightIndependentOfBar(window: CGFloat) {
        let top: CGFloat = 44
        let bar: CGFloat = 60
        // Bar at the bottom: it is part of the bottom inset.
        let atBottom = TimelineDensity.pageHeight(content: window - top - 21 - bar, top: top, bottom: 21 + bar)
        // Bar in the top bar: the content gets its points back.
        let inTopBar = TimelineDensity.pageHeight(content: window - top - 21, top: top, bottom: 21)
        #expect(atBottom == window)
        #expect(inTopBar == window)
        #expect(TimelineDensity.forHeight(atBottom) == TimelineDensity.forHeight(inTopBar))
    }

    @Test(
        "the board's columns never ask for more than the width they are built from",
        arguments: [CGFloat(320), 370.33, 402, 600, 669.67, 750.5, 794, 1032, 1376]
    )
    @MainActor
    func boardColumnsFitTheirWidth(width: CGFloat) {
        for density in [TimelineDensity.regular, .short] {
            let columns = TimelineBoardView.boardColumns(width: width, density: density)
            let used = 2 * columns.inset + columns.label + HLSpace.md + columns.plot
            #expect(used <= width + 0.001)
            #expect(columns.plot >= 0)
        }
    }

    @Test("a measured width only replaces the one in use from half a point on, so rounding cannot loop")
    @MainActor
    func widthTolerance() {
        #expect(!TimelineBoardView.takesWidth(750.33, over: 750))
        #expect(!TimelineBoardView.takesWidth(750, over: 750.33))
        #expect(TimelineBoardView.takesWidth(750, over: 0))
        #expect(TimelineBoardView.takesWidth(402, over: 874))
    }

    @Test(
        "the period bar held across is as wide as six of its longest label: de Alle, en All, nl Alles stay whole",
        arguments: [
            ["W", "M", "3M", "6M", "J", "Alle"],
            ["W", "M", "3M", "6M", "Y", "All"],
            ["W", "M", "3M", "6M", "J", "Alles"],
        ]
    )
    @MainActor
    func periodBarFitsLongestLabel(labels: [String]) {
        let width = TimelinePeriodBarWidth.minimum(labels: labels, labelWidth: TimelinePeriodBarWidth.labelWidth)
        let segment = (width - 2 * HLSpace.xs - 2 * HLSpace.lg) / CGFloat(labels.count)
        for label in labels {
            #expect(segment >= TimelinePeriodBarWidth.labelWidth(label) + 2 * HLSpace.xs)
        }
        // Derived from the longest label: shortening it asks for less room.
        // The longest is measured, not assumed to be the last: in English
        // "3M" and "6M" are wider than "All", and with fixed-width digits
        // they tie, so every label of the widest width is shortened.
        let widest = labels.map(TimelinePeriodBarWidth.labelWidth).max() ?? 0
        let shorter = labels.map { TimelinePeriodBarWidth.labelWidth($0) < widest ? $0 : "A" }
        #expect(TimelinePeriodBarWidth.minimum(labels: shorter, labelWidth: TimelinePeriodBarWidth.labelWidth) < width)
    }

    @Test(
        "rows grow with the text: a bar row holds its name at AX1, AX3 and AX5, the large size keeps the base",
        arguments: [DynamicTypeSize.accessibility1, .accessibility3, .accessibility5]
    )
    func scaledRows(size: DynamicTypeSize) {
        let base = TimelineDensity.regular
        #expect(base.scaled(for: .large) == base)
        let scaled = base.scaled(for: size)
        let name = TimelineDensity.nameLineHeight(size)
        // The name above the bar, the bar and its gap fit in the row.
        #expect(scaled.laneRow >= name + TimelineMetrics.barHeight + HLSpace.xxs + 1)
        #expect(scaled.valueRow > base.valueRow)
        #expect(TimelineDensity.nameLineHeight(.accessibility5) > TimelineDensity.nameLineHeight(.accessibility3))
        // From the first accessibility size on, names stand above their rows.
        #expect(TimelineLayoutStyle.style(width: 1032, typeSize: size) == .stacked)
        #expect(TimelineLayoutStyle.style(width: 1032, typeSize: .xxxLarge) == .board)
    }

    @Test("a chosen day shows the point of its bucket, else the last point before it with its day")
    func readingAtDay() {
        let points = TimelineTracksTests.weekly(["2026-10-05", "2026-10-12"])
        let track = TimelineValueTrack.meanTrack(
            key: "WEIGHT", source: .measurement, unit: "kg", points: points, bucket: .week, window: TimelineTracksTests.quarter
        )
        let inBucket = TimelineValueLabel.reading(of: track, at: TimelineTracksTests.day("2026-10-14"), bucket: .week)
        #expect(inBucket?.isInBucket == true && inBucket?.value == 81)
        let later = TimelineValueLabel.reading(of: track, at: TimelineTracksTests.day("2026-10-28"), bucket: .week)
        #expect(later?.isInBucket == false && later?.value == 81)
        #expect(TimelineValueLabel.reading(of: track, at: TimelineTracksTests.day("2026-09-20"), bucket: .week) == nil)
    }
}
