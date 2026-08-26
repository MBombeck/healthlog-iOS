import Foundation
import Observation

/// **GH #74 — owns the "EKGs aus Apple Health übernehmen" switch.**
///
/// **16-03 / decision E2 (operator, 2026-08-22).** Two things used to be true
/// here and only one still is. The ECG read type sat outside the always-on
/// onboarding sheet because until server v1.35.3 there was nowhere to send a
/// waveform, and asking for the most sensitive thing HealthKit holds without a
/// use for it would have been an empty promise. That reason expired, and the
/// operator moved the type into the first sheet: "EKG und Stimmung wandern in
/// das erste HealthKit-Sheet." A completed onboarding grant therefore switches
/// this on through ``adoptFirstSheetGrant()``, and the drawer under
/// Einstellungen → Apple Health → Weitere Synchronisierungen is no longer the
/// only way to find it (J1).
///
/// The second reason still holds, and shapes the adoption rather than the type
/// set: the upload is a *server* act — `POST /api/insights/ecg`, gated on the
/// `insights` module — so ``FirstSheetSyncAdoption`` activates it only where a
/// paired, authenticated server exists. A standalone install is asked for the
/// permission with everything else, and simply does not start a transfer that
/// has no destination.
///
/// The switch itself stays exactly what it was: an explicit control on the
/// Apple-Health screen, next to the other behaviour toggles (mood, medications,
/// cycle). ``setEnabled(_:)`` still requests the ECG read permission at the
/// moment it is turned on — the recovery path for a user who declined the first
/// sheet — and kicks a first sweep; turning it off stops the sweep and clears
/// the cursor, so a later re-enable starts from the beginning rather than from a
/// stale position.
///
/// The switch itself is a **device-local UI pref** (`UserDefaults`): the server
/// knows nothing about it, exactly like ``MoodHealthSyncStore``. It is not a
/// module — inventing an `ecg` module key the server does not publish would put
/// the two sides out of step.
@MainActor
@Observable
public final class EcgHealthSyncStore {
    /// Whether ECG upload is on.
    public private(set) var enabled: Bool

    /// True while the authorization sheet is in flight (the toggle shows a
    /// spinner and refuses a second tap).
    public private(set) var isRequestingAuthorization = false

    private let healthKit: AnyHealthKitWriter?
    private let sync: (any EcgSyncing)?
    /// Clears the per-user HealthKit cursor on opt-out / logout. Held as a
    /// closure so the store does not need the coordinator's concrete type.
    private let resetAnchor: @Sendable () async -> Void
    private let defaults: UserDefaults

    /// `nonisolated` because the coordinator reads this pref off the main actor
    /// (see ``isOptedIn(in:)``) — a background sweep must not have to hop to the
    /// UI just to read a boolean.
    nonisolated static let prefKey = "hl.ecg.uploadFromAppleHealth"

    public init(
        healthKit: AnyHealthKitWriter?,
        sync: (any EcgSyncing)?,
        resetAnchor: @escaping @Sendable () async -> Void = {},
        defaults: UserDefaults = .standard
    ) {
        self.healthKit = healthKit
        self.sync = sync
        self.resetAnchor = resetAnchor
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.prefKey)
    }

    /// Run a sweep on launch when the switch is already on. Cheap no-op when
    /// off — and the coordinator self-gates as well, so a stale call is safe.
    public func activateIfEnabled() async {
        guard enabled else { return }
        await sync?.triggerEcgSync()
    }

    /// Flip the switch.
    ///
    /// ON requests ECG read authorization and, on success, runs the first
    /// sweep (which backfills the full history from an empty cursor). A refused
    /// or failed request leaves the switch OFF: the UI must not claim an upload
    /// path that cannot run.
    ///
    /// OFF stops there and clears the cursor. Clearing matters — leaving a
    /// cursor behind would mean a later re-enable silently skipped everything
    /// recorded while the switch was off, which is precisely the "quietly
    /// missing recordings" failure this path exists to avoid.
    public func setEnabled(_ newValue: Bool) async {
        guard newValue != enabled else { return }
        if newValue {
            isRequestingAuthorization = true
            defer { isRequestingAuthorization = false }
            do {
                try await healthKit?.requestEcgAuthorizationIfNeeded()
            } catch {
                HLLog.healthKit.error(
                    "ECG Apple-Health auth failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
                enabled = false
                defaults.set(false, forKey: Self.prefKey)
                return
            }
            enabled = true
            defaults.set(true, forKey: Self.prefKey)
            await sync?.triggerEcgSync()
        } else {
            enabled = false
            defaults.set(false, forKey: Self.prefKey)
            await resetAnchor()
        }
    }

    /// **16-03 / decision E2 — adopt a grant the first HealthKit sheet already
    /// obtained.**
    ///
    /// Deliberately NOT ``setEnabled(_:)``: that path exists to ask for the
    /// permission at the moment the user flips the switch, and the whole point
    /// of E2 is that the ECG read type is now in the first sheet, so the
    /// permission has just been answered. Calling `setEnabled(true)` here would
    /// raise a second system sheet for a type the user has already decided
    /// about — the sequential-dialog shape the operator's answer chose against.
    ///
    /// Idempotent, and it never turns anything OFF. A user who was already
    /// synced keeps their cursor; a user who has explicitly switched this off
    /// and then re-runs onboarding on the same install is the only case where
    /// this would flip a deliberate `false`, and that case cannot arise — the
    /// only caller is the onboarding permission step, and reaching it again
    /// means a fresh install, whose pref is absent.
    public func adoptFirstSheetGrant() async {
        guard !enabled else { return }
        enabled = true
        defaults.set(true, forKey: Self.prefKey)
        await sync?.triggerEcgSync()
    }

    /// Logout / user change: force the switch OFF and clear the cursor, so the
    /// next user on this device never inherits either the consent or the
    /// position in the previous user's ECG stream.
    public func deactivateOnLogout() async {
        enabled = false
        defaults.set(false, forKey: Self.prefKey)
        await resetAnchor()
    }
}
