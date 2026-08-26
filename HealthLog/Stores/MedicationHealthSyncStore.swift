import Foundation
import Observation

/// **GH #47 — owns the "Sync medications with Apple Health" toggle (iOS 26+).**
///
/// OFF by default. Device-local UI-pref (`UserDefaults`) the server does not
/// know — the medication mirror is a purely client↔HealthKit concern. Flipping
/// it on requests **opt-in** HealthKit Medications read authorization (a
/// dedicated request, deliberately kept OUT of the always-on onboarding HK
/// sheet) and kicks a first import; flipping it off stops future sync.
///
/// The whole surface is gated on iOS 26 + HealthKit availability
/// (``isAvailable``). Below that the toggle is hidden and every method is a
/// no-op, so nothing references the iOS-26-only reader on an older OS.
@MainActor
@Observable
public final class MedicationHealthSyncStore {
    /// Whether Apple-Health medication sync is on (mirrors the UserDefaults pref).
    public private(set) var enabled: Bool
    /// True while the opt-in auth request is in flight (the toggle shows a spinner).
    public private(set) var isRequestingAuthorization = false
    /// iOS 26 + HealthKit Medications available on this device. When false the
    /// toggle must not be offered.
    public private(set) var isAvailable: Bool
    /// **CU-10** — the last sweep's user-facing obstruction, if any (mirror cap
    /// reached / unstable identifier). `nil` = the mirror is doing its job.
    /// Rendered as its own explanation under the toggle; a generic error banner
    /// would tell the user "something went wrong" for a condition that has a
    /// precise, actionable cause.
    public private(set) var mirrorIssue: AppleHealthMirrorIssue?

    private let repo: MedicationsRepository
    private let keychain: KeychainStoring
    private let reader: AppleHealthMedicationReading?
    private let defaults: UserDefaults
    /// **Phase 07 / plan 07-05** — the account every sweep is admitted under.
    ///
    /// Bound after construction (the composition root owns the Phase-06 lease
    /// registry, and this store's initializer is `public` while the lease
    /// vocabulary is module-internal). Without it the importer refuses to sweep,
    /// which is the correct posture: a mirror that cannot name its owner must
    /// not write a dose ledger.
    private var admission: HealthSyncImporterAdmission?

    /// Rebuilt on each activation for the CURRENT user (the registry partitions
    /// by user id) so a re-login never inherits the prior user's mirror map.
    private var importer: AppleHealthMedicationImporter?

    static let prefKey = "hl.medications.syncWithAppleHealth"

    public init(
        repo: MedicationsRepository,
        keychain: KeychainStoring,
        reader: AppleHealthMedicationReading?,
        defaults: UserDefaults = .standard
    ) {
        self.repo = repo
        self.keychain = keychain
        self.reader = reader
        self.defaults = defaults
        isAvailable = reader?.isAvailable ?? false
        // Force off when the feature isn't available so a stale pref can't claim
        // a sync that can't run.
        enabled = (reader?.isAvailable ?? false) && defaults.bool(forKey: Self.prefKey)
    }

    /// Hands this store the admission every sweep runs under. Rebuilding the
    /// importer afterwards is deliberate: an importer built before the binding
    /// captured no admission and would refuse forever.
    func bindHealthSyncAdmission(_ admission: HealthSyncImporterAdmission) {
        self.admission = admission
        importer = nil
    }

    /// Restore the mirror on launch when the toggle is already on. Cheap no-op
    /// when off / unavailable.
    public func activateIfEnabled() async {
        guard enabled, isAvailable else { return }
        await runSweep()
    }

    /// Trigger a mirror sweep if the feature is on (foreground / BG hook).
    public func triggerSyncIfEnabled() async {
        guard enabled, isAvailable else { return }
        await runSweep()
    }

    /// One sweep + the state it leaves behind. `sync()` (not the fire-and-forget
    /// protocol hop) so the summary's ``AppleHealthMedicationSyncSummary/issue``
    /// reaches the UI instead of being logged and dropped.
    private func runSweep() async {
        let summary = await makeImporter().sync()
        mirrorIssue = summary.issue
    }

    /// Flip the toggle. Turning ON requests Medications read auth (and runs a
    /// first import on success); turning OFF stops future sync. The pref
    /// persists regardless so the choice survives relaunch.
    public func setEnabled(_ newValue: Bool) async {
        guard isAvailable else { return }
        guard newValue != enabled else { return }
        if newValue {
            isRequestingAuthorization = true
            defer { isRequestingAuthorization = false }
            do {
                try await reader?.requestAuthorization()
            } catch {
                HLLog.healthKit.error(
                    "medication Apple-Health auth failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
                enabled = false
                defaults.set(false, forKey: Self.prefKey)
                return
            }
            enabled = true
            defaults.set(true, forKey: Self.prefKey)
            await runSweep()
        } else {
            enabled = false
            defaults.set(false, forKey: Self.prefKey)
            importer = nil
            mirrorIssue = nil
        }
    }

    /// Reset on logout / user-change: force the toggle off + clear the per-user
    /// mirror registry so the next user starts clean (mirrors the mood importer).
    public func deactivateOnLogout() async {
        registry().reset()
        enabled = false
        defaults.set(false, forKey: Self.prefKey)
        importer = nil
        mirrorIssue = nil
    }

    // MARK: - Helpers

    private func registry() -> AppleHealthMirrorRegistry {
        AppleHealthMirrorRegistry(userID: keychain.getString(forKey: KeychainKey.userID))
    }

    private func makeImporter() -> AppleHealthMedicationImporter {
        if let importer { return importer }
        // reader is non-nil whenever isAvailable is true (checked by callers).
        let reader = reader ?? UnavailableAppleHealthMedicationReader()
        let built = AppleHealthMedicationImporter(
            reader: reader,
            repo: repo,
            keychain: keychain,
            registry: registry(),
            admission: admission?.provider(for: .appleMedication)
        )
        importer = built
        return built
    }

    /// Server medication ids this device has mirrored. A local hint only —
    /// since server v1.32.25 `GET /api/medications` echoes `externalSource`, so
    /// the provenance gate reads ``Medication/isAppleHealthMirrored`` instead of
    /// guessing from here.
    public func mirroredMedicationIDs() -> Set<String> {
        registry().mirroredMedicationIDs()
    }
}

/// Inert reader used only when the feature is unavailable (keeps `makeImporter`
/// total without an optional). `isAvailable == false` makes the importer's own
/// gate short-circuit before any read.
private struct UnavailableAppleHealthMedicationReader: AppleHealthMedicationReading {
    var isAvailable: Bool {
        false
    }

    func requestAuthorization() async throws {}
    func readMedications() async throws -> [AppleHealthMedicationRecord] {
        []
    }

    func readDoseEvents(since _: Date?) async throws -> [AppleHealthDoseRecord] {
        []
    }
}
