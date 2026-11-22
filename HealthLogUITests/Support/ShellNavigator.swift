import UIKit
import XCTest

/// The one place UI tests reach the app shell's navigation.
///
/// On iPhone the shell is a tab bar, on iPad (regular width) it is a top tab bar
/// that folds into a sidebar, and on the Duo each half behaves like a compact or
/// regular window. A test must not know which of these it is looking at, so every
/// tab tap goes through here. SwiftUI's `TabView` surfaces its tabs as buttons in
/// all presentations. What the iOS 27 probe dumps show: the iPhone has a `tabBars`
/// container; the iPad's floating top bar has none, its tabs are buttons whose
/// identifier is the SF Symbol and whose label is the title; the folded Duo's
/// vertical bar stands in a `Toolbar`, its buttons carry only the title and
/// the symbol sits on their image; the open sidebar lists tabs and sections as `cells`; one button
/// (identifier `ToggleSideBar`) opens and closes the sidebar.
///
/// Two rules keep a tap from landing on content. Outside `tabBars` a button
/// counts only when symbol and title both match (the Coach button carries
/// `sparkles`, the More menu `ellipsis`), and a sidebar cell only from the left
/// half of the window. Prefer `select(tab:)` over `button(...)`: the button is
/// the tab bar's, and only `select` also finds the other containers or opens a
/// collapsed sidebar.
enum ShellNavigator {
    /// The shell's tabs, pinned to `AuthenticatedShell.tabDescriptors`.
    enum Tab: CaseIterable {
        case home, meds, log, insights, more

        /// The base symbol name; the tab bar may report it with or without `.fill`
        /// depending on placement, so every lookup uses `symbolForms`.
        var symbol: String {
            switch self {
            case .home: "house.fill"
            case .meds: "pills.fill"
            case .log: "plus.circle.fill"
            case .insights: "sparkles"
            case .more: "ellipsis"
            }
        }

        var symbolForms: [String] {
            let base = symbol.hasSuffix(".fill") ? String(symbol.dropLast(5)) : symbol
            return [base, base + ".fill"]
        }

        /// Titles in the app languages that write Latin letters, used outside the tab bar, where a tab is found by title.
        var titles: [String] {
            switch self {
            case .home: ["Home", "Dashboard", "Overzicht", "Inicio"]
            case .meds: ["Meds", "Medikamente", "Medicijnen", "Medicamentos"]
            case .log: ["Log", "Add measurement", "Messung erfassen", "Erfassen", "Vastleggen", "Meting toevoegen", "Registrar"]
            case .insights: ["Insights", "Inzichten"]
            case .more: ["More", "Mehr", "Meer", "Más"]
            }
        }
    }

    /// The tab bar's button for a tab, resolved when it is used, not when it
    /// is asked for. It does not exist while the shell shows a sidebar; use
    /// `select(tab:)` where the shell may be either.
    static func button(_ tab: Tab, in app: XCUIApplication) -> XCUIElement {
        button(symbol: tab.symbol, in: app)
    }

    /// The tab bar's button carrying an SF Symbol. Matched in `tabBars` only.
    static func button(symbol: String, in app: XCUIApplication) -> XCUIElement {
        app.tabBars.buttons.containing(NSPredicate(format: "identifier IN %@", forms(of: symbol))).firstMatch
    }

    /// The bar button of a tab for a test that holds the element before the
    /// shell exists (it resolves when used). One query for every bar: the
    /// phone's tab bar, the pad's floating top bar and the Duo's vertical bar.
    /// The title must match; the symbol must match where the bar forwards
    /// it, so a content button sharing the symbol (Coach, the More menu) or
    /// carrying its own identifier is never taken.
    static func barButton(symbol: String, in app: XCUIApplication) -> XCUIElement {
        guard let tab = Tab.allCases.first(where: { $0.symbolForms.contains(symbol) }) else { return button(symbol: symbol, in: app) }
        return app.buttons.matching(NSPredicate(
            format: "label IN %@ AND (identifier IN %@ OR identifier == '')", tab.titles, tab.symbolForms
        )).firstMatch
    }

    /// Both spellings of a symbol: the base name and its `.fill` form.
    static func forms(of symbol: String) -> [String] {
        let base = symbol.hasSuffix(".fill") ? String(symbol.dropLast(5)) : symbol
        return [base, base + ".fill"]
    }

