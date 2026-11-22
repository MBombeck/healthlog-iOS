import XCTest

/// The navigation and capture primitives of ``QASweepScreenshotsTest``,
/// split out so the walk itself stays readable (and inside `type_body_length`).
extension QASweepScreenshotsTest {
    // MARK: - Navigation primitives

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func tab(_ symbol: String) {
        if ShellNavigator.select(symbol: symbol, in: app, timeout: 8) {
            settle(3)
        } else {
            note("not found: tab \(symbol)")
        }
    }

    /// Opens More and waits for its gear: through the bar, or through the
    /// sidebar where the bar does not take the tap.
    @discardableResult
    func openMore() -> Bool {
        let arrived = AdaptiveShell.open(
            .more,
            in: app,
            button: ShellNavigator.barButton(symbol: "ellipsis", in: app),
            until: app.buttons["more.toolbar.gear"]
        )
        if arrived {
            settle(2)
        } else {
            // A navigation miss fails the case; it no longer passes as a note.
            note("not reached: More")
            XCTFail("More was not reached")
        }
        return arrived
    }

    /// Settings through the gear in More's header, the one way in on every
    /// device.
    func openSettings() -> Bool {
        guard openMore() else { return false }
        guard tap(app.buttons["more.toolbar.gear"], "settings gear") else {
            XCTFail("the settings gear in More was not reached")
            return false
        }
        settle(2)
        return true
    }

    /// The sidebar title of a More row whose area is a section of its own in
    /// a regular window, in the run's language; `nil` for a row that stays in
    /// More everywhere.
    func sectionTitle(forMoreRow row: String) -> String? {
        let titles: [String: [UITestLanguage: String]] = [
            "labs": [.en: "Lab results", .de: "Laborwerte", .nl: "Labuitslagen", .es: "Resultados de laboratorio"],
            "documents": [.en: "Documents", .de: "Dokumente", .nl: "Documenten", .es: "Documentos"],
            "measurements": [.en: "Measurements", .de: "Messwerte", .nl: "Metingen", .es: "Mediciones"],
            "illness": [.en: "Condition journal", .de: "Beschwerden-Tagebuch", .nl: "Klachtendagboek", .es: "Diario de enfermedades"],
            "seizures": [.en: "Seizure diary", .de: "Anfallskalender", .nl: "Aanvalsdagboek", .es: "Diario de crisis"],
            "cycle": [.en: "Cycle", .de: "Zyklus", .nl: "Cyclus", .es: "Ciclo"],
            "mental_wellbeing": [.en: "Mental wellbeing", .de: "Seelisches Wohlbefinden", .nl: "Mentaal welzijn", .es: "Bienestar mental"],
            "workouts": [.en: "Workouts", .de: "Workouts", .nl: "Trainingen", .es: "Entrenamientos"],
            "vorsorge": [.en: "Preventive care", .de: "Vorsorge", .nl: "Preventieve zorg", .es: "Atención preventiva"]
        ]
        guard let names = titles[row] else { return nil }
        return names[language] ?? names[.en]
    }

    /// Opens the area behind a More row wherever the window keeps it: a
    /// section in a regular window is a sidebar tab and no row of More.
    @discardableResult
    func openArea(_ row: String) -> Bool {
        if let title = sectionTitle(forMoreRow: row), AdaptiveShell.isRegular(app) {
            guard ShellNavigator.select(section: title, in: app, timeout: 8) else {
                note("section not reachable: \(row)")
                XCTFail("the section \(row) was not reached")
                return false
            }
            settle(3)
            return true
        }
        guard openMore() else { return false }
        scrollUpToTop()
        guard let target = probe("more.row.\(row)") else {
            note("More row not present: \(row)")
            XCTFail("the More row \(row) was not reached")
            return false
        }
        target.tap()
        settle(3)
        return true
    }

    /// How a lab marker's page came up.
    enum LabMarkerOpening {
        /// Pushed over the list: the way back is the back button.
        case pushed
        /// Beside the table in a wide window: the row was selected, nothing
        /// was pushed, so there is no way back to take.
        case beside
    }

