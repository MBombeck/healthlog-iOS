import Foundation
import Observation

/// Nonisolated UserDefaults key for the proactive coach cadence-suggestions
/// opt-in. Kept in a plain enum so `@AppStorage(...)` call-sites (the Settings
/// toggle) don't drag MainActor isolation into nonisolated `@ViewBuilder`s.
public enum CoachCadenceSuggestionsDefaultsKeys {
    /// Master opt-in for surfacing proactive cadence suggestions as Insights
    /// cards. **Default ON** — calm-by-default: the suggestions are quiet,
    /// dismissible accept/dismiss cards, never push notifications, and self-
    /// suppress when there is nothing to offer. The operator can switch the whole
    /// surface off here. See ``CoachCadenceSuggestionsStore`` for the gating
    /// contract.
    public static let enabled: String = "hl.coach.cadenceSuggestions.enabled"
    /// The locally-suppressed cadence ids (a dismissed suggestion the server
    /// hasn't yet stopped re-offering must not nag). JSON-encoded `[String]`.
    public static let dismissed: String = "hl.coach.cadenceSuggestions.dismissed"
    /// **Build 9 (Server-Prefs) / 9.2** — server mirror of
    /// `coach-prefs.reminderSuggestions.enabled`, written by `AICoachSettingsStore`
    /// on load/toggle. When set (i.e. the Coach was reached) it is the primary
    /// source for ``CoachCadenceSuggestionsStore/enabledOptIn()``; the legacy
    /// ``enabled`` key is consulted only when this mirror was never written.
    public static let serverMirrorEnabled: String = "hl.settings.coach.reminderSuggestions.enabled"
}

/// **W-COACH-CADENCE (#30)** — `@MainActor @Observable` driver behind the
/// proactive coach cadence-suggestion cards (Insights overview, near the coach
/// surface).
///
/// **Inline-sourced (server is authority).** A cadence suggestion reaches the
/// client **inline during a coach chat turn** as a discrete SSE `suggestion`
/// frame (see ``CoachServerService/CoachReminderSuggestion``). There is NO
/// proactive `GET /api/coach/reminder-suggestions` — the route exports only the
/// action POST. ``CoachConversationStore`` mints a ``CoachCadenceSuggestion``
/// from the decoded frame and calls ``present(_:)`` here so the same suggestion
/// also appears as a calm Insights card (not only mid-chat). The store never
/// recomputes / fabricates a cadence.
///
/// **Gated on present.** ``present(_:)`` no-ops unless the opt-in toggle is ON,
/// the cadence is not locally-dismissed, and no HealthLog Focus filter is pausing
/// coach nudges. (The coach-module + online gates are already enforced upstream —
/// the inline suggestion only exists because a coach turn succeeded.)
///
/// **Self-suppressing + non-nagging.** Accept and Dismiss both drop the row
/// optimistically on the same tick; a dismissed `cadenceId` is also recorded in
/// a local suppressed-set so a server still re-offering it (before its own stop
/// reconciles) doesn't re-surface it. The dismiss POST is best-effort — a `404`
/// / not-live route leaves the local suppression in place so it still doesn't
/// nag.
///
/// **Accept = server-minted reminder.** Accept POSTs `{ cadenceId, action:
/// accept }` which creates the reminder **server-side** (origin COACH); the store
/// then asks the shared ``MeasurementRemindersStore`` to re-list so the new
/// reminder lands in the native list — it never fabricates a reminder row locally
/// (no client-side cadence-widening, per #30 contract).
@MainActor
@Observable
public final class CoachCadenceSuggestionsStore {
    /// The live, non-suppressed suggestions to render. Empty until an inline
    /// coach turn presents one — no fabricated state.
    public private(set) var suggestions: [CoachCadenceSuggestion] = []

    private let repo: CoachCadenceSuggestionsRepository
    /// Re-listed after an accept so the new server-minted reminder appears in the
    /// native reminders list. Weak: the store must not extend its life.
    private weak var remindersStore: MeasurementRemindersStore?
    private let defaults: UserDefaults
    /// W-FOCUS-FILTER — resolves the live Focus-filter config. Injected so tests
    /// stay isolated from the shared App Group suite; production reads the store.
    private let focusFilterConfig: @MainActor () -> FocusFilterConfig

    /// Locally-suppressed cadence ids — a dismissed suggestion the server may
    /// still momentarily re-offer must not re-surface. Persisted across launches.
    private var dismissedIDs: Set<String>

    /// `focusFilterConfig` defaults to **inactive** (no Focus filter) so a unit
    /// test never inherits the shared App Group suite. Production (AppContainer)
    /// passes the shared-store reader explicitly.
    public init(
        repo: CoachCadenceSuggestionsRepository,
        remindersStore: MeasurementRemindersStore? = nil,
        defaults: UserDefaults = .standard,
        focusFilterConfig: @escaping @MainActor () -> FocusFilterConfig = { .inactive }
    ) {
        self.repo = repo
        self.remindersStore = remindersStore
        self.defaults = defaults
        self.focusFilterConfig = focusFilterConfig
        dismissedIDs = Self.loadDismissed(from: defaults)
    }

    // MARK: - Ingest (inline coach-turn suggestion)

