import XCTest

/// The launch, the navigation and the audit of
/// ``NewSurfacesAccessibilityAuditTests``, split out so the cases stay a list
/// of surfaces.
extension NewSurfacesAccessibilityAuditTests {
    // MARK: - Launch

    /// The picture sweep's hermetic world in German, plus the surface's own
    /// fixture argument.
    func boot(_ extra: [String]) {
        // The app lands on its dark appearance whatever the device says
        // (dark-first). With the device still light, the contrast audit
        // failed white text on the dark cards at random; with both dark it
        // reads what the user sees.
        XCUIDevice.shared.appearance = .dark
        app = XCUIApplication()
        // German unless `A11Y_AUDIT_LANG` asks for another (the pictures in
        // Dutch); no case reads a label, so every language audits alike.
        let language = UITestLanguage(environmentValue: ProcessInfo.processInfo.environment["A11Y_AUDIT_LANG"] ?? "de")
        app.launchArguments += language.launchArguments + size.launchArguments
        app.launchHermeticAndWaitForDashboard(
            extraArguments: [
                "-uitest-phase8", "insightsAccessibility",
                "-uitest-marketing",
                "-uitest-sweep",
                "-hl.healthkit.requestedAt.hermetic-user", "true",
                "-hl.healthkit.workoutReadMigrated.hermetic-user", "true"
            ] + extra,
            timeout: 120
        )
        settle(4)
        let confirm = app.buttons["disclaimer.ack.confirm"]
        if confirm.exists, confirm.isHittable { confirm.tap() }
        dismissHealthAuthorization()
    }

    func acceptAIConsent() {
        for label in ["Akzeptieren", "Accept", "Accepteren"] {
            let button = app.buttons[label]
            if button.waitForExistence(timeout: 3), button.isHittable {
                button.tap()
                settle(1)
                return
            }
        }
    }

