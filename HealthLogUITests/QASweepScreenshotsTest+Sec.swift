import XCTest

/// 1.5 SEC — the proof before a connector token (`-uitest-sec`, `SecFixtures`):
/// Create on the mint sheet opens "Confirm it's you" before anything is sent,
/// with exactly the proofs the account names (password and passkey); closing
/// it leaves the mint sheet with the sentence and no token. An account that
/// signs in only through its organisation (`-uitest-sec-sso-only`) is told
/// that the app cannot confirm it. Runs with the sweep's language, appearance
/// and text size. Only runs when `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_20s_mcpProofFirst() {
        boot(extra: ["-uitest-sec"])
        guard openMintSheet() else { return }
        shot("20s-mcp-mint")
        guard submitMint() else { return }
        XCTAssertTrue(element("stepUp.record.sheet").waitForExistence(timeout: 8), "20s: no proof sheet before the mint")
        settle(3)
        // The proof sheet stays up: the mint sheet below it is still there.
        XCTAssertTrue(element("stepUp.record.sheet").exists, "20s: proof sheet went away by itself")
        shot("20s-mcp-proof")
        swipeTopSheetDown()
        XCTAssertFalse(element("stepUp.record.sheet").exists, "20s: proof sheet did not close")
        XCTAssertTrue(element("settings.mcp.mint.submit").exists, "20s: mint sheet closed with the proof sheet")
        XCTAssertFalse(element("settings.mcp.reveal.token").exists, "20s: a token was minted without proof")
        shot("20s-mcp-mint-cancelled")
    }

    func test_20s_mcpProofSsoOnly() {
        boot(extra: ["-uitest-sec", "-uitest-sec-sso-only"])
        guard openMintSheet(), submitMint() else { return }
        // POLISH-C (C1, #163 B1) — an account without factor or passkey
        // mints on the token: no proof sheet, no way to the browser.
        settle(4)
        XCTAssertFalse(element("stepUp.record.sheet").exists, "20s: an SSO-only account was asked for a proof")
        shot("20s-mcp-sso-only-no-proof")
    }

    /// More, gear, MCP connector, Create token.
    private func openMintSheet() -> Bool {
        tab("ellipsis")
        guard tap(app.buttons["more.toolbar.gear"], "settings gear") else { return false }
        settle(2)
        guard let mcp = probe("settings.hub.mcp") else {
            note("20s: MCP row not present")
            return false
        }
        mcp.tap()
        settle(4)
        guard let create = probe("settings.mcp.tokens.create") else {
            note("20s: Create token row not present")
            return false
        }
        create.tap()
        settle(3)
        return true
    }

    private func submitMint() -> Bool {
        let field = element("settings.mcp.mint.name")
        guard tap(field, "token name") else { return false }
        field.typeText("Claude")
        return tap(element("settings.mcp.mint.submit"), "Create")
    }

    /// Drags the topmost sheet down by its upper edge.
    private func swipeTopSheetDown() {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.13))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        settle(3)
    }
}
