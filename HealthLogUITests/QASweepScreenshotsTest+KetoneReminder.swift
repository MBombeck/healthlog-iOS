import XCTest

/// A Vorsorge that targets blood ketones (`-uitest-ketone-reminder`,
/// `KetoneReminderFixtures`): the card names the type „Blutketone“ instead of
/// repeating its title, and the detail charts the ketone readings. Runs with
/// the sweep's language, appearance and text size. Only runs when `HL_SWEEP_OUT`
/// is set.
extension QASweepScreenshotsTest {
    func test_19k_ketoneReminder() {
        boot(extra: ["-uitest-ketone-reminder"])
        tab("ellipsis")
        guard let row = probe("more.row.vorsorge") else {
            note("19k: Vorsorge row not present")
            return
        }
        row.tap()
        settle(5)
        scrollUpToTop()
        shot("19k-vorsorge-ketone-card")
        guard let card = probe("vorsorge.card.openDetail.sweep-ketone-reminder") else {
            note("19k: ketone card not present")
            return
        }
        card.tap()
        settle(4)
        shot("19k-vorsorge-ketone-detail")
        scrollDown()
        shot("19k-vorsorge-ketone-detail-scrolled")
    }
}