    /// The tab bar's button found by its localized title, for a bar that does
    /// not forward the symbol.
    static func titledBarButton(_ tab: Tab, in app: XCUIApplication) -> XCUIElement {
        app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", tab.titles)).firstMatch
    }

    /// A tab outside `tabBars`: the iPad's top bar. Probe
    /// dumps show these buttons carrying the symbol as their identifier and the
    /// localized title as label; both must match, so a content button that merely
    /// shares the symbol (Coach, the More menu) is never taken.
    static func floatingBarButton(_ tab: Tab, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier IN %@ AND label IN %@", tab.symbolForms, tab.titles)
        ).firstMatch
    }

    /// A tab of a bar that is neither `tabBars` nor the pad's top bar: the
    /// folded Duo's vertical bar stands in a `Toolbar`, its buttons carry the
    /// title as label and no identifier, the symbol sits on their image.
    /// Title and symbol must both match, so no content button is taken.
    static func toolbarTabButton(_ tab: Tab, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label IN %@", tab.titles))
            .containing(NSPredicate(format: "identifier IN %@", tab.symbolForms))
            .firstMatch
    }

    /// The first tab button of any bar that can take a tap right now. The
    /// tree also holds unreachable copies of every tab (off-screen, titled,
    /// no identifier, the symbol on their image) that a `firstMatch` takes
    /// when they come first, as on the folded Duo's upright bar. So every
    /// match is looked at and only a hittable one is taken; title and symbol
    /// must both match, so no content button is taken.
    static func hittableTabButton(_ tab: Tab, in app: XCUIApplication) -> XCUIElement? {
        let candidates = app.buttons.matching(NSPredicate(format: "label IN %@", tab.titles)).allElementsBoundByIndex
        return candidates.first { element in
            guard element.exists, element.isHittable else { return false }
            if tab.symbolForms.contains(element.identifier) { return true }
            guard element.identifier.isEmpty else { return false }
            return element.images.matching(NSPredicate(format: "identifier IN %@", tab.symbolForms)).firstMatch.exists
        }
    }

    /// The open sidebar's list: the collection view at the window's leading
    /// edge, narrower than half the window. `nil` while no sidebar shows.
    static func sidebarList(in app: XCUIApplication) -> XCUIElement? {
        let window = app.windows.firstMatch.frame
        return app.collectionViews.allElementsBoundByIndex.first { list in
            list.exists && list.frame.minX < 24 && list.frame.width < window.width / 2 && list.frame.width > 0
        }
    }

    /// The sidebar row of a tab. Rows of the open sidebar are `cells` (not
    /// buttons) with the title as label. `nil` while no sidebar row is hittable.
    static func sidebarEntry(_ tab: Tab, in app: XCUIApplication) -> XCUIElement? {
        sidebarRow(titled: tab.titles, in: app)
    }

    /// A row of the open sidebar with one of `titles`: a cell with the title
    /// as label, or, where the cell names nothing, the row's text. Only from
    /// the left half of the window, so no page content is taken.
    static func sidebarRow(titled titles: [String], in app: XCUIApplication) -> XCUIElement? {
        let window = app.windows.firstMatch.frame
        let inSidebar = { (element: XCUIElement) in
            element.exists && element.isHittable && element.frame.midX < window.width / 2
        }
        let cells = app.cells.matching(NSPredicate(format: "label IN %@", titles)).allElementsBoundByIndex
        if let cell = cells.first(where: inSidebar) { return cell }
        let texts = app.collectionViews.staticTexts.matching(NSPredicate(format: "label IN %@", titles)).allElementsBoundByIndex
        return texts.first(where: inSidebar)
    }

    /// Taps a tab wherever the shell shows it: tab bar, floating bar, open
    /// sidebar, or, when none of them is reachable, once through the sidebar
    /// toggle. Reports whether it tapped. Also waits for the shell after a launch.
    @discardableResult
    static func select(tab: Tab, in app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var toggled = false
        repeat {
            for candidate in [
                button(tab, in: app), titledBarButton(tab, in: app),
                floatingBarButton(tab, in: app), toolbarTabButton(tab, in: app)
            ]
                where candidate.exists && candidate.isHittable
            {
                candidate.tap()
                return true
            }
            if let bar = hittableTabButton(tab, in: app) {
                bar.tap()
                return true
            }
            // A regular window has no Log tab: Log is the "+" of the tab roots.
            if tab == .log, captureButton(in: app).exists, captureButton(in: app).isHittable {
                captureButton(in: app).tap()
                return true
            }
            if let row = sidebarEntry(tab, in: app) {
                row.tap()
                return true
            }
            if !toggled, toggleSidebar(in: app) {
                toggled = true
                continue
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }

    /// The "+" in the navigation bar of a tab root in a regular window.
    static func captureButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons["shell.capture.button"].firstMatch
    }

    /// Taps a tab by its SF Symbol name, for helpers that still carry a symbol.
    @discardableResult
    static func select(symbol: String, in app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        guard let tab = Tab.allCases.first(where: { $0.symbolForms.contains(symbol) }) else { return false }
        return select(tab: tab, in: app, timeout: timeout)
    }

    /// Opens a section, named by its accessibility identifier or its label
    /// (a sidebar row such as "Labor" is a cell with the title as label and the
    /// symbol as identifier). Order: an entry that is already reachable, then
    /// the sidebar after one toggle, then the More tab and its row.
    @discardableResult
    static func select(section name: String, in app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        func entry() -> XCUIElement {
            app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier == %@ OR (label == %@ AND elementType IN %@)", name, name, [
                    XCUIElement.ElementType.cell.rawValue, XCUIElement.ElementType.button.rawValue
                ])
            ).firstMatch
        }
        if entry().exists, entry().isHittable {
            entry().tap()
            return true
        }
        // At the largest text sizes the sidebar is longer than the window:
        // the section's row is reached by scrolling the sidebar's own list.
        let opened = toggleSidebar(in: app) || sidebarIsOpen(in: app)
        if opened, let list = sidebarList(in: app) {
            for _ in 0 ..< 6 {
                if entry().waitForExistence(timeout: 1), entry().isHittable {
                    entry().tap()
                    return true
                }
                // A sidebar row whose cell names nothing: its text.
                if let row = sidebarRow(titled: [name], in: app) {
                    row.tap()
                    return true
                }
                list.swipeUp()
            }
        }
        guard select(tab: .more, in: app, timeout: timeout) else { return false }
        guard entry().waitForExistence(timeout: timeout), entry().isHittable else { return false }
        entry().tap()
        return true
    }

    /// Whether any sidebar row is reachable right now.
    static func sidebarIsOpen(in app: XCUIApplication) -> Bool {
        Tab.allCases.contains { sidebarEntry($0, in: app) != nil }
    }

    /// Taps the system toggle ("Seitenleiste ein-/ausblenden", identifier
    /// `ToggleSideBar`) to open a sidebar. One button both opens and closes, so it
    /// is only tapped while no sidebar row is reachable.
    @discardableResult
    static func toggleSidebar(in app: XCUIApplication) -> Bool {
        guard !sidebarIsOpen(in: app) else { return false }
        let toggle = app.buttons.matching(NSPredicate(
            format: "identifier == 'ToggleSideBar' OR label CONTAINS[c] 'sidebar' OR label CONTAINS[c] 'seitenleiste' OR label CONTAINS[c] 'zijbalk' OR label CONTAINS[c] 'navigatiekolom'"
        )).firstMatch
        guard toggle.exists, toggle.isHittable else { return false }
        toggle.tap()
        Thread.sleep(forTimeInterval: 0.6)
        return true
    }

    /// The top edge of the bottom tab bar, or `nil` when the shell shows none
    /// (sidebar, or a top tab bar on a wide window). Tests use it to ask
    /// whether content sits under bottom chrome.
    static func bottomBarMinY(in app: XCUIApplication) -> CGFloat? {
        let bar = app.tabBars.firstMatch
        guard bar.exists else { return nil }
        let window = app.windows.firstMatch.frame
        return bar.frame.minY > window.height / 2 ? bar.frame.minY : nil
    }

    /// Where bottom chrome begins: the tab bar's top edge, else the window's
    /// bottom edge when the shell shows no bottom bar.
    static func bottomChromeMinY(in app: XCUIApplication) -> CGFloat {
        bottomBarMinY(in: app) ?? app.windows.firstMatch.frame.maxY
    }

    /// Frame of the tab bar, `.null` when none is shown.
    static func tabBarFrame(in app: XCUIApplication) -> CGRect {
        let bar = app.tabBars.firstMatch
        return bar.exists ? bar.frame : .null
    }
}
