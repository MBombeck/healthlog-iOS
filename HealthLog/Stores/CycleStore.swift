import Foundation
import Observation

/// `@Observable @MainActor` store backing the cycle surfaces.
///
/// Loads calendar / cycles / profile via ``CycleRepository`` (SWR cache-first)
/// and exposes the server-authoritative ``CycleVerdictDTO`` + ``CyclePredictionDTO``.
///
/// **Z1 (#72) — forecast and judgement part ways here.** Offline the on-device
/// ``CyclePredictionEngine`` still fills the FORECAST (labelled `.onDevice`);
/// the VERDICT is restored from the last one the server sent, dated, and never
/// recomputed — see `CycleStore+Verdict.swift`.
///
/// **Gated.** Every load is a no-op unless ``CycleGate/isCycleTrackingAvailable``
/// is true (which is itself hard-gated behind `FeatureFlag.cycleTracking`,
/// default OFF). A `403 cycle.disabled` flips ``isDisabled`` so the surface can
/// render a clean disabled state instead of an error. No UI is wired yet.
@MainActor
@Observable
public final class CycleStore {
    public private(set) var calendar: CycleCalendarResponse?
    public private(set) var cycles: [MenstrualCycleDTO] = []
    public private(set) var stats: CycleStatsDTO?
    public private(set) var profile: CycleProfileDTO?
    public private(set) var customSymptoms: [CycleCustomSymptomDTO] = []
    public private(set) var customSymptomsError: String?
    public private(set) var isLoadingCustomSymptoms = false
    private var hasLoadedCustomSymptoms = false
    public private(set) var insights: CycleInsightsDTO?
    public private(set) var insightsError: String?
    public private(set) var isLoadingInsights = false
    private var hasAttemptedInsights = false
    /// **Z1 (#72) — the cycle VERDICT the UI renders, and when the server made
    /// it.** Always server-computed: `state`, `phase` and `overdueDays` are
    /// never derived on the device (the server resolves "today" from the profile
    /// timezone, which this device may not have). Offline this holds the last
    /// stored verdict and ``verdictIsRestored`` flips, so the surface dates it
    /// instead of passing it off as current.
    public private(set) var verdict: CycleVerdictSnapshot?
    /// True when ``verdict`` came from the persisted snapshot rather than from a
    /// live server response in this load — the surface must show its "as of".
    public private(set) var verdictIsRestored = false
    /// The prediction the UI renders. Server-resolved DTO when present,
    /// otherwise the on-device fallback materialised into the same wire shape.
    ///
    /// The on-device engine may still produce THIS (dates, bands, the expected
    /// next start). It may not produce a ``verdict`` — that is the Z1 cut
    /// between forecast and judgement.
    public private(set) var prediction: CyclePredictionDTO?
    /// CU-25 (#72) — where ``prediction`` came from; `nil` when there is none.
    /// See ``CyclePredictionProvenance``.
    public private(set) var predictionProvenance: CyclePredictionProvenance?
    /// On-device prediction (offline / standalone parity path). Set when the
    /// server prediction is unavailable, and — since CU-25 — actually bridged
    /// into ``prediction`` (labelled) rather than computed and rendered by
    /// nothing.
    public private(set) var offlinePrediction: CyclePredictionEngine.Prediction?
    /// CU-25 (#72) — day keys the user answered "no, not a period start" for.
    /// In memory only: a date on which someone declined a period prompt is
    /// cycle data, and `UserDefaults` is for UI prefs, not health data.
    public private(set) var flowReconciliationDeclined: Set<String> = []
    public private(set) var isLoading = false
    /// True after a `403 cycle.disabled` — the account has not enabled tracking.
    public private(set) var isDisabled = false
    public private(set) var lastError: String?

    /// True for ~2 s after a successful day-log save — drives a minimal
    /// in-sheet confirmation. The richer calendar surface lands in C5.
    public private(set) var lastSaveSucceeded = false