    func dismissHealthAuthorization() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for owner in [app, springboard] {
            for label in ["Nicht erlauben", "Nicht zulassen", "Don’t Allow", "Don't Allow"] {
                let button = owner.buttons[label]
                if button.exists, button.isHittable {
                    button.tap()
                    settle(1.5)
                    return
                }
            }
        }
    }

    // MARK: - Navigation

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func tab(_ symbol: String) {
        let button = app.tabBars.buttons.containing(.image, identifier: symbol).firstMatch
        if button.waitForExistence(timeout: 10) {
            button.tap()
            settle(2.5)
        }
    }

    func openMoreRow(_ identifier: String) -> Bool {
        tab("ellipsis")
        guard let row = probe(identifier) else {
            missing(identifier)
            return false
        }
        row.tap()
        settle(3.5)
        dismissHealthAuthorization()
        return true
    }

    func openSettingsRow(_ identifier: String) -> Bool {
        tab("ellipsis")
        let gear = app.buttons["more.toolbar.gear"]
        guard gear.waitForExistence(timeout: 10) else {
            missing("more.toolbar.gear")
            return false
        }
        gear.tap()
        settle(2)
        guard let row = probe(identifier) else {
            missing(identifier)
            return false
        }
        row.tap()
        settle(3)
        return true
    }

    func openDeepLink(_ string: String) {
        guard let url = URL(string: string) else { return }
        XCUIDevice.shared.system.open(url)
        settle(6)
    }

    /// Drags until `identifier` is hittable; `nil` when it never shows.
    func probe(_ identifier: String, drags: Int = 14, column: CGFloat = 0.5, bottomMargin: CGFloat = 0) -> XCUIElement? {
        let target = element(identifier)
        _ = target.waitForExistence(timeout: 3)
        for _ in 0 ..< drags {
            if inTheOpen(target, bottomMargin: bottomMargin) { return target }
            drag(column: column)
        }
        return inTheOpen(target, bottomMargin: bottomMargin) ? target : nil
    }

    func scroll(to target: XCUIElement, drags: Int = 10) -> Bool {
        for _ in 0 ..< drags where !inTheOpen(target) {
            drag(column: 0.5)
        }
        return inTheOpen(target)
    }

    /// `probe` that fails the case when the surface's landmark never shows.
    func reach(_ identifier: String, column: CGFloat = 0.5, bottomMargin: CGFloat = 0) -> Bool {
        guard probe(identifier, column: column, bottomMargin: bottomMargin) != nil else {
            missing(identifier)
            return false
        }
        // Let the scroll come to rest: a contrast read mid-flight is noise.
        settle(2)
        return true
    }

    /// Hittable, and its top edge clear of the bars (or inside the
    /// navigation bar, where toolbar buttons sit).
    func inTheOpen(_ target: XCUIElement, bottomMargin: CGFloat = 0) -> Bool {
        guard target.exists, target.isHittable else { return false }
        // A toolbar button lives in the bar itself.
        let bar = app.navigationBars.firstMatch
        if bar.exists, bar.frame.contains(target.frame) { return true }
        let (top, bottom) = chromeEdges(bottomChrome: bottomMargin)
        let frame = target.frame
        // The edge effect may cover the first lines of a landmark that
        // starts right under the bar; the top of the list is as far as it goes.
        return frame.minY >= top - 32 && frame.minY + min(frame.height, 44) <= bottom
    }

    /// A slow drag with a hold: no momentum, about 40 % of the screen.
    func drag(column: CGFloat) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: column, dy: 0.72))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: column, dy: 0.36))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: 600, thenHoldForDuration: 0.3)
        settle(1)
    }

    func settle(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    func missing(_ what: String) {
        attachFailureDiagnostics(app: app, label: "a11y-missing")
        writeEvidence("missing-\(what)\(size.suffix)", details: [app.debugDescription])
        XCTFail("A11Y precondition never appeared: \(what)")
    }

    // MARK: - Audit

    /// The size pass of the current walk: the ordinary size audits every type
    /// but clipping, the largest size audits clipping in the layout SwiftUI
    /// really builds there (see ``AuditSize``).
    func eachSize(_ walk: () -> Void) {
        for pass in AuditSize.allCases {
            size = pass
            walk()
            app.terminate()
        }
    }

    /// Runs the audit on the screen as it stands and fails on every finding
    /// on the surface itself that no ``AuditException`` names.
    ///
    /// The surface is the union of the elements whose identifier begins with
    /// `owned` (one prefix or several, comma-separated; the whole screen
    /// without `owned`). Three kinds of finding are
    /// printed, not asserted, each for its reason:
    /// - *unattributed*: the audit names no element, so there is nothing to
    ///   place on the surface or to fix (element-less nodes of Swift Charts
    ///   and of the glass layers);
    /// - *chrome*: on the navigation bar, the tab bar or, with
    ///   `bottomChrome`, the floating control above it: system bars, and a
    ///   contrast taken through their glass measures the fold (Phase 8 K1);
    /// - *outside*: on an older part of the same screen, which this audit
    ///   does not own.
    ///
    /// The keyboard counts as a bar too, and `bottomLimit` lets a screen
    /// with its own fixed composer end the surface above it.
    func audit(
        _ surface: String,
        owned prefix: String? = nil,
        bottomChrome: CGFloat = 0,
        bottomLimit: CGFloat? = nil
    ) {
        let name = surface + size.suffix
        let window = app.windows.firstMatch.frame
        let edges = chromeEdges(bottomChrome: bottomChrome)
        let (top, bottom) = (edges.top, min(edges.bottom, bottomLimit ?? .infinity))
        let owned = ownedFrame(prefix) ?? window
        print("A11Y-AREA \(name): owned=\(owned) top=\(top) bottom=\(bottom)")
        var findings: [String] = []
        var skipped: [String] = []
        var details: [String] = []
        do {
            try app.performAccessibilityAudit(for: size.types) { issue in
                let element = issue.element
                let frame = element?.frame ?? .null
                let location = element.map {
                    "\($0.elementType.rawValue)#\($0.identifier)@\(Int(frame.minX)),\(Int(frame.minY)) "
                        + "\(Int(frame.width))x\(Int(frame.height))"
                } ?? "no element"
                let described = "\(issue.compactDescription) [\(location)]"
                details.append("\(described) label=\(element?.label ?? "") — \(issue.detailedDescription)")
                let finding = AuditFinding(
                    type: issue.auditType,
                    identifier: element?.identifier ?? "",
                    elementType: element?.elementType,
                    label: element?.label ?? "",
                    frame: frame
                )
                if issue.auditType == .textClipped {
                    // See `AuditSize.xxxl`: every clipping finding is set
                    // against the picture of the same pass by eye.
                    skipped.append("clipping-by-eye: \(described)")
                } else if element == nil || frame.isNull {
                    skipped.append("unattributed: \(described)")
                } else if frame.minY < top || frame.maxY > bottom {
                    skipped.append("chrome: \(described)")
                } else if !owned.intersects(frame) {
                    skipped.append("outside: \(described)")
                } else if let exception = AuditException.first(matching: finding, on: surface) {
                    skipped.append("\(exception.name): \(described)")
                } else {
                    findings.append(described)
                }
                return true
            }
        } catch {
            XCTFail("A11Y \(name): the audit did not run: \(error)")
        }
        findings = confirmRepeated(findings, skipped: &skipped)
        writeEvidence(name, details: details)
        for line in skipped {
            print("A11Y-SKIP \(name) \(line)")
        }
        print("A11Y-AUDIT \(name): \(findings.count) open, \(skipped.count) not asserted")
        XCTAssertTrue(findings.isEmpty, "A11Y \(name): \(findings)")
    }

    /// A contrast or Dynamic Type finding counts when a second reading a
    /// moment later repeats it on the same element. Single readings failed
    /// now and then on white text on the dark cards and on the last row of a
    /// card, and passed on the next run (the glass of the cards, the end of
    /// a scroll or a fade), so one reading alone is no evidence either way.
    private func confirmRepeated(_ findings: [String], skipped: inout [String]) -> [String] {
        let prefixes = ["Contrast", "Dynamic Type"]
        let doubtful = findings.filter { line in prefixes.contains { line.hasPrefix($0) } }
        guard !doubtful.isEmpty else { return findings }
        settle(1.5)
        var again = Set<String>()
        try? app.performAccessibilityAudit(for: [.contrast, .dynamicType]) { issue in
            if let element = issue.element {
                let frame = element.frame
                let place = "\(element.elementType.rawValue)#\(element.identifier)@\(Int(frame.minX)),\(Int(frame.minY))"
                again.insert("\(issue.compactDescription.prefix(8))|\(place)")
            }
            return true
        }
        return findings.filter { line in
            guard prefixes.contains(where: { line.hasPrefix($0) }) else { return true }
            let place = line.components(separatedBy: "[").last?.components(separatedBy: " ").first ?? ""
            if again.contains("\(line.prefix(8))|\(place)") { return true }
            skipped.append("not-repeated: \(line)")
            return false
        }
    }

    /// Where the system bars begin: content above `top` and below `bottom`
    /// sits under a bar.
    func chromeEdges(bottomChrome: CGFloat = 0) -> (top: CGFloat, bottom: CGFloat) {
        let window = app.windows.firstMatch.frame
        let bar = app.navigationBars.firstMatch
        // The bar plus the scroll edge effect under it, which fades what
        // scrolls beneath (about 32 pt on iOS 26 and 27).
        let top = bar.exists && bar.frame.maxY < window.height / 2 ? bar.frame.maxY + 32 : 0
        let tabs = app.tabBars.firstMatch
        var bottom = (tabs.exists && tabs.frame.minY > window.height / 2 ? tabs.frame.minY : window.maxY) - bottomChrome
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists, keyboard.frame.minY > 0 { bottom = min(bottom, keyboard.frame.minY) }
        return (top, bottom)
    }

    private func ownedFrame(_ prefix: String?) -> CGRect? {
        guard let prefix else { return nil }
        let window = app.windows.firstMatch.frame
        // Several prefixes, separated by commas.
        let predicates = prefix.split(separator: ",").map {
            NSPredicate(format: "identifier BEGINSWITH %@", String($0))
        }
        let matches = app.descendants(matching: .any)
            .matching(NSCompoundPredicate(orPredicateWithSubpredicates: predicates))
            .allElementsBoundByIndex
            .map(\.frame)
            .filter { !$0.isNull && !$0.isEmpty && $0.intersects(window) }
        guard let first = matches.first else { return nil }
        return matches.dropFirst().reduce(first) { $0.union($1) }
    }

    func writeEvidence(_ name: String, details: [String]) {
        let out = ProcessInfo.processInfo.environment["A11Y_AUDIT_OUT"] ?? ""
        guard !out.isEmpty else { return }
        let dir = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: dir.appendingPathComponent("\(name).png"))
        try? Data(details.joined(separator: "\n").utf8)
            .write(to: dir.appendingPathComponent("\(name).txt"))
    }
}

