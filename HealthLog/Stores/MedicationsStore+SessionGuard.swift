import Foundation

extension MedicationsStore {
    /// Replaces the anonymous test boundary with AppContainer's shared account
    /// generation. Binding is single-shot so a store can never drift between
    /// two registries while work is in flight.
    func bindAuthenticatedSessionRegistry(
        _ registry: AuthenticatedSessionLeaseRegistry,
        ownerIDProvider: @escaping @Sendable () -> String?
    ) {
        precondition(ownsAuthenticatedSessionRegistry, "authenticated registry already bound")
        authenticatedSessionRegistry.invalidate()
        authenticatedSessionRegistry = registry
        authenticatedSessionOwnerProvider = ownerIDProvider
        ownsAuthenticatedSessionRegistry = false
    }

    /// Captures immutable account identity once, before an authenticated
    /// operation reaches its first suspension.
    func captureAuthenticatedSessionLease() -> AuthenticatedSessionLease? {
        guard let ownerID = authenticatedSessionOwnerProvider()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !ownerID.isEmpty else
        {
            return nil
        }
        return authenticatedSessionRegistry.capture(ownerID: ownerID)
    }

    func authenticatedEffectIsCurrent(_ sessionLease: AuthenticatedSessionLease?) -> Bool {
        sessionLease?.isCurrent == true
    }

    /// Headless stores need a fresh anonymous generation after logout so later
    /// tests/previews still operate while every pre-clear lease stays stale.
    func rotateOwnedAuthenticatedSessionBoundary() {
        guard ownsAuthenticatedSessionRegistry else { return }
        authenticatedSessionRegistry.invalidate()
        authenticatedSessionRegistry.activate(ownerID: "_anonymous")
    }

    func awaitAuthenticatedSessionQuiescence() async {
        let tasks = [medicationsFanoutTask, complianceRefreshTask].compactMap { $0 }
        for task in tasks {
            await task.value
        }
    }

    /// **R5 — extend the local medication reminders without the network.**
    ///
    /// Single-occurrence reminders (a short course, every N weeks, cyclic …)
    /// reach only as far as the last reconcile armed them. A background wake —
    /// BGProcessing, BGAppRefresh, a silent push, an action on a reminder — is
    /// often the only time the app runs for days, and it may have no network.
    /// This runs the same reconcile the foreground load ends with
    /// (``reconcileSpeziSchedulerIfAvailable()``), from the list already in
    /// memory or, in a process the wake just launched, from the SWR cache.
    ///
    /// Fenced like a load: nothing happens without a current session lease, and
    /// a cached list read while the account changed is dropped. A list the store
    /// already holds is never replaced by the cached one.
    ///
    /// - Returns: `true` when a reconcile ran.
    @discardableResult
    func topUpRemindersFromCache() async -> Bool {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return false }
        if hasLoadedMedications || !medications.isEmpty {
            reconcileSpeziSchedulerIfAvailable()
            return true
        }
        guard let swr,
              let cached = await swr.peek(.medicationsList, as: [Medication].self) else { return false }
        guard authenticatedEffectIsCurrent(sessionLease) else { return false }
        // A load may have published while the cache was read; it wins.
        if medications.isEmpty {
            medications = cached.value
        }
        reconcileSpeziSchedulerIfAvailable()
        return true
    }
}

extension MedicationsStore {
    /// **#191 — the freshness check runs in a task the store owns**, so the
    /// foreground pass's deadline cannot cancel it. A check already running is
    /// reused; `clearOnLogout` cancels it (``resetFreshness()``), and the
    /// reload inside captures its own session lease.
    func startFreshnessCheck(_ check: @escaping @MainActor () async -> Void) {
        guard contract.freshnessCheck == nil else { return }
        contract.freshnessCheck = _Concurrency.Task { @MainActor [weak self] in
            await check()
            self?.contract.freshnessCheck = nil
        }
    }
}

// 1.7: the store's owned tasks and background effects of the dose
// confirmation (``DoseStateConfirmation``), kept with the other session-fenced
// tasks of the store.
extension MedicationsStore {
    /// Raises the hold and arms its cap (``doseConfirmationHoldCap``).
    func beginDoseHold(now: Date = .now) {
        doseConfirmation.holdGeneration &+= 1
        let generation = doseConfirmation.holdGeneration
        if !doseConfirmation.isPending {
            doseConfirmation.isPending = true
            doseConfirmation.pendingSince = now
        }
        contract.doseHold?.cancel()
        contract.doseHold = _Concurrency.Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.doseConfirmationHoldCap))
            guard !Task.isCancelled, let self, doseConfirmation.holdGeneration == generation else { return }
            settleDoseHold(reason: "cap")
        }
    }

    /// Waits until the SWR rows of the last answers are on disk. A background
    /// wake (silent push, relay, BGAppRefresh) calls it before it ends, so the
    /// next cold start paints the state the wake learned.
    func persistPendingCacheWrites() async {
        await swr?.drainPendingWrites()
    }

    /// **1.7 (R1 #8)** — a mark the server refused. Without a take there the
    /// row returns to what it was; with one (`alreadyTaken`) reopening it
    /// stood the dose there as open again, so it shows taken at the server's
    /// time and the reload brings the real row.
    func settleRefusedMark(intakeId: String, original: MedicationIntake, already: MedicationAlreadyTaken?) {
        if let idx = todayIntakes.firstIndex(where: { $0.id == intakeId }) {
            todayIntakes[idx] = already.map { Self.alreadyTakenRow(original, $0) } ?? original
        }
        onIntakesDidChange?()
        guard already != nil else { return }
        _Concurrency.Task { @MainActor [weak self] in await self?.load(force: true) }
    }
}
