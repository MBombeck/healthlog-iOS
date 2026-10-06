import XCTest

/// **#115 P2 — the imperial account, photographed.**
///
/// TestFlight 1.1.0 (284): "Units set to imperial but range is showing metric."
/// The dashboard weight tile read "162.1 lb" over "Target 61.9–83.3 kg". This
/// boots the sweep world with `-uitest-imperial` (`ImperialUnitFixtures`:
/// `/me` says `unitPreference: "imperial"`, the targets route serves the
/// tester's canonical 61.9–83.3 kg band) and photographs the weight tile, the
/// whole dashboard around it and the weight page. Like the rest of the sweep it
/// only runs when `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_12_imperialUnits() {
        guard !isXXL else { return }
        boot(extra: ["-uitest-imperial"])
        let tile = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'tile.weight.withChart' OR identifier == 'tile.weight.noChart'")
        ).firstMatch
        var tries = 0
        while !(tile.exists && tile.isHittable && tile.frame.maxY < app.windows.firstMatch.frame.maxY * 0.85), tries < 8 {
            scrollDown()
            tries += 1
        }
        guard tile.exists else {
            note("imperial: weight tile not found")
            return
        }
        settle(2)
        shot("12-imperial-dashboard")
        let crop = tile.screenshot()
        let url = URL(fileURLWithPath: outputDir).appendingPathComponent("12-imperial-weight-tile.png")
        do {
            try crop.pngRepresentation.write(to: url)
        } catch {
            note("write failed 12-imperial-weight-tile: \(error)")
        }
        openDeepLink("healthlog://insights/weight")
        settle(5)
        shotPair("12-imperial-weight-page")
    }
}
