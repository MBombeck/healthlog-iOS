import Foundation
@testable import HealthLog
import Testing

/// The hero dismissal flag persists and is wiped on logout. The collapsed
/// coach coin these tests also covered was never shown and is gone.
@Suite("coachHeroDismissed (COACH-COIN)")
@MainActor
struct AskCoachCollapsedCoinTests {
    // MARK: - SettingsStore flag contract

    private func makeSettingsStore(suiteName: String? = nil) throws -> SettingsStore {
        let suite = suiteName ?? "coach-coin-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let api = StubAPIClient()
        let repo = SettingsRepository(api: api)
        return SettingsStore(repo: repo, defaults: defaults)
    }

    @Test("coachHeroDismissed defaults to false on a fresh install")
    func coachHeroDismissedDefaultsFalse() throws {
        let store = try makeSettingsStore()
        #expect(store.coachHeroDismissed == false)
    }

    @Test("coachHeroDismissed persists across SettingsStore instances")
    func coachHeroDismissedPersists() throws {
        let suite = "coach-coin-tests-persist-\(UUID().uuidString)"
        let first = try makeSettingsStore(suiteName: suite)
        first.coachHeroDismissed = true
        let second = try makeSettingsStore(suiteName: suite)
        #expect(second.coachHeroDismissed == true)
    }

    @Test("clearOnLogout wipes coachHeroDismissed back to false")
    func clearOnLogoutResetsHeroDismissed() throws {
        let store = try makeSettingsStore()
        store.coachHeroDismissed = true
        store.clearOnLogout()
        #expect(store.coachHeroDismissed == false)
    }
}