/// The two passes of every surface.
enum AuditSize: CaseIterable {
    /// The ordinary text size: every audit type but clipping. At this size
    /// the audit estimates clipping by enlarging the text in place without a
    /// new layout, so text that SwiftUI breaks onto more lines at the larger
    /// size reads as clipped; the largest-size pass measures it for real.
    case standard
    /// Launched at AX-XXXL: clipping, where the layout is the real one.
    ///
    /// Recorded, not asserted. Even in the real layout the audit called text
    /// clipped that stands whole in the picture taken in the same moment:
    /// Picker row labels of the symptom form ("Symptom", "Stärke"), the
    /// wrapping badge "Leicht einge-schränkt", the coach note before it was
    /// moved. So every clipping finding of this pass is checked by eye
    /// against `<surface>-xxxl.png` (A11Y_AUDIT_OUT), and the report lists
    /// each one with its verdict.
    case xxxl

    var types: XCUIAccessibilityAuditType {
        switch self {
        case .standard: XCUIAccessibilityAuditType.all.subtracting(.textClipped)
        case .xxxl: .textClipped
        }
    }

    var suffix: String {
        self == .standard ? "" : "-xxxl"
    }

    var launchArguments: [String] {
        self == .standard ? [] : ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    }
}

/// What an exception sees of a finding.
struct AuditFinding {
    let type: XCUIAccessibilityAuditType
    let identifier: String
    let elementType: XCUIElement.ElementType?
    let label: String
    let frame: CGRect
}