    /// Present an inline-sourced cadence suggestion as an Insights card — gated.
    ///
    /// Called by ``CoachConversationStore`` when a coach chat turn surfaced an
    /// SSE `suggestion` frame. No-ops (and clears nothing) when:
    ///   - the opt-in toggle is OFF (the operator switched the surface off), or
    ///   - the cadence is in the local suppressed-set (already dismissed), or
    ///   - a HealthLog Focus filter is pausing coach nudges.
    ///
    /// Otherwise the suggestion is upserted (keyed on `cadenceId`) so the same
    /// cadence presented twice never stacks duplicate cards.
    public func present(_ suggestion: CoachCadenceSuggestion) {
        guard enabledOptIn() else { return }
        guard !dismissedIDs.contains(suggestion.cadenceId) else { return }
        // W-FOCUS-FILTER — while a HealthLog Focus filter is active with "pause
        // coach nudges" on, hold back the proactive cadence cards. The card never
        // carries PHI; the inline in-chat card is unaffected (the user is
        // actively in a coach turn there).
        guard !focusFilterConfig().suppressesCoachNudges else { return }
        suggestions.removeAll { $0.cadenceId == suggestion.cadenceId }
        suggestions.append(suggestion)
    }

    /// The opt-in toggle's resolved value. **Default ON** — calm-by-default: the
    /// surface is quiet + self-suppressing, so absent an explicit opt-out the
    /// inline suggestions are surfaced as cards. A nil stored value (never
    /// toggled) reads as ON.
    private func enabledOptIn() -> Bool {
        // Build 9 (9.2) — the server mirror wins once it has been written (Coach
        // reached). It is authoritative across devices; the legacy device-local
        // key is only the pre-server fallback.
        let mirror = CoachCadenceSuggestionsDefaultsKeys.serverMirrorEnabled
        if defaults.object(forKey: mirror) != nil {
            return defaults.bool(forKey: mirror)
        }
        let key = CoachCadenceSuggestionsDefaultsKeys.enabled
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }

    // MARK: - Actions

    /// Accept a suggestion: drop it optimistically, POST `{ cadenceId, accept }`
    /// (the server creates the reminder, origin COACH), then re-list the native
    /// reminders so the new row appears. On failure the row is restored.
    /// Returns `true` when the server accepted.
    @discardableResult
    public func accept(_ suggestion: CoachCadenceSuggestion) async -> Bool {
        await act(suggestion, action: .accept, suppressLocally: false, refreshReminders: true)
    }

    /// Dismiss a suggestion: drop it optimistically, record it in the local
    /// suppressed-set so it can't re-surface, then best-effort POST
    /// `{ cadenceId, dismiss }`. A failed / not-live POST still leaves the local
    /// suppression in place (it won't nag). Returns `true` when the POST landed.
    @discardableResult
    public func dismiss(_ suggestion: CoachCadenceSuggestion) async -> Bool {
        await act(suggestion, action: .dismiss, suppressLocally: true, refreshReminders: false)
    }

    private func act(
        _ suggestion: CoachCadenceSuggestion,
        action: CoachCadenceSuggestionsRepository.Action,
        suppressLocally: Bool,
        refreshReminders: Bool
    ) async -> Bool {
        let snapshot = suggestions
        suggestions.removeAll { $0.id == suggestion.id }
        if suppressLocally { recordDismissed(suggestion.cadenceId) }
        do {
            try await repo.act(cadenceId: suggestion.cadenceId, action: action)
            if refreshReminders { await remindersStore?.load(force: true) }
            return true
        } catch {
            // Dismiss: keep the local suppression (it must still not nag) — do
            // NOT restore the row. Accept: a failed create is honest, restore the
            // card so the user can retry.
            if !suppressLocally { suggestions = snapshot }
            // Operator-grade only: the action verb (an enum case) + the sanitized
            // error. The suggestion text is NEVER part of the message. Split
            // across interpolations so each `.public` value is independently
            // auditable (M-7 doctrine).
            let verb = action.rawValue
            let safeError = LogSanitizer.redact(String(describing: error))
            HLLog.api.error(
                "Coach cadence-suggestion action failed: \(verb, privacy: .public) — \(safeError, privacy: .public)"
            )
            return false
        }
    }

    // MARK: - Logout

    /// Drop in-memory suggestions on logout so the next user never inherits the
    /// previous user's coach cadence cards. The persisted dismissed-set is keyed
    /// per device, not per account; it is intentionally NOT wiped here (a stale
    /// dismissal at worst hides one suggestion the next user could re-surface by
    /// toggling the surface — never a PHI leak, since cadence ids are opaque).
    public func clearOnLogout() {
        suggestions = []
    }

    // MARK: - Dismissed-set persistence

    private func recordDismissed(_ cadenceId: String) {
        dismissedIDs.insert(cadenceId)
        if let data = try? JSONEncoder().encode(Array(dismissedIDs)) {
            defaults.set(data, forKey: CoachCadenceSuggestionsDefaultsKeys.dismissed)
        }
    }

    private static func loadDismissed(from defaults: UserDefaults) -> Set<String> {
        guard let data = defaults.data(forKey: CoachCadenceSuggestionsDefaultsKeys.dismissed),
              let ids = try? JSONDecoder().decode([String].self, from: data) else
        {
            return []
        }
        return Set(ids)
    }

    /// Test-only seed — set the visible suggestions without an ingest round-trip
    /// (the logout-wipe + render suites use this).
    func seedForTesting(_ next: [CoachCadenceSuggestion]) {
        suggestions = next
    }
}