    /// Module-internal rather than `private` so the split-out extensions
    /// (`CycleStore+Verdict`) can reach it — the file-length discipline moves
    /// code out of this file, not out of this type.
    let repository: CycleRepository
    private let gate: CycleGate
    private let availability: BackendAvailability?
    /// Optional Apple-Health mirror for MANUAL saves (C2 writer). When wired,
    /// a 2xx server write is followed by a best-effort HK mirror. Nil in tests
    /// / non-HK builds.
    private let healthKit: AnyHealthKitWriter?
    /// Resolves the current user id for the per-user import anchor partition.
    private let userIDProvider: @MainActor () -> String?
    /// Guards a redundant authorization request / importer start within a run.
    private var importerActive = false

    public init(
        repository: CycleRepository,
        gate: CycleGate,
        availability: BackendAvailability? = nil,
        healthKit: AnyHealthKitWriter? = nil,
        userIDProvider: @escaping @MainActor () -> String? = { nil }
    ) {
        self.repository = repository
        self.gate = gate
        self.availability = availability
        self.healthKit = healthKit
        self.userIDProvider = userIDProvider
    }

    // MARK: - Gated HealthKit lifecycle (C2 entry points, driven from C4)

    /// Refresh the gate, then drive the cycle HealthKit lifecycle to match.
    ///
    /// When eligible: request reproductive-category authorization (once) and
    /// start the foreign-sample importer (idempotent). When ineligible: stop
    /// the importer. This is the call that actually DRIVES the C2 importer /
    /// authorization the C2 report left "constructable but not yet driven".
    /// Call on app-foreground + after the opt-in toggle flips.
    public func refreshGateLifecycle() async {
        await gate.refreshAsync()
        guard gate.isCycleTrackingAvailable else {
            if importerActive {
                await healthKit?.stopCycleImportObserver()
                importerActive = false
            }
            return
        }
        guard !importerActive else { return }
        importerActive = true
        do {
            try await healthKit?.requestCycleAuthorizationIfNeeded()
        } catch {
            // Auth denied / unavailable — log + still continue: the server
            // remains the source of truth; the importer simply finds nothing.
            HLLog.healthKit.error(
                "cycle HK auth failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
            )
        }
        await healthKit?.startCycleImportIfEligible(repo: repository, userID: userIDProvider())
    }

    /// Stop + reset the cycle importer on logout / user-change so the next user
    /// starts from a clean anchor — AND drop the in-memory cycle state.
    ///
    /// **v0.14.8 W3 (AUDIT-SECURITY-B175 H-1):** this method existed but was
    /// never called from `performFullLocalLogout`, so the cycle HK import
    /// observer kept running under the next user's token (device cycle samples
    /// uploaded into the wrong account) and the long-lived container store kept
    /// rendering the previous user's calendar / predictions / profile until
    /// process death. Cycle is the highest-sensitivity data category in the
    /// app — it must meet the same bar as Mood (`MoodHealthSyncStore
    /// .deactivateOnLogout`) and Workouts (`resetWorkoutImportObserver`).
    /// `resetCycleImportObserver()` resets the per-user anchors, stops the
    /// observer and releases the importer (`HealthKitService.resetCycleImport`).
    public func deactivateOnLogout() async {
        await healthKit?.resetCycleImportObserver()
        importerActive = false
        // In-memory residue — the container-lifetime store would otherwise
        // paint the previous user's menstrual-cycle data on the next sign-in.
        resetInMemoryState()
    }

    /// Drop every in-memory cycle snapshot on logout so the next user on the
    /// same device never inherits the previous user's calendar / cycles /
    /// profile / prediction (reproductive-health data — the most sensitive
    /// surface in the app). Wired into the `AppContainer+Logout` cascade
    /// alongside ``deactivateOnLogout()`` (v0.14.8 tech-audit N5.2/N5.6
    /// logout-path sweep — the store previously survived logout fully
    /// populated).
    ///
    /// N5.6 — this store holds NO long-lived tasks today; if a revalidate-task
    /// pattern is ever added, hold + cancel the handle here (copy the
    /// `DerivedInsightsStore.clearOnLogout()` shape).
    public func clearOnLogout() {
        resetInMemoryState()
    }