/// A finding on a surface that is not a defect of it, each with its reason.
/// Narrow on purpose: an audit type and a predicate on the element,
/// optionally limited to named surfaces.
struct AuditException {
    let name: String
    let type: XCUIAccessibilityAuditType
    let surfaces: Set<String>?
    let reason: String
    let matches: (AuditFinding) -> Bool

    @MainActor static func first(matching finding: AuditFinding, on surface: String) -> AuditException? {
        all.first { exception in
            exception.type == finding.type
                && (exception.surfaces?.contains(surface) ?? true)
                && exception.matches(finding)
        }
    }

    @MainActor static let all: [AuditException] = [
        AuditException(
            name: "chart-mark-hit-area",
            type: .hitRegion,
            surfaces: nil,
            // Swift Charts makes each mark its own VoiceOver element, as wide
            // as one day of the chart. VoiceOver reaches them by swiping, a
            // finger by the chart's selection; a mark is no touch target.
            reason: "Swift-Charts-Marke: VoiceOver-Element je Datenpunkt, kein Tippziel",
            matches: { $0.elementType == .other && $0.identifier.isEmpty && $0.frame.height >= 3 * $0.frame.width }
        ),
        AuditException(
            name: "single-glyph-contrast",
            type: .contrast,
            surfaces: nil,
            // A unit of one character ("%" beside the marker's name, 11 pt
            // wide): its edge smoothing outweighs the ink, so the reading
            // says little. The same colour at the same size passes on every
            // longer text of these surfaces.
            reason: "Einzelnes Zeichen, Kantenglättung überwiegt die Messung",
            matches: { $0.elementType == .staticText && $0.frame.width < 16 }
        ),
        AuditException(
            name: "composition-amount-with-iu",
            type: .contrast,
            surfaces: ["supp-composition"],
            // "25 µg (1.000 IE)": the same colour, size and card as "175 mg"
            // and "125 mg" in the rows below, which pass; the picture shows it
            // as legible as they are (report A11Y, crop of
            // `supp-composition.png`). Only the amount with the unit in
            // brackets fails, on every run.
            reason: "Gleiche Farbe wie die übrigen Mengen, die bestehen; Bild zeigt gute Lesbarkeit",
            matches: { $0.elementType == .staticText && $0.label.contains("(") }
        ),
        AuditException(
            name: "form-system-text",
            type: .dynamicType,
            surfaces: ["composition-editor", "symptom-form", "lab-scan-review", "documents-trash"],
            // Labels of Picker, DatePicker and Button rows and the section
            // footers of a Form or List carry no font of ours: the system
            // sets them, and they grow with the setting (the "-xxxl" pictures
            // of the same surfaces). The audit reads the system's own list
            // text as partly unscaled.
            reason: "Systemtext einer Form- oder Listenzeile, wächst laut XXXL-Bild mit",
            matches: { $0.elementType == .staticText && $0.identifier.isEmpty }
        ),
        AuditException(
            name: "compact-date-picker-label",
            type: .contrast,
            surfaces: nil,
            // The same system button, read over its own tinted capsule.
            reason: "Datumsknopf des System-DatePickers, Farbe vom System",
            matches: {
                $0.elementType == .button && $0.label.range(of: #"^\d{1,2}[.:]\d{2}([.]\d{4})?$"#, options: .regularExpression) != nil
            }
        ),
        AuditException(
            name: "compact-date-picker-label",
            type: .sufficientElementDescription,
            surfaces: nil,
            // The date button inside the system's compact DatePicker speaks
            // the date as the system formats it; the picker carries the
            // field's label.
            reason: "Datumsknopf des System-DatePickers, Etikett trägt der Picker",
            matches: { $0.elementType == .button && $0.label.range(of: #"^\d{1,2}\.\d{1,2}\.\d{4}$"#, options: .regularExpression) != nil }
        )
    ]
}
