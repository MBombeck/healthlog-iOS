import Foundation
@testable import HealthLog
import Testing

/// v0.14.3 B1 — locks the dismissible Coach hero UI-pref on `SettingsStore`.
///
/// The Insights overview Coach hero (`AskCoachHeroCard`) carries a close (x)
/// affordance that sets `settings.coachHeroDismissed = true`. The flag is a pure
/// UI-pref persisted in UserDefaults (PROJECT_GUIDE.md: UI-prefs only), so the dismissal
/// must survive an app relaunch — i.e. a fresh `SettingsStore` reading the same
/// defaults suite must read `coachHeroDismissed == true` again. This suite pins
/// the default (false → hero shows on a fresh install) and the persisted
/// round-trip (dismissal stays gone).
@MainActor
@Suite("SettingsStore — Coach hero dismiss persistence (B1)")
struct SettingsStoreCoachHeroDismissTests {
    private static func makeStore(suiteName: String) throws -> SettingsStore {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let api = StubAPIClient()
        let repo = SettingsRepository(api: api)
        return SettingsStore(repo: repo, defaults: defaults)
    }

    @Test("defaults to false — a fresh install shows the Coach hero")
    func defaultIsFalse() throws {
        let store = try Self.makeStore(suiteName: "hl.tests.coachHero.\(UUID().uuidString)")
        #expect(store.coachHeroDismissed == false)
    }

    @Test("dismissal persists across a relaunch (UserDefaults round-trip)")
    func dismissalPersists() throws {
        let suite = "hl.tests.coachHero.\(UUID().uuidString)"
        let storeA = try Self.makeStore(suiteName: suite)
        #expect(storeA.coachHeroDismissed == false)

        // Operator taps the close (x) on the Coach hero.
        storeA.coachHeroDismissed = true

        // Relaunch: a fresh store against the same defaults suite must read the
        // dismissal back — the hero stays gone.
        let storeB = try Self.makeStore(suiteName: suite)
        #expect(storeB.coachHeroDismissed == true)
    }
}
