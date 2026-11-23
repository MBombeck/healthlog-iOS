import Foundation

public extension AICoachSettingsRepository {
    /// The Coach's reading window (`coach-prefs.defaultWindow`).
    func fetchCoachDefaultWindow() async throws -> CoachDefaultWindow? {
        try await CoachDefaultWindow.from(fetchCoachPrefsRaw())
    }

    /// Read-modify-write of `defaultWindow` alone, on the guarded full-replace
    /// PUT; a conflict re-applies it to the freshly read object.
    @discardableResult
    func setCoachDefaultWindow(_ window: CoachDefaultWindow) async throws -> CoachDefaultWindow? {
        let raw = try await fetchCoachPrefsRaw()
        let applied = window.applied(to: raw)
        try await putCoachPrefs(applied) { fresh in window.applied(to: fresh) }
        return CoachDefaultWindow.from(applied)
    }
}