    /// Opens a lab marker's page from the lab list. Beside the table the first
    /// marker is already chosen, so the first row that is not selected is
    /// tapped; the picture then shows another marker than the list's. `nil`
    /// when the list has no marker row.
    func openLabMarker() -> LabMarkerOpening? {
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'labs.byType.item'"))
        guard rows.firstMatch.waitForExistence(timeout: 4) else { return nil }
        let all = rows.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
        guard let first = all.first else { return nil }
        let isBeside = all.contains(where: \.isSelected)
        let target = isBeside ? (all.first { !$0.isSelected } ?? first) : first
        target.tap()
        settle(3)
        return isBeside ? .beside : .pushed
    }

    /// The Log tab is an action: it raises the capture picker.
    func tapLogTab() -> Bool {
        let tapped = ShellNavigator.select(tab: .log, in: app, timeout: 8)
        if !tapped { note("not found: Log tab") }
        return tapped
    }

    @discardableResult
    func tap(_ target: XCUIElement, _ what: String, timeout: TimeInterval = 8) -> Bool {
        let started = Date()
        guard target.waitForExistence(timeout: timeout) else {
            note("not found: \(what) (waited \(Int(Date().timeIntervalSince(started))) s)")
            return false
        }
        guard target.isHittable else {
            note("not hittable: \(what)")
            return false
        }
        target.tap()
        return true
    }

    func waitFor(_ identifier: String, _ timeout: TimeInterval) {
        let started = Date()
        if !element(identifier).waitForExistence(timeout: timeout) {
            note("timeout \(Int(Date().timeIntervalSince(started))) s waiting for \(identifier)")
        }
    }

    /// Scrolls until `identifier` is hittable, at most eight drags; `nil` when
    /// the element never showed up (an honest "not on this screen").
    func probe(_ identifier: String) -> XCUIElement? {
        let target = element(identifier)
        for _ in 0 ..< 8 {
            if target.exists, target.isHittable { return target }
            scrollDown()
        }
        return target.exists && target.isHittable ? target : nil
    }

