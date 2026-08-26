import Foundation

/// **Phase 16 Plan 03 — which device-local syncs a completed onboarding grant
/// may switch on (decision E2).**
///
/// "An per Default" cannot mean "silently on": Apple always asks. What E2 buys
/// is that the two types are IN the first system sheet, and that answering it
/// leaves the corresponding sync running — so EKG and Stimmung are, in the
/// operator's terms, *dabei und aktiv* without a trip to
/// Einstellungen → Apple Health → Weitere Synchronisierungen, the drawer he
/// called unauffindbar (J1).
///
/// A value rather than two conditions inside a view's `request()`, because the
/// asymmetry below is a product rule and deserves to be readable and testable
/// on its own.
enum FirstSheetSyncAdoption {
    /// What a grant activates on this install.
    struct Plan: Equatable, Sendable {
        /// Apple-Health mood sync (``MoodHealthSyncStore``).
        let mood: Bool
        /// ECG upload (``EcgHealthSyncStore``).
        let ecg: Bool
    }

    /// - Parameter hasAuthenticatedServer: whether this install holds a usable
    ///   session against a paired server (`BackendAvailability.isAuthenticated`).
    ///
    /// **Mood is unconditional.** It is device-local end to end — HealthKit to
    /// HealthLog and back — and the server knows nothing about it, so a
    /// standalone install can run it exactly as a paired one does.
    ///
    /// **The ECG upload is not.** Its only destination is
    /// `POST /api/insights/ecg`; on a standalone install there is nowhere to
    /// send a waveform, and the settings row hides for that same reason
    /// (`AppleHealthIntegrationDetailScreen` gates it on `backend.hasServer`).
    /// Switching on a sync that has no target would leave a hidden toggle
    /// reading ON, which is a smaller version of the lie this phase exists to
    /// remove. The read permission is still asked for in the first sheet — that
    /// is E2 — but the transfer only starts where a transfer can happen.
    static func plan(hasAuthenticatedServer: Bool) -> Plan {
        Plan(mood: true, ecg: hasAuthenticatedServer)
    }
}
