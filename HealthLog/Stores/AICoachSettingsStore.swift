import Foundation
import Observation

/// **Build 6 / Item 6.6** — drives the two Coach/AI privacy controls on
/// ``SettingsCoachScreen``: the "read documents with AI" auto-switch
/// (`documentsAutoAiRead`) and the Insights data-detail picker
/// (`insightsPrivacyMode`).
///
/// Server-first (PROJECT_GUIDE.md): the values are owned by the server; this store is
/// an in-memory mirror re-hydrated on every surface appearance. Writes are
/// optimistic — the control snaps immediately, then reverts to the prior value
/// if the server rejects, so the UI never lies about persisted state.
///
/// The two flags are fetched + written independently: one endpoint failing
/// (e.g. an older server missing the documents route) must not blank the other
/// control.
@MainActor
@Observable
public final class AICoachSettingsStore {
    /// Server `documentsAutoAiRead`. OFF until the first successful load.
    public private(set) var documentsAutoAiRead: Bool = false
    /// Server `insightsPrivacyMode`. `aggregated` (server default) until loaded.
    public private(set) var insightsPrivacyMode: InsightsPrivacyMode = .aggregated

    /// **Build 9 (Server-Prefs) / 9.2** — server-wide "coach disabled" flag
    /// (`disableCoach`). `nil` until the first successful load: the initial state
    /// comes FROM the server and there is NO iOS default to write up (guard 1 —
    /// the iOS-default-OFF must NEVER be PATCHed as `disableCoach=true`, which
    /// would kill the web coach on all the user's devices). The UI presents the
    /// inverse ("Coach aktiviert" = `!coachDisabled`) and hides while `nil`.
    public private(set) var coachDisabled: Bool?
    /// **Build 9 (Server-Prefs) / 9.2** — mirror of `reminderSuggestions.enabled`
    /// (coach-prefs). `nil` until the first successful load; the server default is
    /// ON (calm-by-default) when the key/blob is absent. Also mirrored into
    /// `CoachCadenceSuggestionsDefaultsKeys.serverMirrorEnabled` so the pure
    /// `CoachCadenceSuggestionsStore` reader consults it.
    public private(set) var reminderSuggestionsEnabled: Bool?

    /// `true` once at least one field has been hydrated from the server. Drives
    /// the "value not resolved yet" disabled state on the controls.
    public private(set) var didLoad: Bool = false
    /// `true` while a write for the documents toggle is in flight.
    public private(set) var isDocumentsWriteInFlight: Bool = false
    /// `true` while a write for the insights-privacy mode is in flight.
    public private(set) var isInsightsWriteInFlight: Bool = false
    /// `true` while a write for the server coach-availability toggle is in flight.
    public private(set) var isCoachWriteInFlight: Bool = false
    /// `true` while a write for the reminder-suggestions toggle is in flight.
    public private(set) var isReminderWriteInFlight: Bool = false
    /// Last non-retriable error surfaced by a load or write, for a banner.
    public private(set) var error: HLError?

    private let repo: AICoachSettingsRepository
    private let defaults: UserDefaults
    /// **9.2** — optional so the `coach` module availability can be optimistically
    /// mirrored after a disable-coach toggle (surfaces appear/disappear without a
    /// `/me` refresh). `nil` in unit tests that don't exercise that path.
    private let moduleGate: ModuleGate?

    public init(
        repo: AICoachSettingsRepository,
        defaults: UserDefaults = .standard,
        moduleGate: ModuleGate? = nil
    ) {
        self.repo = repo
        self.defaults = defaults
        self.moduleGate = moduleGate
    }

