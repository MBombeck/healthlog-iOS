import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// v0.14.1 / #142 — locks the avatar dependency that `RootView`'s auth-phase
/// trigger resolves. `DashboardHeader`'s `.task(id: avatarReloadToken)` keys on
/// `settings.profile?.avatarUrl`; if `profile` is nil the avatar stays blank.
///
/// After an in-session re-login `clearOnLogout()` wipes `profile`, so nothing
/// resolves the avatar until `settings.load()` re-populates it — which is exactly
/// what `RootView.loadProfileOnAuthenticationIfNeeded()` now triggers on the
/// phase transition into `.authenticated`.
///
/// Covers:
/// - `load()` populates `profile.avatarUrl` (the dependency the header reads)
/// - `clearOnLogout()` nils `profile` (the bug precondition the trigger corrects)
/// - the `profile == nil` guard the trigger uses is honest after logout
@MainActor
@Suite("SettingsStore — avatar dependency resolution")
struct SettingsStoreAvatarDependencyTests {
    private func makeStore(profile: UserProfile) async -> SettingsStore {
        let api = StubAPIClient()
        await api.setHandler { request in
            // The store's `load()` fans out `repo.profile()` + `repo.healthKitConfig()`
            // concurrently; route by path so each call gets the right type. The
            // returned profile carries `avatarUrl`, so the `/me` avatar-merge
            // fallback never fires.
            let path = (request as? APIRequest<UserProfile>)?.path
                ?? (request as? APIRequest<HealthKitSyncConfig>)?.path
                ?? ""
            if path.contains("profile") { return profile }
            return HealthKitSyncConfig(entries: [], lastSyncedAt: nil)
        }
        let repo = SettingsRepository(api: api)
        let defaults = UserDefaults(suiteName: "SettingsStoreAvatarDependencyTests.\(UUID().uuidString)")!
        return SettingsStore(repo: repo, defaults: defaults)
    }

    private static func profile(avatarUrl: String?) -> UserProfile {
        UserProfile(
            username: "anna",
            displayName: "Anna",
            email: "anna@example.com",
            avatarUrl: avatarUrl,
            dateOfBirth: nil,
            gender: nil,
            heightCm: 175,
            locale: "de",
            timezone: "Europe/Berlin"
        )
    }

    @Test("load populates profile.avatarUrl — the header avatar dependency")
    func loadPopulatesAvatarDependency() async {
        let store = await makeStore(profile: Self.profile(avatarUrl: "/api/avatars/anna.png"))
        #expect(store.profile == nil) // precondition: a fresh re-login session
        await store.load()
        #expect(store.profile?.avatarUrl == "/api/avatars/anna.png")
    }

    @Test("clearOnLogout nils profile — the precondition the auth trigger corrects")
    func clearOnLogoutNilsProfile() async {
        let store = await makeStore(profile: Self.profile(avatarUrl: "/api/avatars/anna.png"))
        await store.load()
        #expect(store.profile != nil)
        store.clearOnLogout()
        // After logout `profile == nil`, so the RootView trigger's guard fires
        // and re-loads on the next transition into `.authenticated`.
        #expect(store.profile == nil)
    }
}
