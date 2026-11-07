import Foundation

public extension AICoachSettingsRepository {
    /// 1.5 COACH-R — `coachReasoning` from `GET /api/auth/me`; `nil` on a
    /// server older than v1.41.
    func fetchCoachReasoning() async throws -> CoachReasoningState? {
        let request: APIRequest<AuthMeCoachReasoning> = .get("/api/auth/me")
        return try await api.send(request).coachReasoning
    }

    /// Read-modify-write of `coach-prefs.reasoning` alone on the guarded
    /// full-replace PUT; a conflict re-applies it to the freshly read object.
    /// Returns the state the server resolved afterwards (caps applied).
    func setCoachReasoning(_ level: CoachReasoningLevel) async throws -> CoachReasoningState? {
        let raw = try await fetchCoachPrefsRaw()
        let apply: @Sendable ([String: HLJSONValue]) -> [String: HLJSONValue] = { prefs in
            var prefs = prefs
            prefs["reasoning"] = .string(level.rawValue)
            return prefs
        }
        try await putCoachPrefs(apply(raw), reapply: apply)
        return try await fetchCoachReasoning()
    }
}
