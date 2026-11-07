import XCTest

/// 1.5 MOVE — "Unterwegs" on the environment screen against a connected
/// Dawarich (`-uitest-move`, `MovementFixtures`): the latest day with every
/// row and a travel day, one day back without coverage, then over the month
/// end to 31 October; the not-connected line (`-uitest-move-disconnected`);
/// the Dawarich row in Settings › Integrations. Without the argument the
/// sweep's server answers like one before v1.43 (no section), which is the
/// "before" picture and the older-server case. Runs with
/// the sweep's language, appearance and text size. Only runs when
/// `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_21_movement() {
        boot(extra: ["-uitest-move"])
        guard openEnvironment() else { return }
        showMovement("21-move-latest")
        // 3 Nov -> 2 Nov (no coverage) -> 1 Nov (no values) -> 31 Oct (month end).
        for name in ["21-move-noCoverage", "21-move-noValues", "21-move-monthEnd"] {
            stepBack()
            showMovement(name)
        }
        guard !isXXL else { return }
        goBack()
        tab("ellipsis")
        guard tap(app.buttons["more.toolbar.gear"], "settings gear") else { return }
        settle(2)
        if let integrations = probe("settings.hub.integrations") {
            integrations.tap()
            settle(3)
            if probe("settings.integrations.dawarichRow") == nil { note("Dawarich row not on screen") }
            shot("21-move-integrations")
        }
    }

    func test_21_movementDisconnected() {
        boot(extra: ["-uitest-move-disconnected"])
        guard openEnvironment() else { return }
        showMovement("21-move-disconnected")
    }

    /// The sweep's own server, no Dawarich: the "before" picture.
    func test_21_movementBefore() {
        guard !isXXL else { return }
        boot()
        guard openEnvironment() else { return }
        shotToEnd("21-move-before")
    }

    private func openEnvironment() -> Bool {
        tab("ellipsis")
        scrollUpToTop()
        guard let row = probe("more.row.environment") else {
            note("More row not present: environment")
            return false
        }
        row.tap()
        settle(4)
        return true
    }

    private func showMovement(_ name: String) {
        scrollUpToTop()
        let found = probe("environment.movement.day") ?? probe("environment.movement.notConnected")
        if found == nil { note("\(name): movement section not on screen") }
        shot(name)
        scrollDown()
        shot("\(name)-rows")
    }

    private func stepBack() {
        scrollUpToTop()
        guard let back = probe("environment.movement.previous") else {
            note("previous-day arrow not hittable")
            return
        }
        back.tap()
        settle(2)
    }
}
