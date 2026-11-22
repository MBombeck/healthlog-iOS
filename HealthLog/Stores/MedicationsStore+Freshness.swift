import Foundation

/// #191 — the store's share of the 1.49.0 contract, one stored property on
/// ``MedicationsStore``: where the capabilities are read (tests point it at
/// their own suite), the `medications.lastUpdatedAt` of the data on screen,
/// and the freshness check in flight.
struct MedicationContractState {
    var capabilityDefaults: UserDefaults? = MedicationCapabilities.appGroupDefaults
    var loadedStamp: MedicationFreshnessStamp?
    var freshnessCheck: Task<Void, Never>?
    /// 1.7: the cap of the current dose hold (``DoseStateConfirmation``).
    var doseHold: Task<Void, Never>?
}

/// **#191 (final) — what the freshness check compares.** Medication-row
/// changes (a snooze, a schedule edit) move `medications.lastUpdatedAt`; dose
/// changes (the auto-skip cron included) move `intakes.lastUpdatedAt` and the
/// live and tombstoned counts. A difference in any of them reloads.
public struct MedicationFreshnessStamp: Sendable, Equatable {
    public let medicationsUpdatedAt: Date?
    public let intakesUpdatedAt: Date?
    public let intakesLive: Int?
    public let intakesTombstoned: Int?

    public init(
        medicationsUpdatedAt: Date?,
        intakesUpdatedAt: Date? = nil,
        intakesLive: Int? = nil,
        intakesTombstoned: Int? = nil
    ) {
        self.medicationsUpdatedAt = medicationsUpdatedAt
        self.intakesUpdatedAt = intakesUpdatedAt
        self.intakesLive = intakesLive
        self.intakesTombstoned = intakesTombstoned
    }

    /// `nil` when the server carries neither block (an older server).
    public init?(state: ServerSyncStateDTO) {
        guard state.medications != nil || state.intakes != nil else { return nil }
        self.init(
            medicationsUpdatedAt: state.medications?.lastUpdatedAt,
            intakesUpdatedAt: state.intakes?.lastUpdatedAt,
            intakesLive: state.intakes?.liveCount,
            intakesTombstoned: state.intakes?.tombstonedCount
        )
    }
}

/// **#188 (1), stable in #191 — is the phone's medication state current?**
///
/// `GET /api/sync/state` carries `medications.lastUpdatedAt` and the
/// `intakes` block (``MedicationFreshnessStamp``). The app compares it on every
/// foreground and on every notification interaction and reloads when it
/// differs from the stamp of the data it shows. A dose the pill box, the web
/// or Telegram recorded while the app slept is then on screen before the
/// person can take it twice.
extension MedicationsStore {
    /// Pure decision: reload when the server names a stamp the loaded data
    /// does not carry. No stamp (an older server) never reloads.
    nonisolated static func freshnessNeedsReload(
        serverStamp: MedicationFreshnessStamp?,
        loadedStamp: MedicationFreshnessStamp?
    ) -> Bool {
        guard let serverStamp else { return false }
        return serverStamp != loadedStamp
    }

    /// Logout: the next account starts without a stamp or a check in flight.
    func resetFreshness() {
        contract.freshnessCheck?.cancel()
        contract.freshnessCheck = nil
        contract.loadedStamp = nil
    }

    /// Reloads when `serverStamp` differs from the loaded data's stamp. The
    /// stamp is taken over only after a fresh today answer, so a failed reload
    /// is retried by the next check.
    func reconcileFreshness(serverStamp: MedicationFreshnessStamp?) async {
        guard Self.freshnessNeedsReload(serverStamp: serverStamp, loadedStamp: contract.loadedStamp) else {
            // 1.7: the server names the stamp of the data on screen, so that
            // data is current: the sync confirms it before the reload lands.
            if serverStamp != nil { noteDoseStateConfirmedBySync() }
            return
        }
        guard let sessionLease = captureAuthenticatedSessionLease() else { return }
        let before = freshTodayIntakesDeliveries
        await load(force: true)
        guard authenticatedEffectIsCurrent(sessionLease) else { return }
        if freshTodayIntakesDeliveries != before { contract.loadedStamp = serverStamp }
    }
}

public extension AppContainer {
    /// One freshness check (see ``MedicationsStore/reconcileFreshness(serverStamp:)``).
    /// Only where the server publishes the stamp
    /// (``MedicationCapability/medicationsLastUpdated``), so an older server
    /// costs no extra handshake. Fail-quiet: offline leaves everything as it is.
    @MainActor
    func checkMedicationFreshness() async {
        // 1.7: a short deadline. The check holds the store's single slot, so
        // a request hanging for the session's 20 s would block every check of
        // the next foregrounds behind it.
        guard MedicationCapabilities.isOpen(.medicationsLastUpdated, defaults: medicationsStore.contract.capabilityDefaults),
              let state = await MedicationFreshnessDeadline.handshake(serverStatsRepos.syncState) else { return }
        await medicationsStore.reconcileFreshness(serverStamp: MedicationFreshnessStamp(state: state))
    }

    /// Starts the check in a task of its own, so the foreground pass's
    /// deadline cannot cancel it. A check already running is reused.
    @MainActor
    func startMedicationFreshnessCheck() {
        medicationsStore.startFreshnessCheck { [weak self] in
            await self?.checkMedicationFreshness()
        }
    }
}

public extension AppContainer {
    /// **1.7 — the app opens (cold start once signed in, return from the
    /// background).** Synchronously holds a stale dose state neutral, then
    /// starts `/api/sync/state` and the today reload side by side, each in a
    /// task the store owns: neither waits behind the foreground pass's
    /// ordered legs nor is cancelled by its deadline (#188 (1)).
    @MainActor
    func revalidateDoseStateOnOpen() {
        guard medicationsStore.captureAuthenticatedSessionLease() != nil else { return }
        medicationsStore.refreshDoseStateIfStale()
        startMedicationFreshnessCheck()
        medicationsStore.startForegroundRevalidation()
    }
}