    /// `scrollDown`, started in the page's left margin (outside any card).
    func marginScroll() {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: 0.72))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: 0.32))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: 600, thenHoldForDuration: 0.3)
        settle(1.2)
    }

    /// Like `probe`, but far enough for the longest settings screens and for
    /// the settings hub at the largest text size.
    func deepProbe(_ identifier: String) -> XCUIElement? {
        let target = element(identifier)
        for step in 0 ..< 16 {
            if target.exists, target.isHittable { return target }
            // A drag that starts on a large button (the assistant source
            // picker) does not scroll; every other try drags along the
            // page's left margin, outside the cards.
            if step.isMultiple(of: 2) {
                scrollDown()
            } else {
                marginScroll()
            }
        }
        return target.exists && target.isHittable ? target : nil
    }

    /// A slow drag with a hold at the end: no momentum, so one call moves the
    /// content by a predictable ~40 % of the screen.
    func scrollDown() {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: scrollColumn, dy: 0.72))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: scrollColumn, dy: 0.32))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: 600, thenHoldForDuration: 0.3)
        settle(1.2)
    }

    func scrollUpToTop() {
        let status = app.statusBars.firstMatch
        if status.exists, status.isHittable {
            status.tap()
        } else {
            for _ in 0 ..< 4 {
                app.swipeDown()
            }
        }
        settle(1)
    }

    func goBack() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists, back.isHittable {
            back.tap()
        } else {
            let edge = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 300, dy: 0)))
        }
        settle(1.5)
    }

    func dismissSheet() {
        for label in ["Cancel", "Abbrechen", "Close", "Schließen", "Done", "Fertig"] {
            let button = app.buttons[label]
            if button.exists, button.isHittable {
                button.tap()
                settle(1.5)
                return
            }
        }
        let top = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
        top.press(forDuration: 0.05, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 700)))
        settle(1.5)
    }

    func openDeepLink(_ string: String) {
        guard let url = URL(string: string) else { return }
        XCUIDevice.shared.system.open(url)
    }

    func visibleInsightsPage() -> String? {
        let pages = app.scrollViews.matching(NSPredicate(format: "identifier BEGINSWITH 'insights.page.'"))
        let width = app.windows.firstMatch.frame.width
        for index in 0 ..< pages.count {
            let page = pages.element(boundBy: index)
            let frame = page.frame
            if abs(frame.minX) < width * 0.25, frame.width > width * 0.5 { return page.identifier }
        }
        return nil
    }

    /// The disclaimer ack, the AI-consent gate, any HealthKit sheet.
    func dismissOverlays() {
        let confirm = app.buttons["disclaimer.ack.confirm"]
        if confirm.exists, confirm.isHittable { confirm.tap()
            settle(1)
        }
        for label in ["Decline", "Ablehnen", "Weigeren"] {
            let button = app.buttons[label]
            if button.exists, button.isHittable { button.tap()
                settle(1)
            }
        }
        dismissHealthAuthorization()
    }

    func dismissHealthAuthorization() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let labels = ["Don't Allow", "Don’t Allow", "Nicht erlauben", "Nicht zulassen"]
        for owner in [app, springboard] {
            for label in labels {
                let button = owner.buttons[label]
                if button.exists, button.isHittable {
                    button.tap()
                    settle(1.5)
                    note("dismissed HealthKit authorization (\(label))")
                    return
                }
            }
        }
    }

    // MARK: - Building blocks

    /// The building block page from its top to its end, then the sheet
    /// scaffold without and with an action.
    func test_31_buildingBlocks() {
        bootBuildingBlocks()
        shotToEnd("31-blocks")
        scrollUpToTop()
        for kind in ["plain", "action"] {
            guard tap(element("blocks.sheet.\(kind)"), "sheet \(kind)") else { continue }
            settle(2)
            shot("31-blocks-sheet-\(kind)")
            if tap(element("hl.sheet.close"), "sheet close") {
                settle(1.5)
            } else {
                dismissSheet()
            }
        }
        // The action forms stand on a page of their own, so the largest text
        // size reaches them within the scroll steps.
        bootBuildingBlocks(extra: ["-uitest-building-blocks-actions"])
        shotToEnd("31-actions")
    }

    /// The fixture-backed start of `boot()` with the building block page in
    /// place of the root. That launch never shows a Dashboard, so the boot
    /// waits for the page itself.
    func bootBuildingBlocks(extra: [String] = []) {
        app = XCUIApplication()
        var arguments = language.launchArguments + [
            "-uitest-hermetic",
            "-uitest-ack-disclaimer",
            "-uitest-disable-biometric-lock",
            "-uitest-building-blocks"
        ] + extra
        if isXXL {
            arguments += ["-UIPreferredContentSizeCategoryName", xxlCategory]
        }
        if isLightAppearance {
            arguments += HermeticAppearance.lightArguments
        }
        app.launchArguments = arguments
        app.launch()
        waitFor("blocks.ready", 60)
        settle(2)
    }

    // MARK: - Capture

    func settle(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// The screen as it stands, then once more after one scroll.
    func shotPair(_ name: String) {
        shot("\(name)-top")
        scrollDown()
        shot("\(name)-scroll1")
    }

    func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let url = URL(fileURLWithPath: outputDir).appendingPathComponent("\(name).png")
        do {
            try screenshot.pngRepresentation.write(to: url)
        } catch {
            note("write failed \(name): \(error)")
        }
        // An alert is a finding: it is in the picture above; name it, then
        // clear it so the walk can go on.
        let alert = app.alerts.firstMatch
        if alert.exists {
            let texts = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
            note("ALERT on \(name): \(texts)")
            alert.buttons.firstMatch.tap()
            settle(1)
        }
    }

    func note(_ line: String) {
        let url = URL(fileURLWithPath: outputDir).appendingPathComponent("_notes.txt")
        let stamped = "[\(name)] \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(stamped.utf8))
            try? handle.close()
        } else {
            try? Data(stamped.utf8).write(to: url)
        }
    }
}
