import SwiftUI

/// How Today stands at a measured size. Every answer is a pure function of a
/// width or a height the page measured itself, never of the device, so it is
/// testable without rendering.
///
/// Today is one column at every width, as on the phone. On the phone the
/// day's read (the hero, its hints, the compliance ring) stands above the
/// metric tiles. From ``HLLayout/sideBySideMinimum`` on the hero heads the
/// column across its whole width, the tiles follow in an even grid of three
/// or four, and the other cards close the column. No column beside another:
/// on the iPad the two of them read as restless (device test of build 312).
enum TodayLayout {
    /// The narrowest a metric tile gets: its value, chart and averages stay
    /// legible at 236 pt.
    static let tileMinimumWidth: CGFloat = 236
    /// At most four tiles in a row: a 13-inch iPad across.
    static let tileMaximumColumns = 4

    /// The grid of Today's metric tiles. Its row fills its width (no 320 pt
    /// cap), so the tiles line up with the cards above and below them, and
    /// the count of columns leaves no tile alone in the last row where a
    /// smaller count avoids it.
    static let tileGrid = textSizedGrid(.large)

    /// The grid at a text size: at the accessibility sizes fewer columns
    /// (``HLAdaptiveGrid/maximumColumns(_:at:)``).
    static func textSizedGrid(_ size: DynamicTypeSize) -> HLTileGrid {
        HLTileGrid(
            minimumTileWidth: tileMinimumWidth,
            maximumColumns: HLAdaptiveGrid.maximumColumns(tileMaximumColumns, at: size),
            maximumTileWidth: nil,
            avoidsLoneTile: true
        )
    }

    /// The order of Today's three blocks in its one column.
    enum Order: Equatable {
        /// The phone: the hero and the day's cards, then the tiles.
        case dayFirst
        /// A wide page: the hero, then the tiles, then the day's cards.
        case tilesFirst
    }

    /// The order at the page's content width: the phone's below the
    /// side-by-side width, the hero above the tiles above the cards from it on.
    static func order(contentWidth: CGFloat) -> Order {
        contentWidth >= HLLayout.sideBySideMinimum ? .tilesFirst : .dayFirst
    }

    /// The widest the hero's read (lead, facts and ring) grows: the reading
    /// width. On a wide iPad the lead ran over 1000 pt and the ring stood
    /// 600 to 900 pt away from its facts; within this width they stay one
    /// group. Narrower cards (every phone, the open Duo) are unchanged.
    static let heroReadMaximumWidth: CGFloat = HLLayout.readableWidth

    /// The width the hero's read takes inside a card whose content is
    /// `contentWidth` wide.
    static func heroReadWidth(contentWidth: CGFloat) -> CGFloat {
        min(max(0, contentWidth), heroReadMaximumWidth)
    }

    /// A window shorter than this is short: the folded Duo, a small Stage
    /// Manager window.
    static let shortWindowHeight: CGFloat = 700
    /// In a short window the hero card stays at or under this height up to
    /// the text size xLarge, so the first tiles still show on the first
    /// screen. The card gets there by composition (two lead lines, the facts
    /// beside the ring), never by cutting it off.
    static let shortWindowHeroHeight: CGFloat = 320

    /// The lead sentence's lines: three, two in a short window.
    static let standardLeadLines = 3
    static let shortWindowLeadLines = 2

    /// Whether the compliance card shows: the medications tile is on, the
    /// hero does not name the medications already, and there is a schedule
    /// or a history to count.
    static func showsCompliance(
        medicationsVisible: Bool,
        heroNamesMedications: Bool,
        scheduledToday: Int,
        takenToday: Int,
        hasHistory: Bool
    ) -> Bool {
        guard medicationsVisible, !heroNamesMedications else { return false }
        return scheduledToday > 0 || takenToday > 0 || hasHistory
    }

    /// The number of tile columns at the page's content width, the grid's
    /// width in the one column. One column fills its width (``HLTileGrid``),
    /// as on the phone.
    static func tileColumns(contentWidth: CGFloat) -> Int {
        tileGrid.columns(width: contentWidth)
    }

    /// The content width of a page in a window `windowWidth` wide.
    static func contentWidth(windowWidth: CGFloat) -> CGFloat {
        max(0, windowWidth - HLLayout.pageInsets.leading - HLLayout.pageInsets.trailing)
    }

    /// Whether the Apple Health cards (connect, update notice) appear. Only
    /// a device that asks for Apple Health at all offers them; on the iPad
    /// they would be a call that leads nowhere.
    static func showsAppleHealthCards(_ profile: DeviceProfile) -> Bool {
        HealthKitAvailabilityPolicy(idiom: profile.idiom).offersAuthorization
    }

    /// From this window width on a short window counts. Narrower windows
    /// are phones held upright (375 to 402 pt), whose Today stays as it is.
    static let shortWindowMinimumWidth: CGFloat = 440

    /// Whether a window of `height` and `width` (safe areas included) is
    /// short: under 700 pt high and at least 440 pt wide, the folded Duo
    /// (466 × 678) or a small Stage Manager window. A phone upright, even
    /// the smallest (375 × 667), is never short, so its Today is unchanged.
    /// Not yet measured is not short.
    static func isShortWindow(height: CGFloat?, width: CGFloat?) -> Bool {
        guard let height, let width, height > 0 else { return false }
        return height < shortWindowHeight && width >= shortWindowMinimumWidth
    }

    /// The lines the lead sentence may take. At an accessibility size it
    /// wraps freely in every window: text the person enlarged is never cut.
    static func leadLineLimit(isShortWindow: Bool, isAccessibilitySize: Bool) -> Int? {
        if isAccessibilitySize { return nil }
        return isShortWindow ? shortWindowLeadLines : standardLeadLines
    }

    /// Whether the facts and the ring stand on top of each other. A short
    /// window keeps them side by side until an accessibility size, since
    /// stacking adds the ring's whole height to the card.
    static func stacksRead(_ size: DynamicTypeSize, isShortWindow: Bool) -> Bool {
        if isShortWindow { return size.isAccessibilitySize }
        return TodayHeroReadLayout.stacks(size)
    }
}