    /// Drop every in-memory snapshot this store holds. Shared by both logout
    /// entry points and by ``purgeAll()`` so the reset list cannot drift between
    /// them — a property forgotten in one copy leaves the previous user's
    /// reproductive-health data painted on the next sign-in.
    private func resetInMemoryState() {
        calendar = nil
        cycles = []
        stats = nil
        profile = nil
        prediction = nil
        predictionProvenance = nil
        offlinePrediction = nil
        verdict = nil
        verdictIsRestored = false
        flowReconciliationDeclined = []
        customSymptoms = []
        customSymptomsError = nil
        isLoadingCustomSymptoms = false
        insights = nil
        hasLoadedCustomSymptoms = false
        insightsError = nil
        isLoadingInsights = false
        hasAttemptedInsights = false
        isLoading = false
        isDisabled = false
        lastError = nil
        lastSaveSucceeded = false
    }

    // MARK: - Writes (optimistic + Outbox + HealthKit mirror)

    /// Persist a single cycle day-log capture. Goes through the existing
    /// ``CycleRepository`` write path (optimistic POST → Outbox on retriable
    /// failure, idempotency-keyed). On a 2xx server write the row is mirrored
    /// into Apple Health (C2 writer) best-effort. Returns `true` when the row
    /// was accepted by the server or safely enqueued offline.
    ///
    /// No-op (returns `false`) while the gate is closed — the surface should
    /// never have been reachable in that case.
    @discardableResult
    public func saveDayLog(_ write: CycleDayLogWrite) async -> Bool {
        guard gate.isCycleTrackingAvailable else { return false }
        lastError = nil
        do {
            let dto = try await repository.logDayLog(write)
            lastSaveSucceeded = true
            // Best-effort Apple-Health mirror of the MANUAL row. Failure here
            // never fails the save (the server is the source of truth).
            if write.source == "MANUAL" {
                do {
                    try await healthKit?.writeCycleDayLogToHealth(dto, isCycleStart: isKnownCycleStartDay(dto.date))
                } catch {
                    HLLog.healthKit.error(
                        "cycle HK mirror failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                    )
                }
            }
            await load()
            return true
        } catch let err as HLError where err.shouldPersistToOutbox {
            // Enqueued for replay — treat as a (deferred) success so the sheet
            // can confirm + dismiss rather than blocking the user offline.
            lastSaveSucceeded = true
            return true
        } catch {
            if CycleRepository.isCycleDisabled(error) {
                isDisabled = true
            }
            lastError = LogSanitizer.redact(String(describing: error))
            return false
        }
    }

    /// One-tap period start/end quick action (`POST /api/cycle/period`).
    /// Reuses the repository write path (Outbox-backed). Returns `true` on a
    /// server-accepted or safely-enqueued write.
    @discardableResult
    public func setPeriod(_ request: CyclePeriodRequest) async -> Bool {
        guard gate.isCycleTrackingAvailable else { return false }
        lastError = nil
        do {
            try await repository.period(request)
            lastSaveSucceeded = true
            await load()
            return true
        } catch let err as HLError where err.shouldPersistToOutbox {
            lastSaveSucceeded = true
            return true
        } catch {
            if CycleRepository.isCycleDisabled(error) {
                isDisabled = true
            }
            lastError = LogSanitizer.redact(String(describing: error))
            return false
        }
    }

    /// Commit a manual day-log capture TOGETHER with an optional period
    /// start/end in a single Save (C4 reconcile — period is a Save-committed
    /// form choice, no longer an instant one-tap action). Both writes ride the
    /// existing Outbox-backed repository path; the calendar / prediction surface
    /// is refreshed ONCE at the end so the Cycle screen (ring + calendar)
    /// reflects the change. Returns `true` when both writes were accepted by the
    /// server or safely enqueued offline.
    ///
    /// No-op (returns `false`) while the gate is closed.
    @discardableResult
    public func commitCapture(
        dayLog write: CycleDayLogWrite,
        period request: CyclePeriodRequest?,
        existingID: String? = nil,
        patch: CycleDayLogPatch? = nil
    ) async -> Bool {
        guard gate.isCycleTrackingAvailable else { return false }
        lastError = nil
        var enqueuedOffline = false

        if let request {
            do {
                try await repository.period(request)
            } catch let error as HLError where error.shouldPersistToOutbox {
                enqueuedOffline = true
            } catch {
                if CycleRepository.isCycleDisabled(error) { isDisabled = true }
                lastError = LogSanitizer.redact(String(describing: error))
                return false
            }
        }

        do {
            let dto: CycleDayLogDTO = if let existingID, let patch {
                try await repository.updateDayLog(id: existingID, patch: patch)
            } else {
                try await repository.logDayLog(write)
            }
            if write.source == "MANUAL" {
                let isCycleStart = (request?.action == .start && request?.date == dto.date)
                    || isKnownCycleStartDay(dto.date)
                do {
                    try await healthKit?.writeCycleDayLogToHealth(dto, isCycleStart: isCycleStart)
                } catch {
                    HLLog.healthKit.error(
                        "cycle HK mirror failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                    )
                }
            }
        } catch let error as HLError where error.shouldPersistToOutbox && existingID == nil {
            enqueuedOffline = true
        } catch {
            if CycleRepository.isCycleDisabled(error) { isDisabled = true }
            lastError = LogSanitizer.redact(String(describing: error))
            return false
        }

        lastSaveSucceeded = true
        if !enqueuedOffline {
            await load()
        }
        return true
    }

    /// Is `date` (`YYYY-MM-DD`) a known menstrual-cycle start day? Drives the
    /// REQUIRED `HKMetadataKeyMenstrualCycleStart` metadata on the Apple-Health
    /// flow mirror. Best-effort from the cached (non-predicted) cycle list —
    /// when the cache is cold the flag is simply `false` (a valid HK value).
    private func isKnownCycleStartDay(_ date: String) -> Bool {
        cycles.contains { !$0.isPredicted && $0.startDate == date }
    }

    /// Reset the transient save-confirmation flag (call after the sheet shows
    /// + dismisses its confirmation).
    public func clearSaveConfirmation() {
        lastSaveSucceeded = false
    }

    public func dayLog(date: String) async -> CycleDayLogDTO? {
        guard gate.isCycleTrackingAvailable else { return nil }
        do {
            return try await repository.dayLog(date: date)
        } catch {
            if CycleRepository.isCycleDisabled(error) { isDisabled = true }
            lastError = LogSanitizer.redact(String(describing: error))
            return nil
        }
    }

    public func loadCustomSymptoms() async {
        guard gate.isCycleTrackingAvailable, !isLoadingCustomSymptoms, !hasLoadedCustomSymptoms else { return }
        isLoadingCustomSymptoms = true
        customSymptomsError = nil
        defer { isLoadingCustomSymptoms = false }
        do {
            customSymptoms = try await repository.customSymptoms()
            hasLoadedCustomSymptoms = true
        } catch {
            customSymptomsError = LogSanitizer.redact(String(describing: error))
        }
    }

    @discardableResult
    public func createCustomSymptom(label: String, icon: String? = nil) async -> CycleCustomSymptomDTO? {
        guard gate.isCycleTrackingAvailable else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1 ... 40).contains(trimmed.count) else {
            customSymptomsError = String(localized: "cycle.custom.error.invalid")
            return nil
        }
        customSymptomsError = nil
        do {
            let created = try await repository.createCustomSymptom(.init(label: trimmed, icon: icon))
            customSymptoms.append(created)
            return created
        } catch {
            customSymptomsError = LogSanitizer.redact(String(describing: error))
            return nil
        }
    }

    @discardableResult
    public func updateCustomSymptom(key: String, label: String, icon: RecordPatchField<String> = .unchanged) async -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard gate.isCycleTrackingAvailable, (1 ... 40).contains(trimmed.count) else {
            customSymptomsError = String(localized: "cycle.custom.error.invalid")
            return false
        }
        customSymptomsError = nil
        do {
            let updated = try await repository.updateCustomSymptom(
                key: key,
                patch: .init(label: trimmed, icon: icon)
            )
            if let index = customSymptoms.firstIndex(where: { $0.key == key }) {
                customSymptoms[index] = updated
            }
            return true
        } catch {
            customSymptomsError = LogSanitizer.redact(String(describing: error))
            return false
        }
    }