    /// Re-hydrate both flags from the server. Independent per-field so one
    /// endpoint's failure leaves the other control on its last-known value.
    public func load() async {
        error = nil
        async let docs = repo.fetchDocumentsAutoAiRead()
        async let insights = repo.fetchInsightsPrivacyMode()
        async let disable = repo.fetchDisableCoach()
        async let reminder = fetchReminderSuggestionsEnabled()
        do {
            documentsAutoAiRead = try await docs
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
        do {
            insightsPrivacyMode = try await insights
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
        // Build 9 (9.2) — fail-soft + NO network write. On error the mirror
        // property stays `nil` so the UI hides the toggle rather than adopting a
        // wrong default; on success it hydrates the property + the UserDefaults
        // mirror. A `nil`/absent server value is adopted, never written back
        // (no ping-pong).
        if let value = try? await disable {
            coachDisabled = value
            defaults.set(value, forKey: Keys.coachDisabled)
        }
        if let value = try? await reminder {
            reminderSuggestionsEnabled = value
            defaults.set(value, forKey: CoachCadenceSuggestionsDefaultsKeys.serverMirrorEnabled)
        }
        didLoad = true
    }

    /// GET coach-prefs and extract `reminderSuggestions.enabled`. An absent key /
    /// legacy blob resolves to the server default ON (calm-by-default). Throws
    /// only on a transport/decoding failure → the caller leaves the mirror `nil`.
    private func fetchReminderSuggestionsEnabled() async throws -> Bool {
        let raw = try await repo.fetchCoachPrefsRaw()
        if case let .object(reminder)? = raw["reminderSuggestions"],
           case let .bool(enabled)? = reminder["enabled"]
        {
            return enabled
        }
        return true
    }

    /// **9.2 explicit user toggle** — the ONLY path that writes `disableCoach`
    /// (never load/hydration, guard 1). Optimistic + PATCH + revert. On success it
    /// also optimistically mirrors the `coach` module availability so the coach
    /// surfaces appear/disappear without a `/me` refresh.
    public func setCoachDisabled(_ disabled: Bool) async {
        guard coachDisabled != disabled else { return }
        let previous = coachDisabled
        coachDisabled = disabled
        defaults.set(disabled, forKey: Keys.coachDisabled)
        isCoachWriteInFlight = true
        error = nil
        defer { isCoachWriteInFlight = false }
        do {
            let echoed = try await repo.setDisableCoach(disabled)
            coachDisabled = echoed
            defaults.set(echoed, forKey: Keys.coachDisabled)
            moduleGate?.applyModuleOptimistic(wireKey: ModuleKey.coach.wireKey, enabled: !echoed)
        } catch let err as HLError {
            revertCoachDisabled(to: previous)
            error = err
        } catch {
            revertCoachDisabled(to: previous)
            self.error = .unknown(String(describing: error))
        }
    }

    private func revertCoachDisabled(to previous: Bool?) {
        coachDisabled = previous
        if let previous {
            defaults.set(previous, forKey: Keys.coachDisabled)
        } else {
            defaults.removeObject(forKey: Keys.coachDisabled)
        }
    }

    /// **9.2 explicit user toggle** — optimistic + coach-prefs RMW PUT (via the
    /// repo, preserving siblings) + revert.
    public func setReminderSuggestionsEnabled(_ enabled: Bool) async {
        guard reminderSuggestionsEnabled != enabled else { return }
        let previous = reminderSuggestionsEnabled
        reminderSuggestionsEnabled = enabled
        defaults.set(enabled, forKey: CoachCadenceSuggestionsDefaultsKeys.serverMirrorEnabled)
        isReminderWriteInFlight = true
        error = nil
        defer { isReminderWriteInFlight = false }
        do {
            let updated = try await repo.setReminderSuggestionsEnabled(enabled)
            if case let .object(reminder)? = updated["reminderSuggestions"],
               case let .bool(confirmed)? = reminder["enabled"]
            {
                reminderSuggestionsEnabled = confirmed
                defaults.set(confirmed, forKey: CoachCadenceSuggestionsDefaultsKeys.serverMirrorEnabled)
            }
        } catch let err as HLError {
            revertReminder(to: previous)
            error = err
        } catch {
            revertReminder(to: previous)
            self.error = .unknown(String(describing: error))
        }
    }

    private func revertReminder(to previous: Bool?) {
        reminderSuggestionsEnabled = previous
        if let previous {
            defaults.set(previous, forKey: CoachCadenceSuggestionsDefaultsKeys.serverMirrorEnabled)
        } else {
            defaults.removeObject(forKey: CoachCadenceSuggestionsDefaultsKeys.serverMirrorEnabled)
        }
    }

    /// Optimistically flip `documentsAutoAiRead` and PATCH it. Reverts on a
    /// non-retriable error. Skips a no-op when the value already matches.
    public func setDocumentsAutoAiRead(_ enabled: Bool) async {
        guard documentsAutoAiRead != enabled else { return }
        let previous = documentsAutoAiRead
        documentsAutoAiRead = enabled
        isDocumentsWriteInFlight = true
        error = nil
        defer { isDocumentsWriteInFlight = false }
        do {
            // The route echoes the resolved state — hard-set it so the UI tracks
            // exactly what the server persisted.
            documentsAutoAiRead = try await repo.setDocumentsAutoAiRead(enabled)
        } catch let err as HLError {
            documentsAutoAiRead = previous
            error = err
        } catch {
            documentsAutoAiRead = previous
            self.error = .unknown(String(describing: error))
        }
    }

    /// Optimistically set `insightsPrivacyMode` and PUT it. Reverts on a
    /// non-retriable error. Skips a no-op when the mode already matches.
    public func setInsightsPrivacyMode(_ mode: InsightsPrivacyMode) async {
        guard insightsPrivacyMode != mode else { return }
        let previous = insightsPrivacyMode
        insightsPrivacyMode = mode
        isInsightsWriteInFlight = true
        error = nil
        defer { isInsightsWriteInFlight = false }
        do {
            try await repo.setInsightsPrivacyMode(mode)
        } catch let err as HLError {
            insightsPrivacyMode = previous
            error = err
        } catch {
            insightsPrivacyMode = previous
            self.error = .unknown(String(describing: error))
        }
    }

    /// Reset the in-memory mirror. Called on logout so the next user on a shared
    /// device never inherits the previous user's flags before their own load.
    public func clearOnLogout() {
        documentsAutoAiRead = false
        insightsPrivacyMode = .aggregated
        didLoad = false
        isDocumentsWriteInFlight = false
        isInsightsWriteInFlight = false
        error = nil
        // Build 9 (9.2) — server coach flags are per-user; the next signed-in user
        // hydrates fresh. Drop the properties + the two mirror keys.
        coachDisabled = nil
        reminderSuggestionsEnabled = nil
        isCoachWriteInFlight = false
        isReminderWriteInFlight = false
        defaults.removeObject(forKey: Keys.coachDisabled)
        defaults.removeObject(forKey: CoachCadenceSuggestionsDefaultsKeys.serverMirrorEnabled)
    }

    private enum Keys {
        /// Build 9 (9.2) — mirror of `disableCoach`. The reminder-suggestions
        /// mirror lives in `CoachCadenceSuggestionsDefaultsKeys.serverMirrorEnabled`
        /// (shared with the pure cadence reader).
        static let coachDisabled = "hl.settings.coach.disabled"
    }
}
