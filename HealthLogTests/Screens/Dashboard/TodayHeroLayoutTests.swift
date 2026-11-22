#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing

    /// How Today stands at each width and in a short window: one column at
    /// every width, the tiles right under the hero from the side-by-side
    /// width on, the tiles in as many columns as the width holds (up to
    /// four), one full-width column on the phone, and a hero that keeps to
    /// 320 pt where the window is shorter than 700 pt.
    @MainActor
    @Suite("Today hero layout")
    struct TodayHeroLayoutTests {
        /// The window widths every adaptive rule is checked at.
        nonisolated static let widths: [CGFloat] = [320, 440, 466, 540, 669, 744, 834, 1032, 1133, 1376]

        // MARK: - Columns per width

        /// Build 312 on the iPad Pro 11: the day's read on the left and the
        /// tiles on the right read as restless. One column at every width; from
        /// 834 pt the tiles follow the hero, below it the phone's order holds.
        @Test(
            "one column everywhere: the tiles under the hero from 834 pt on, the phone's order below",
            arguments: zip(widths, [false, false, false, false, false, false, true, true, true, true])
        )
        func tilesUnderTheHero(window: CGFloat, tilesFirst: Bool) {
            let content = TodayLayout.contentWidth(windowWidth: window)
            #expect(TodayLayout.order(contentWidth: content) == (tilesFirst ? .tilesFirst : .dayFirst))
            #expect(TodayStackLayout.placementOrder(TodayLayout.order(contentWidth: content), count: 3)
                == (tilesFirst ? [0, 2, 1] : [0, 1, 2]))
        }

        @Test(
            "the tiles take as many columns as the column holds, three or four on a wide iPad",
            arguments: zip(widths, [1, 1, 1, 2, 2, 2, 3, 4, 4, 4])
        )
        func tileColumns(window: CGFloat, expected: Int) {
            let content = TodayLayout.contentWidth(windowWidth: window)
            #expect(TodayLayout.tileColumns(contentWidth: content) == expected)
        }

        @Test(
            "at the accessibility sizes at most two tile columns, from AX3 one",
            arguments: [
                (DynamicTypeSize.large, 4), (.xxxLarge, 4), (.accessibility1, 2),
                (.accessibility2, 2), (.accessibility3, 1), (.accessibility5, 1)
            ]
        )
        func columnsPerTextSize(size: DynamicTypeSize, maximum: Int) {
            #expect(HLAdaptiveGrid.maximumColumns(4, at: size) == maximum)
            #expect(TodayLayout.textSizedGrid(size).maximumColumns == maximum)
            // The widest page: never more columns than the text size allows.
            #expect(TodayLayout.textSizedGrid(size).columns(width: 1376) <= maximum)
            // A grid that asks for fewer keeps its own maximum.
            #expect(HLAdaptiveGrid.maximumColumns(1, at: size) == 1)
        }

        @Test("no tile falls under 240 pt and the row lines up with the cards of its column", arguments: widths)
        func tileRowFlush(window: CGFloat) {
            let content = TodayLayout.contentWidth(windowWidth: window)
            let gridWidth = content
            let grid = TodayLayout.tileGrid
            #expect(abs(grid.rowWidth(width: gridWidth) - gridWidth) <= 0.5)
            if grid.columns(width: gridWidth) > 1 {
                #expect(grid.tileWidth(width: gridWidth) >= TodayLayout.tileMinimumWidth)
            } else {
                #expect(grid.tileWidth(width: gridWidth) == gridWidth)
            }
        }

        @Test("iPad mini upright: two tiles of 350 pt, flush with the hero above")
        func iPadMiniFlush() {
            let content = TodayLayout.contentWidth(windowWidth: 744)
            #expect(TodayLayout.tileGrid.tileWidth(width: content) == (712 - HLLayout.tileGap) / 2)
        }

        @Test("on the phone (440) everything stands in one column as before, the tiles full width")
        func phoneUnchanged() throws {
            let content = TodayLayout.contentWidth(windowWidth: 440)
            #expect(content == 408)
            #expect(TodayLayout.order(contentWidth: content) == .dayFirst)
            #expect(TodayLayout.tileColumns(contentWidth: content) == 1)
            // Three tiles measure as the stack they were: full height of each
            // plus the tile gap between them.
            let height = try Self.gridHeight(width: content, heights: [40, 80, 60])
            #expect(abs(height - (40 + 80 + 60 + 2 * HLLayout.tileGap)) <= 0.5)
        }

        @Test("side by side the tiles of a row stand as tall as the tallest")
        func rowsTakeTheTallestTile() throws {
            let height = try Self.gridHeight(width: 1000, heights: [40, 80, 60])
            #expect(abs(height - 80) <= 0.5)
            let twoRows = try Self.gridHeight(width: 500, heights: [40, 80, 60])
            #expect(abs(twoRows - (80 + 60 + HLLayout.tileGap)) <= 0.5)
        }

        // MARK: - Short window

        @Test(
            "a window under 700 pt high and at least 440 pt wide is short; a phone upright never is",
            arguments: [
                (CGFloat?.none, CGFloat?.none, false),
                (0, 466, false),
                (678, 466, true), // the folded Duo
                (699.5, 540, true), // a small Stage Manager window
                (667, 375, false), // the smallest phone upright
                (874, 402, false), // iPhone 17 Pro upright
                (956, 440, false), // the largest phone upright
                (700, 466, false),
                (1032, 1376, false)
            ]
        )
        func shortWindow(height: CGFloat?, width: CGFloat?, isShort: Bool) {
            #expect(TodayLayout.isShortWindow(height: height, width: width) == isShort)
        }

        @Test(
            "a phone upright keeps its hero: three lead lines and the stacking of today",
            arguments: [(CGFloat(667), CGFloat(375)), (874, 402)]
        )
        func phoneHeroUnchanged(height: CGFloat, width: CGFloat) throws {
            let short = TodayLayout.isShortWindow(height: height, width: width)
            #expect(!short)
            #expect(TodayLayout.leadLineLimit(isShortWindow: short, isAccessibilitySize: false) == 3)
            for size in [DynamicTypeSize.large, .xLarge, .xxLarge, .xxxLarge, .accessibility3] {
                #expect(TodayLayout.stacksRead(size, isShortWindow: short) == TodayHeroReadLayout.stacks(size))
            }
            let content = TodayLayout.contentWidth(windowWidth: width)
            let before = try Self.height(
                of: TodayHeroCard(digest: Self.fullDigest, onRingTap: {}), width: content, size: .large
            )
            let now = try Self.height(
                of: TodayHeroCard(digest: Self.fullDigest, onRingTap: {}, isShortWindow: short),
                width: content,
                size: .large
            )
            #expect(abs(before - now) <= 0.5)
        }

        // MARK: - The one column

        @Test("an even grid: no tile stands alone in the last row where fewer columns avoid it")
        func noLoneTile() {
            let grid = TodayLayout.tileGrid
            // Upright 13-inch iPad (1000 pt): five tiles in four columns would
            // leave one alone; three per row instead.
            #expect(grid.columns(width: 1000, itemCount: 5) == 3)
            #expect(grid.columns(width: 1000, itemCount: 8) == 4)
            // Upright 11-inch iPad (802 pt): seven tiles stay in three columns.
            #expect(grid.columns(width: 802, itemCount: 6) == 3)
            // The phone keeps one column whatever the count.
            #expect(grid.columns(width: 408, itemCount: 7) == 1)
        }

        /// Review P2: on a wide iPad the lead ran over 1000 pt and the ring
        /// stood far from its facts. The read keeps the reading width; every
        /// card narrower than it, the phone's included, is unchanged.
        @Test(
            "the hero's read stays within the reading width; narrower cards keep their whole width",
            arguments: widths
        )
        func heroReadWidth(window: CGFloat) {
            let card = TodayLayout.contentWidth(windowWidth: window) - 2 * HLLayout.cardInset
            let read = TodayLayout.heroReadWidth(contentWidth: card)
            #expect(read <= HLLayout.readableWidth)
            #expect(read == min(card, HLLayout.readableWidth))
            if window <= 744 { #expect(read == card) }
            // Facts and ring as one group: the room between the facts' start
            // and the ring never grows past the reading width.
            #expect(read - TodayHeroCard.ringColumnWidth < HLLayout.readableWidth)
        }

        /// Across, the sidebar stands beside the page (from 1100 pt), so Today
        /// gets the detail column: the window minus the sidebar (320 pt on
        /// iPadOS 27, measured in the run-4 pictures).
        @Test(
            "beside the sidebar: mini, 11 and 13 inch across get three, three and four tile columns",
            arguments: zip([CGFloat(1133), 1210, 1376], [3, 3, 4])
        )
        func columnsBesideTheSidebar(window: CGFloat, expected: Int) {
            let detail = window - Self.sidebarWidth
            let content = TodayLayout.contentWidth(windowWidth: detail)
            #expect(TodayLayout.tileColumns(contentWidth: content) == expected)
            #expect(TodayLayout.order(contentWidth: content) == .tilesFirst)
        }

        nonisolated static let sidebarWidth: CGFloat = 320

        @Test("an empty block takes no gap")
        func emptyBlockTakesNoGap() throws {
            let stack = TodayStackLayout {
                Color.gray.frame(height: 40)
                Color.clear.frame(height: 0)
                Color.gray.frame(height: 60)
            }
            let height = try Self.height(of: stack, width: 1000, size: .large)
            #expect(abs(height - (40 + 60 + HLLayout.cardGap)) <= 0.5)
        }

        @Test("the compliance card counts only where it shows")
        func complianceRule() {
            #expect(TodayLayout.showsCompliance(
                medicationsVisible: true, heroNamesMedications: false, scheduledToday: 2, takenToday: 0, hasHistory: false
            ))
            #expect(TodayLayout.showsCompliance(
                medicationsVisible: true, heroNamesMedications: false, scheduledToday: 0, takenToday: 0, hasHistory: true
            ))
            #expect(!TodayLayout.showsCompliance(
                medicationsVisible: true, heroNamesMedications: false, scheduledToday: 0, takenToday: 0, hasHistory: false
            ))
            #expect(!TodayLayout.showsCompliance(
                medicationsVisible: false, heroNamesMedications: false, scheduledToday: 2, takenToday: 1, hasHistory: true
            ))
            #expect(!TodayLayout.showsCompliance(
                medicationsVisible: true, heroNamesMedications: true, scheduledToday: 2, takenToday: 1, hasHistory: true
            ))
        }

        @Test("in a short window the lead keeps two lines, at an accessibility size it wraps freely")
        func leadLines() {
            #expect(TodayLayout.leadLineLimit(isShortWindow: false, isAccessibilitySize: false) == 3)
            #expect(TodayLayout.leadLineLimit(isShortWindow: true, isAccessibilitySize: false) == 2)
            #expect(TodayLayout.leadLineLimit(isShortWindow: true, isAccessibilitySize: true) == nil)
            #expect(TodayLayout.leadLineLimit(isShortWindow: false, isAccessibilitySize: true) == nil)
            #expect(TodayHeroCard.leadLineLimit == TodayLayout.standardLeadLines)
        }

        @Test(
            "in a short window the facts stay beside the ring up to the accessibility sizes",
            arguments: [DynamicTypeSize.large, .xLarge, .xxLarge, .xxxLarge, .accessibility1, .accessibility5]
        )
        func readStacking(size: DynamicTypeSize) {
            #expect(TodayLayout.stacksRead(size, isShortWindow: true) == size.isAccessibilitySize)
            #expect(TodayLayout.stacksRead(size, isShortWindow: false) == TodayHeroReadLayout.stacks(size))
        }

        @Test(
            "in a short window the hero card stays at or under 320 pt up to xLarge",
            arguments: [DynamicTypeSize.large, .xLarge]
        )
        func shortWindowHeroHeight(size: DynamicTypeSize) throws {
            // The folded Duo: 466 pt less the page margins.
            let card = TodayHeroCard(digest: Self.fullDigest, onRingTap: {}, isShortWindow: true)
            let height = try Self.height(of: card, width: TodayLayout.contentWidth(windowWidth: 466), size: size)
            #expect(height > 0)
            #expect(height <= TodayLayout.shortWindowHeroHeight, "the hero is \(height) pt tall at \(size)")
        }

        @Test("a tall window keeps the hero as it was")
        func tallWindowHeroUnchanged() throws {
            let before = try Self.height(
                of: TodayHeroCard(digest: Self.fullDigest, onRingTap: {}),
                width: 408,
                size: .large
            )
            let tall = try Self.height(
                of: TodayHeroCard(digest: Self.fullDigest, onRingTap: {}, isShortWindow: false),
                width: 408,
                size: .large
            )
            #expect(abs(before - tall) <= 0.5)
        }

        @Test("the skeleton keeps the loaded card's height in a short window")
        func shortWindowSkeleton() throws {
            let skeleton = try Self.height(of: TodayHeroSkeleton.heroCard(isShortWindow: true), width: 434, size: .large)
            let loaded = try Self.height(
                of: TodayHeroCard(digest: TodayHeroSkeleton.placeholderDigest, onRingTap: {}, isShortWindow: true),
                width: 434,
                size: .large
            )
            #expect(abs(skeleton - loaded) <= 2)
        }

        // MARK: - Apple Health cards

        @Test("the Apple Health cards stay off the iPad and on the phone and the Duo")
        func appleHealthCards() {
            #expect(!TodayLayout.showsAppleHealthCards(DeviceProfile(idiom: .pad, model: "iPad")))
            #expect(TodayLayout.showsAppleHealthCards(DeviceProfile(idiom: .phone, model: "iPhone")))
            #expect(TodayLayout.showsAppleHealthCards(.phone))
        }

        // MARK: - Helpers

        /// A full day: a score, four facts and a lead far longer than three lines.
        static let fullDigest = DailyDigest(
            generatedAt: "",
            phase: "final",
            sleepPending: true,
            score: DailyDigest.Score(value: 74, band: "green", delta: nil, steadyWeeks: 3),
            topSignal: nil,
            briefingLead: nil,
            line: String(
                repeating: "Dein Blutdruck lag die Woche über ruhig im Zielbereich, der Schlaf war etwas kürzer. ",
                count: 4
            ),
            worthALook: [],
            today: [
                DailyDigest.TodayFact(kind: "sleep", label: "Letzte Nacht", value: "6 Std. 19 Min., kürzer", href: nil, moduleKey: nil),
                DailyDigest.TodayFact(kind: "medication", label: "Medikamente", value: "2 von 5 genommen", href: nil, moduleKey: nil),
                DailyDigest.TodayFact(kind: "steps", label: "Schritte", value: "8.412", href: nil, moduleKey: nil),
                DailyDigest.TodayFact(kind: "bp", label: "Blutdruck", value: "128/82 mmHg", href: nil, moduleKey: nil)
            ]
        )

        /// The height a tile grid of fixed-height tiles takes at `width`.
        private static func gridHeight(width: CGFloat, heights: [CGFloat]) throws -> CGFloat {
            let grid = TodayLayout.tileGrid {
                ForEach(Array(heights.enumerated()), id: \.offset) { _, height in
                    Color.gray.frame(height: height)
                }
            }
            return try height(of: grid, width: width, size: .large)
        }

        private static func height(of view: some View, width: CGFloat, size: DynamicTypeSize) throws -> CGFloat {
            let renderer = ImageRenderer(
                content: view
                    .frame(width: width)
                    .fixedSize(horizontal: false, vertical: true)
                    .dynamicTypeSize(size)
            )
            renderer.scale = 1
            let image = try #require(renderer.uiImage, "view failed to render")
            return image.size.height
        }
    }

#endif