    @discardableResult
    public func softDeleteCustomSymptom(key: String) async -> Bool {
        guard gate.isCycleTrackingAvailable else { return false }
        customSymptomsError = nil
        do {
            _ = try await repository.softDeleteCustomSymptom(key: key)
            customSymptoms.removeAll { $0.key == key }
            return true
        } catch {
            customSymptomsError = LogSanitizer.redact(String(describing: error))
            return false
        }
    }

    public func loadInsights(force: Bool = false) async {
        guard gate.isCycleTrackingAvailable, !isLoadingInsights else { return }
        if hasAttemptedInsights, !force { return }
        hasAttemptedInsights = true
        isLoadingInsights = true
        insightsError = nil
        defer { isLoadingInsights = false }
        if force { await repository.invalidateInsights() }
        do {
            insights = try await repository.insights()
        } catch {
            insights = nil
            insightsError = LogSanitizer.redact(String(describing: error))
        }
    }

    @discardableResult
    public func updatePreferences(_ patch: CyclePrefsPatch) async -> Bool {
        guard gate.isCycleTrackingAvailable else { return false }
        lastError = nil
        do {
            profile = try await repository.updatePrefs(patch)
            return true
        } catch {
            if CycleRepository.isCycleDisabled(error) { isDisabled = true }
            lastError = LogSanitizer.redact(String(describing: error))
            return false
        }
    }

