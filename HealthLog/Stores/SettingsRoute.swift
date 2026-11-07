import Foundation

/// Typed `morePath` payload for the Settings stack, resolved by a
/// `.navigationDestination(for:)` in `MoreScreen`.
///
/// Lives in its own file per the `file_length` discipline in `PROJECT_GUIDE.md` —
/// `AppRouter.swift` had grown past the 600-line budget and this enum is the
/// one self-contained piece of it. Pure move: no case added or removed here,
/// no behaviour changed.
enum SettingsRoute: Hashable {
    case root
    case notifications
    /// v0.14.1 — Settings → Assistant ("KI"-Hub). Pushed by
    /// ``AppRouter/requestSettingsAssistant()`` so the Coach's "External AI
    /// needs a server provider" surface can route the user to where they set
    /// one up, instead of silently bouncing back to the chooser.
    case assistant
    /// Web-parity `TodayHero` — Settings → Integrations. Pushed by
    /// ``AppRouter/requestSettingsIntegrations()`` so the daily-digest rail's
    /// `sync.reconnect` action lands where a broken integration is reconnected.
    case integrations
    /// CU-37 — Settings → Integrationen → Apple-Health-Import. Pushed by
    /// ``AppRouter/requestAppleHealthImport()`` so the ECG surface's empty state
    /// can hand the operator the archive-import path it names instead of only
    /// describing it.
    case appleHealthImport
    /// GH #74 — Settings → Integrationen → Apple Health. Pushed by
    /// ``AppRouter/requestAppleHealthSettings()`` so the ECG empty state can
    /// hand over the upload switch itself instead of describing where it lives
    /// (UI-Standard R4 — Wegweiser werden Absprünge).
    case appleHealthDetail
    /// #141 — Settings → Sicherheit, the push path `/settings/security` of a
    /// security alert. Pushed by ``AppRouter/applyMoreStackRoute(_:)``.
    case security
    /// #141 — Vorsorge (`/checkups`), pushed straight onto the More stack.
    case checkups
    /// #141 — the cycle home (`/cycle`), pushed straight onto the More stack.
    case cycle
    /// #153 follow-up — Settings › Server › Access headers. A value, so the
    /// page comes back after the privacy shield rebuilt the window.
    case serverAccessHeaders
    /// POLISH-C (C2) — the pages one level further down, pushed as values so
    /// they come back after the privacy shield too: Account › Sessions,
    /// Account › Security › Passkeys and › Two-factor, and each provider page
    /// under Integrations.
    case sessions
    case passkeys
    case twoFactor
    case integration(IntegrationRoute)
}

/// POLISH-C (C2) — one provider page under Settings › Integrations.
enum IntegrationRoute: Hashable, CaseIterable {
    case withings
    case whoop
    case oura
    case polar
    case fitbit
    case strava
    case nightscout
}
