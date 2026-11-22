import XCTest

/// The Today screen from its top down to its end, in every text size: the
/// hero with lead, score and facts, the hint section under it and the tiles.
/// `test_00` stops after one scroll, which at the largest text size ends
/// inside the hero. Only runs when `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_27_todayHero() {
        boot()
        shotToEnd("27-today")
    }

    /// The same screen with a dismissible milestone hint instead, so the
    /// dismiss mark shows alone in its corner.
    func test_28_todayDismissible() {
        boot(extra: ["-uitest-hero-dismissible"])
        shotToEnd("28-today-dismissible")
    }
}