    /// Update the chosen secondary symptothermal sign (v1.16.15 —
    /// `MUCUS` / `CERVIX`) via `PATCH /api/auth/me/cycle-prefs`. Optimistically
    /// folds the new value into the in-memory ``profile`` so the advanced-settings
    /// toggle reflects the choice immediately, then reconciles with the
    /// server-returned merged profile. Reverts on failure. No-op while the gate is
    /// closed.
    @discardableResult
    public func updateSecondarySymptom(_ value: CycleSecondarySymptom) async -> Bool {
        guard gate.isCycleTrackingAvailable else { return false }
        lastError = nil
        let previous = profile
        // Optimistic local fold so the picker reflects the choice at once.
        if let previous {
            profile = previous.withSecondarySymptom(value.rawValue)
        }
        do {
            let merged = try await repository.updatePrefs(CyclePrefsPatch(secondarySymptom: value))
            profile = merged
            return true
        } catch {
            profile = previous
            if CycleRepository.isCycleDisabled(error) { isDisabled = true }
            lastError = LogSanitizer.redact(String(describing: error))
            return false
        }
    }

    /// One-tap hard purge (`DELETE /api/cycle/all`, server v1.16). Drops every
    /// in-memory snapshot on success, then reloads so the surface honestly
    /// reflects the (now empty) server state. NOT Outbox-backed — offline the
    /// purge fails and returns `false` (the settings row surfaces a retry).
    /// Apple-Health samples are deliberately untouched (the purge promise is
    /// server-side; HealthKit data stays under the user's Health-app control).
    @discardableResult
    public func purgeAll() async -> Bool {
        guard gate.isCycleTrackingAvailable else { return false }
        lastError = nil
        do {
            try await repository.purgeAll()
            // Everything, including the stored verdict: the purge promise is
            // that no dated reproductive trace survives.
            resetInMemoryState()
            await load()
            return true
        } catch {
            if CycleRepository.isCycleDisabled(error) {
                isDisabled = true
            }
            lastError = LogSanitizer.redact(String(describing: error))
            return false
        }
    }

