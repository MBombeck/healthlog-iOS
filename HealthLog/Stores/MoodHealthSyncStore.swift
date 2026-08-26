import Foundation
import Observation

/// **v0.10.0 W-Mood-B — owns the "Mit Apple Health synchronisieren" toggle.**
///
/// **16-03 / decision E2 (operator, 2026-08-22): "EKG und Stimmung wandern in
/// das erste HealthKit-Sheet."** The State-of-Mind type is now a member of
/// `defaultReadTypes` and `defaultWriteTypes`, so a completed onboarding grant
/// switches this on through ``adoptFirstSheetGrant()`` — no second system sheet,
/// and no trip to the Einstellungen → Apple Health drawer the operator called
/// unauffindbar (J1). Mood sync is device-local end to end, so unlike the ECG
/// upload it is activated on every install, standalone included.
///
/// ``setEnabled(_:)`` keeps its old shape and is now the recovery path: a user
/// who declined the first sheet and later flips the toggle gets the dedicated
/// State-of-Mind request at that moment. When off, no auth request, no import
/// observer — and the writers no-op on `writeMood` because the toggle gates the
/// whole feature.
///
/// The toggle itself is a **UI-pref** (UserDefaults) the server doesn't know —
/// State-of-Mind sync is a purely client↔HealthKit concern (R-Mood-3: no server
/// work). `enabled` drives both the export (the `MoodStore.writeMood` calls are
/// only meaningful once auth is granted) and the import lifecycle.
@MainActor
@Observable
public final class MoodHealthSyncStore {
    /// Whether Apple-Health mood sync is on. Mirrors the UserDefaults pref;
    /// flipping it requests/stops auth + the importer.
    public private(set) var enabled: Bool

    /// True while an auth request is in flight (the toggle shows a spinner).
    public private(set) var isRequestingAuthorization = false

    private let healthKit: AnyHealthKitWriter?
    private let moodRepo: MoodRepository
    private let keychain: KeychainStoring
    private let defaults: UserDefaults

    static let prefKey = "hl.mood.syncWithAppleHealth"

    public init(
        healthKit: AnyHealthKitWriter?,
        moodRepo: MoodRepository,
        keychain: KeychainStoring,
        defaults: UserDefaults = .standard
    ) {
        self.healthKit = healthKit
        self.moodRepo = moodRepo
        self.keychain = keychain
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.prefKey)
    }

    /// Restore the importer on launch when the toggle is already on (the
    /// observer doesn't survive process death). Cheap no-op when off.
    public func activateIfEnabled() async {
        guard enabled, let healthKit else { return }
        await healthKit.startMoodImport(repo: moodRepo, userID: userID())
    }

    /// User-requested one-shot import. It is deliberately a no-op while the
    /// explicit mood toggle is off and never requests authorization.
    public func triggerSyncIfEnabled() async {
        guard enabled, let healthKit else { return }
        await healthKit.refreshMoodImport(repo: moodRepo, userID: userID())
    }

    /// Flip the toggle. Turning ON requests State-of-Mind auth (and starts the
    /// importer on success); turning OFF stops the importer. The pref persists
    /// regardless so the choice survives relaunch.
    public func setEnabled(_ newValue: Bool) async {
        guard newValue != enabled else { return }
        if newValue {
            isRequestingAuthorization = true
            defer { isRequestingAuthorization = false }
            do {
                try await healthKit?.requestMoodAuthorization()
            } catch {
                // Auth denied / unavailable — keep the toggle off so the UI
                // doesn't claim a sync that can't run.
                HLLog.healthKit.error(
                    "mood Apple-Health auth failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
                enabled = false
                defaults.set(false, forKey: Self.prefKey)
                return
            }
            enabled = true
            defaults.set(true, forKey: Self.prefKey)
            await healthKit?.startMoodImport(repo: moodRepo, userID: userID())
        } else {
            enabled = false
            defaults.set(false, forKey: Self.prefKey)
            await healthKit?.stopMoodImport()
        }
    }

    /// **16-03 / decision E2 — adopt a grant the first HealthKit sheet already
    /// obtained.**
    ///
    /// Deliberately NOT ``setEnabled(_:)``: that path asks for State-of-Mind
    /// read+share authorization at the moment the user flips the switch, and
    /// after E2 the type is in the first sheet, so the question has just been
    /// answered. Asking again would raise a second system sheet for a decision
    /// the user already made — exactly the sequential-dialog shape the
    /// operator's answer chose against.
    ///
    /// Idempotent, and it never turns anything OFF; the importer is started so
    /// moods logged elsewhere begin arriving without a trip to Settings.
    public func adoptFirstSheetGrant() async {
        guard !enabled else { return }
        enabled = true
        defaults.set(true, forKey: Self.prefKey)
        await healthKit?.startMoodImport(repo: moodRepo, userID: userID())
    }

    /// Reset Apple-Health mood sync on logout / user-change.
    ///
    /// **v0.10.0 W10 M2 — force the toggle OFF + reset the per-user import
    /// anchor.** Previously this only stopped the importer and left the
    /// device-local pref `true`, so a *different* user signing in on the same
    /// device re-activated the importer against a `nil` (per-user) anchor — and
    /// re-imported the entire `HKStateOfMind` history into the new account
    /// (cross-user mis-attribution). The next user must start clean: the pref is
    /// forced off (no auto-activation until an explicit re-opt-in) and the
    /// just-logged-out user's anchor is cleared so re-enabling never silently
    /// sweeps the full history.
    public func deactivateOnLogout() async {
        await healthKit?.resetMoodImport()
        enabled = false
        defaults.set(false, forKey: Self.prefKey)
    }

    private func userID() -> String? {
        keychain.getString(forKey: KeychainKey.userID)
    }
}
