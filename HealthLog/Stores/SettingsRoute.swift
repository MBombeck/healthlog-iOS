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
}
