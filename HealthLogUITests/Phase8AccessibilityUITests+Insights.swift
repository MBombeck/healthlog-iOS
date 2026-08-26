import XCTest

/// **08-11 — the Insights score grid, at both text sizes, plus its own audit.**
///
/// Split into its own file for the same reason `+Logout` and `+SupportGate` are:
/// `Phase8AccessibilityUITests` is close enough to the `type_body_length` budget
/// that a whole new walkthrough belongs beside it rather than inside it. The
/// class is still run whole (`-only-testing:HealthLogUITests/Phase8AccessibilityUITests`),
/// so the case participates in every gate the class does.
extension Phase8AccessibilityUITests {
    /// The layout claim, measured as a DIFFERENTIAL across two launches of the
    /// same fixture: at the standard content size the score tiles are half-width
    /// and share rows; at `AccessibilityXXXL` each tile has the row to itself.
    ///
    /// Two launches rather than one, because the single-launch version cannot
    /// tell "one column at accessibility sizes" from "one column always" — and
    /// the standard-size half of the contract is exactly what the policy suite's
    /// preservation clauses protect.
    ///
    /// The audit runs on the accessibility-size pass, where the surface is least
    /// adapted, and is scoped to the score grid this plan owns: findings
    /// elsewhere on the Insights overview are printed as diagnostics rather than
    /// asserted, because they belong to surfaces no Phase-8 plan has opened.
    /// That is a scope, not an issue-category exclusion — every audit type stays
    /// switched on and every finding is recorded in the gate log.
    @MainActor
    func testInsightsAccessibilityLayout() throws {
        var violations: [String] = []
        violations += try insightsGridViolations(atAccessibilitySize: false)
        violations += try insightsGridViolations(atAccessibilitySize: true, auditing: true)
        record(violations, for: "insights-accessibility")
        XCTAssertTrue(
            violations.isEmpty,
            "08-11 Insights score grid did not adapt to the accessibility text size"
        )
    }

    // MARK: - One launch, one content size

    @MainActor
    private func insightsGridViolations(
        atAccessibilitySize: Bool,
        auditing: Bool = false
    ) throws -> [String] {
        let label = atAccessibilitySize ? "ax5" : "standard"
        let app = XCUIApplication()
        app.launchPhase8Shell(
            .insightsAccessibility,
            extraArguments: atAccessibilitySize
                ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
                : []
        )

        let insights = app.phase8Tab("sparkles")
        guard app.awaitPhase8(insights, "the Insights tab (\(label))") else { return [] }
        insights.tap()

        let block = app.phase8Element("insights.scoreCards")
        guard app.awaitPhase8(block, "the Insights score-card grid (\(label))", timeout: 30) else { return [] }

        let cards = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "insights.scoreCard."))
            .allElementsBoundByIndex
            .filter { $0.exists && $0.frame.width > 1 }
        print("PHASE8-DIAGNOSTIC insights \(label) block=\(block.frame) cards=" +
            cards.map { "\($0.identifier)\($0.frame)" }.joined(separator: " "))

        var violations = geometryViolations(cards: cards, block: block, atAccessibilitySize: atAccessibilitySize)
        if auditing {
            violations += try scopedAuditViolations(app: app, within: block.frame, named: "insights-\(label)")
        }
        if !violations.isEmpty { attachFailureDiagnostics(app: app, label: "phase8-insights-\(label)") }
        return violations
    }

    /// The measurement itself, and the reason it is phrased in half-widths.
    ///
    /// A score card's accessibility element hugs its CONTENT (ring plus label),
    /// not the grid cell — measured, at `AccessibilityXXXL`, at 225pt and 281pt
    /// inside a 366pt grid, against 100pt each at the standard size. So "the
    /// tile fills the grid" is not observable from here, but the discriminator
    /// is: content wider than half the grid CANNOT have fitted a two-up column,
    /// and content narrower than half cannot have been alone on its row. Both
    /// directions are stated, so neither size can pass vacuously.
    @MainActor
    private func geometryViolations(
        cards: [XCUIElement],
        block: XCUIElement,
        atAccessibilitySize: Bool
    ) -> [String] {
        var violations: [String] = []
        // The fixture serves four renderable scores. Fewer than two on screen
        // means the fixture never reached the grid, and every clause below would
        // then be a statement about an empty screen.
        guard cards.count >= 2 else {
            return ["only \(cards.count) score cards rendered; the derived-batch fixture never reached the grid"]
        }
        let width = block.frame.width
        guard width > 1 else { return ["the score-card grid reported no width"] }

        let sharedRows = cards.enumerated().contains { index, card in
            cards.dropFirst(index + 1).contains { abs($0.frame.midY - card.frame.midY) < 1 }
        }
        let widest = cards.map(\.frame.width).max() ?? 0
        let narrowest = cards.map(\.frame.width).min() ?? 0
        let half = width / 2

        if atAccessibilitySize {
            if sharedRows {
                violations.append("two score cards still share a row at AccessibilityXXXL")
            }
            if narrowest <= half {
                violations.append(
                    "a score card is \(Int(narrowest))pt inside a \(Int(width))pt grid at AccessibilityXXXL, "
                        + "which still fits a two-up column"
                )
            }
        } else {
            if !sharedRows {
                violations.append("the standard-size grid no longer places two cards on a row")
            }
            if widest >= half {
                violations.append("the standard-size grid stopped being two-up (\(Int(widest))pt of \(Int(width))pt)")
            }
        }
        return violations
    }

    /// The native audit over the four types this phase owns, scoped by geometry
    /// to the grid under test. Every finding is printed; only the ones inside the
    /// owned surface are returned as violations.
    @MainActor
    private func scopedAuditViolations(
        app: XCUIApplication,
        within owned: CGRect,
        named screen: String
    ) throws -> [String] {
        var mine: [String] = []
        var elsewhere: [String] = []
        try app.performAccessibilityAudit(for: [.contrast, .dynamicType, .hitRegion, .textClipped]) { issue in
            let frame = issue.element?.frame ?? .null
            // The element's IDENTIFIER and type, never its label: a label on
            // this screen carries a rendered figure, and a gate log is not a
            // place for one even when the figure is a fixture's invention.
            let element = issue.element.map { "\($0.elementType.rawValue)#\($0.identifier)@\(Int($0.frame.minY))" }
            let described = "\(screen): \(issue.compactDescription) [\(element ?? "no element")]"
            if !frame.isNull, owned.intersects(frame) {
                mine.append(described)
            } else {
                elsewhere.append(described)
            }
            // Handled here so the audit raises no failures of its own; the single
            // named assertion in the test is the only reported one.
            return true
        }
        print("PHASE8-DIAGNOSTIC audit outside the owned grid (\(screen)): \(elsewhere)")
        return mine
    }
}
