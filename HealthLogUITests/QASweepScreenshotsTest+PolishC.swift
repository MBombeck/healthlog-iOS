import XCTest

/// 1.5 POLISH-C (C6) — Settings, Assistant with a configured provider
/// (`-uitest-citations`), once at the default text size and once at the
/// largest accessibility size, where the provider's state pill used to break
/// into four lines beside the name. Runs with the sweep's language and
/// appearance. Only runs when `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_24_polishCProviderPill() {
        for size in [String?.none, "UICTContentSizeCategoryAccessibilityXXXL"] {
            let tag = size == nil ? "24-ai" : "24-ai-xxxl"
            bootAcceptingAI(extra: ["-uitest-citations"] + (size.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? []))
            // Evidence when the tab bar is covered: what is on screen and the
            // element tree, before the walk tries the tab.
            shot("\(tag)-start")
            if !app.phase8Tab("ellipsis").isHittable {
                note("polish-c: tab bar covered\n\(app.debugDescription)")
            }
            tab("ellipsis")
            if tap(app.buttons["more.toolbar.gear"], "settings gear") {
                settle(2)
                if let row = probe("settings.hub.ai") {
                    row.tap()
                    settle(3)
                    shotToEnd(tag)
                } else {
                    note("polish-c: no Assistant row in Settings")
                }
            }
            app.terminate()
        }
    }
}
