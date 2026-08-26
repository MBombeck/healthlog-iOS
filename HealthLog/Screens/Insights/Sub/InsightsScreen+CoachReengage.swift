import Foundation

/// b182 (AUDIT-COACH-PARITY F1) — the pure decision behind the Insights Coach
/// re-engage affordance, extracted from `InsightsScreen.swift` to keep that file
/// under the file_length ceiling (PROJECT_GUIDE.md file_length discipline). Kept as a
/// `static` pure function (like `InsightsScreen+Helpers`) so the call site — which
/// owns the `private` `@Environment` reads — passes the inputs and this stays
/// unit-pinnable out of the View body.
extension InsightsScreen {
    /// True when the Coach is currently SUPPRESSED (`aiMode == .none`) but a server
    /// provider exists and the user simply hasn't consented yet (or declined the
    /// auto-sheet once, which permanently silences the shell auto-gate at
    /// `AuthenticatedShell.swift:250`). Without an affordance the Insights coach
    /// surface is a dead end: a prior decline / intent-only state hides the Coach
    /// with NO path back. When true the screen renders a calm "Enable the coach"
    /// entry (header circle + body card) that re-opens the consent choice via
    /// `AIConsentStore.requestExplicitPrompt()` — the shell's explicit-CTA path
    /// BYPASSES the `wasDeclined` suppression, so a declined user can re-engage and
    /// a grant can land.
    ///
    /// **W-B186 COACH-1 (#24) — admin/server-managed providers are now in scope.**
    /// Server v1.16.16 reports `aiAvailable == true` && `managedBy == "server"`
    /// even when `GET /api/user/ai-provider` exposes no per-user provider. In that
    /// case the re-engage CTA targets the **server-managed consent scope** (not a
    /// concrete provider), so the affordance is offered and the grant lands. Pass
    /// `isServerManagedAvailable` + `hasServerManagedConsent` for that path; the
    /// user-configured path (`resolvedProvider != .unconfigured`) is unchanged.
    ///
    /// - Parameters:
    ///   - aiMode: the resolved `AIMode` (the affordance is only for `.none`).
    ///   - coachFlagEnabled: the `assistant.coach` feature flag.
    ///   - hasServer: `BackendAvailability.hasServer` (server-only path).
    ///   - resolvedProvider: the server-resolved `AIProvider`.
    ///   - hasConsentForProvider: whether consent is already granted for it.
    ///   - isServerManagedAvailable: `config.usesProviderOpaqueAIConsent`.
    ///   - hasServerManagedConsent: whether the server-managed scope is granted.
    static func isCoachReengageAvailable(
        aiMode: AIMode,
        coachFlagEnabled: Bool,
        hasServer: Bool,
        resolvedProvider: AIProvider,
        hasConsentForProvider: Bool,
        isServerManagedAvailable: Bool = false,
        hasServerManagedConsent: Bool = false,
        isAIExplicitlyUnavailable: Bool = false
    ) -> Bool {
        guard aiMode == .none, coachFlagEnabled, hasServer else { return false }
        guard !isAIExplicitlyUnavailable else { return false }
        // W-B186 COACH-1 — server/admin-managed external AI: offer the re-engage
        // CTA against the server-managed scope when consent hasn't landed yet.
        if isServerManagedAvailable {
            return !hasServerManagedConsent
        }
        guard resolvedProvider != .unconfigured else { return false }
        return !hasConsentForProvider
    }
}