    /// Load all cycle surfaces. No-op while the gate is closed. Falls back to the
    /// on-device engine when the server is unreachable or returns no prediction.
    public func load(window: CycleCalendarWindow = .default, cyclesLimit: Int = 24) async {
        guard gate.isCycleTrackingAvailable else { return }
        isLoading = true
        defer { isLoading = false }

        // Offline / standalone → skip the network entirely. The FORECAST is
        // recomputed on-device (labelled); the VERDICT is not — it is restored
        // from the last one the server sent, dated (Z1 / #72).
        if availability?.isReachable == false {
            await restoreStoredVerdict()
            await computeOfflinePrediction()
            return
        }

        do {
            async let cal = repository.calendar(from: window.from, to: window.to, dayAnchor: window.dayAnchor)
            async let list = repository.cycles(limit: cyclesLimit)
            async let prof = repository.profile()
            let (calendar, list2, profile) = try await (cal, list, prof)
            self.calendar = calendar
            cycles = list2.cycles
            stats = list2.stats
            self.profile = profile
            isDisabled = false
            lastError = nil
            await applyServerVerdict(calendar.verdict, generatedAt: calendar.generatedAt)
            if let serverPrediction = calendar.prediction {
                // The canonical value: the server computed it, the client just
                // consumes the resolved DTO.
                prediction = serverPrediction
                predictionProvenance = .server
                offlinePrediction = nil
            } else {
                // Server returned no prediction (e.g. still learning) — mirror
                // on-device so the surface still has the band/phase to draw. The
                // result is LABELLED `.onDevice`, never passed off as the record.
                prediction = nil
                predictionProvenance = nil
                await computeOfflinePrediction()
            }
        } catch {
            if CycleRepository.isCycleDisabled(error) {
                isDisabled = true
                prediction = nil
                predictionProvenance = nil
                offlinePrediction = nil
                verdict = nil
                verdictIsRestored = false
                lastError = nil
            } else {
                lastError = LogSanitizer.redact(String(describing: error))
                // Network failure → fall back to the on-device FORECAST so the
                // surface degrades gracefully rather than going blank, and to
                // the last stored VERDICT (dated) rather than a fresh judgement.
                await restoreStoredVerdict()
                await computeOfflinePrediction()
            }
        }
    }

    // MARK: - Verdict plumbing (Z1 / #72)

    /// The single publishing seam for the cycle verdict, so the plumbing can
    /// live in `CycleStore+Verdict.swift` (file-length discipline) without
    /// relaxing `private(set)` on the app's most sensitive store.
    func publishVerdict(_ snapshot: CycleVerdictSnapshot?, restored: Bool) {
        verdict = snapshot
        verdictIsRestored = restored
    }

    /// CU-25 (#72) — the single publishing seam for the on-device forecast, so
    /// ``computeOfflinePrediction(today:)`` can live in its own file without
    /// relaxing `private(set)` on the app's most sensitive store.
    func publishOfflinePrediction(
        _ computed: CyclePredictionEngine.Prediction?,
        dto: CyclePredictionDTO?,
        provenance: CyclePredictionProvenance?
    ) {
        offlinePrediction = computed
        prediction = dto
        predictionProvenance = provenance
    }

    /// CU-25 (#72) — remember a declined period prompt for `date` (in memory
    /// only, see ``flowReconciliationDeclined``).
    public func declineFlowReconciliation(for date: String) {
        flowReconciliationDeclined.insert(date)
    }
}

// `CycleCalendarWindow` lives in `HealthLog/Models/Cycle/CycleCalendarWindow.swift`
// (server-parity v1.16): the Repositories folder also compiles into the widgets
// extension, which does not include the Stores layer.
