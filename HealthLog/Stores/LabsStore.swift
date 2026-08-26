import Foundation
import Observation

/// `@MainActor @Observable` store backing the native labs + biomarker surfaces
/// (v1.18.1 `W-LABS`). Loads lab results + the biomarker catalog via
/// ``LabsRepository``, and drives optimistic delete with a `HLUndoToast`
/// restore (`POST /api/labs/restore`).
///
/// **Gated.** Every load is gated by the caller (`ModuleGate.isEnabled(.labs)`);
/// a `403 module.disabled` flips ``isDisabled`` so the surface renders a clean
/// disabled state instead of an error.
///
/// **Render-only range.** The store never recomputes a reference range or a
/// range verdict — `LabResultDTO.rangeStatus` is the singular NEUTRAL server
/// verdict and is rendered as-is.
@MainActor
@Observable
public final class LabsStore {
    public private(set) var labs: [LabResultDTO] = []
    public private(set) var biomarkers: [BiomarkerDTO] = []
    public private(set) var isLoading = false
    /// True after a `403 module.disabled` for `labs` — the module is OFF.
    public private(set) var isDisabled = false
    public private(set) var lastError: String?
    /// **14-03 (E1 / #67, Labs edition) — the biomarker CATALOG's own failure.**
    ///
    /// Deliberately a second slot rather than a second use of ``lastError``:
    /// `lastError` is what `LabsScreen.phase` reads to decide that the whole
    /// surface failed, and a catalog request that 500s while `GET /api/labs`
    /// returned rows is not that. The rows render; this states what is missing
    /// beside them (and therefore which biomarker-dependent affordances are
    /// thin until a reload). `nil` = the catalog is current.
    public private(set) var biomarkerCatalogError: String?
    /// Server-reported total (for an honest pull-to-refresh count).
    public private(set) var total = 0

    /// Ids removed optimistically and pending a possible restore (undo window).
    /// Cleared when the undo window expires or the restore lands.
    public private(set) var pendingRestoreIDs: [String] = []

    private let repository: LabsRepository
    private let undo: UndoCoordinator?
    @ObservationIgnored private var authenticatedSessionRegistry = AuthenticatedSessionLeaseRegistry()
    @ObservationIgnored private var authenticatedSessionOwnerProvider: @Sendable () -> String? = { "_anonymous" }
    @ObservationIgnored private var ownsAuthenticatedSessionRegistry = true
    /// In-flight guard so overlapping `load()` calls coalesce.
    private var isReloading = false

    /// v0154 LR-REDO — labs-list page size. Matches the web's `limit=500` so a
    /// full biomarker history backs the client-side per-biomarker series filter
    /// + chart. The server caps the page server-side; this is the requested size.
    static let historyLimit = 500

    /// **W-THRESHOLD-NUDGE** — optional, MDR-safe out-of-range nudge coordinator.
    /// `nil` in standalone / tests that don't exercise the nudge; when wired it
    /// is consulted right after a lab result lands. It NEVER blocks or fails the
    /// write — it only (maybe) surfaces one calm, retrospective, non-diagnostic
    /// banner off the SERVER's own range verdict. Settable post-init so the
    /// container can wire it after both stores exist.
    var thresholdNudge: ThresholdNudgeCoordinator?

    public init(repository: LabsRepository, undo: UndoCoordinator? = nil) {
        self.repository = repository
        self.undo = undo
        authenticatedSessionRegistry.activate(ownerID: "_anonymous")
    }

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

    private func captureAuthenticatedSessionLease() -> AuthenticatedSessionLease? {
        guard let ownerID = authenticatedSessionOwnerProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ownerID.isEmpty else { return nil }
        return authenticatedSessionRegistry.capture(ownerID: ownerID)
    }

    private func rotateOwnedAuthenticatedSessionBoundary() {
        guard ownsAuthenticatedSessionRegistry else { return }
        authenticatedSessionRegistry.invalidate()
        authenticatedSessionRegistry.activate(ownerID: "_anonymous")
    }

    // MARK: - Load

    /// Load lab results + the biomarker catalog. No-op while a reload is already
    /// in flight. A `403 module.disabled` flips ``isDisabled``.
    public func load() async {
        guard let sessionLease = captureAuthenticatedSessionLease() else {
            // 13-03 (H-A1c) — a refused lease was a silent no-op here too.
            StoreEffectDiagnostics.recordRefusal(.leaseUnavailable, store: .labs)
            return
        }
        guard !isReloading else { return }
        isReloading = true
        isLoading = true
        // 13-03 — unconditional. The condition used to be the very lease that
        // had just been retired, so on the one exit that needed it the defer
        // did not fire — and it stranded TWO flags, not one: `isReloading`
        // guards this method's own re-entry, so every later `load()` became a
        // permanent no-op as well. Lowering the flags publishes nothing; the
        // data fence below still refuses to write labs, biomarkers or an error
        // for a retired lease.
        //
        // 20-02 (D-14-06-A) — guarded on `ownsRegistryGeneration`, which is
        // registry currency WITHOUT the cancellation fold. Cancellation still
        // settles both flags, so 13-03's reasoning above survives intact
        // (including the `isReloading` half, whose stranding turned every later
        // `load()` into a permanent no-op). What changes is the account
        // boundary: `isLoading` is an observable, so a SUPERSEDED load lowering
        // it publishes over the skeleton the account that is actually here is
        // legitimately showing — the 09-06 invariant. `clearOnLogout()` resets
        // both flags and runs on every boundary, so refusing here cannot strand
        // either one; `AuthenticatedLabsBoundaryTests` asserts that recovery by
        // consequence rather than by trusting this comment.
        defer {
            if sessionLease.ownsRegistryGeneration {
                isLoading = false
                isReloading = false
            }
        }
        // v0154 LR-REDO — pull a full biomarker history (web uses limit=500)
        // so the per-biomarker detail page can back its chart + "Alle
        // Messungen" list from the loaded list (the series is a client-side
        // filter of `labs`, no per-biomarker endpoint). The default 100 cap
        // truncated long histories under the by-type index.
        async let labsResult = repository.labs(limit: Self.historyLimit)
        async let catalog = repository.biomarkers()
        // 14-03 (E1 / the #67 pattern, Labs edition) — two requests, two
        // independently settled halves.
        //
        // These two were awaited as ONE tuple, so a throw from either jumped
        // out of the whole `do` block: a failed biomarker CATALOG discarded a
        // perfectly good labs result and the screen fell through to its error
        // phase with no rows. That is exactly the symptom #67 taught the
        // dashboard to survive, still live here. Each half now settles into its
        // own slot, and each states its own failure.
        //
        // This is publication-level decoupling only. No retry policy is added,
        // no third request, and the two requests stay two requests.
        var page: ListLabResultsResponse?
        var markers: ListBiomarkersResponse?
        var labsFailure: Error?
        var catalogFailure: Error?
        do { page = try await labsResult } catch { labsFailure = error }
        do { markers = try await catalog } catch { catalogFailure = error }
        // The account fence is unchanged and still comes first: a retired lease
        // publishes NOTHING — not a row, not an error, not a caption. 13-03's
        // unconditional `defer` above still lowers both flags on this exit.
        guard sessionLease.isCurrent else {
            StoreEffectDiagnostics.recordRefusal(.leaseRetired, store: .labs)
            return
        }
        // A `module.disabled` verdict from EITHER half is the module speaking
        // about the WHOLE surface, not a partial failure, so it keeps taking the
        // single existing path (both snapshots cleared, `isDisabled` raised).
        if moduleGateClosed(labsFailure: labsFailure, catalogFailure: catalogFailure) { return }
        // The three DATA publications stay HERE, after the one fence that guards
        // them, and there are exactly as many of them as there were before the
        // split — the Phase-06 effect inventory counts publication sites at the
        // await boundary that fences them, and this plan is not entitled to
        // move one out of that census. Each reads its own half and leaves the
        // other half's snapshot exactly as it found it, which is the whole of
        // what "partial failure" means here.
        labs = page?.results ?? labs
        total = page.map { $0.meta?.total ?? $0.results.count } ?? total
        biomarkers = markers?.biomarkers ?? biomarkers
        publishHalfStatements(
            anyHalfSucceeded: page != nil || markers != nil,
            labsFailure: labsFailure,
            catalogFailure: catalogFailure
        )
    }

    /// 14-03 — is the `labs` module simply off?
    ///
    /// A `module.disabled` verdict from either request is about the whole
    /// surface, so it is not a partial failure and does not get split: it takes
    /// the single ``applyError`` path that clears both snapshots and raises
    /// ``isDisabled``. Returns whether it fired, so the caller reads as a gate.
    private func moduleGateClosed(labsFailure: Error?, catalogFailure: Error?) -> Bool {
        let disabled = [labsFailure, catalogFailure]
            .compactMap { $0 }
            .first { LabsRepository.isLabsDisabled($0) }
        guard let disabled else { return false }
        applyError(disabled)
        return true
    }

    /// 14-03 — what each half says about ITSELF once both have settled.
    ///
    /// `lastError` is the labs half's, and only its. `biomarkerCatalogError` is
    /// the catalogue's, deliberately in its own slot because `lastError` is what
    /// `LabsScreen.phase` reads to decide the WHOLE surface failed. A half that
    /// answered proves the module is on whatever the other half did; two
    /// non-gate failures leave the previous verdict alone, exactly as the
    /// single-path `applyError` did before the split.
    private func publishHalfStatements(
        anyHalfSucceeded: Bool,
        labsFailure: Error?,
        catalogFailure: Error?
    ) {
        if anyHalfSucceeded { isDisabled = false }
        lastError = labsFailure.map { LogSanitizer.redact(String(describing: $0)) }
        lastErrorWasDuplicateName = labsFailure.map { LabsRepository.isDuplicateName($0) } ?? false
        biomarkerCatalogError = catalogFailure.map { LogSanitizer.redact(String(describing: $0)) }
    }

    /// Fetch the single-resource detail (incl. the decrypted note) for a row.
    /// Throws so the detail screen can decide how to degrade — the list row
    /// summary already renders without it.
    public func fetchDetail(id: String) async throws -> LabResultDetailDTO {
        guard let sessionLease = captureAuthenticatedSessionLease() else { throw CancellationError() }
        let detail = try await repository.labDetail(id: id)
        try sessionLease.requireCurrent()
        return detail
    }

    /// Refresh just the biomarker catalog (e.g. after a catalog edit).
    public func reloadBiomarkers() async {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return }
        do {
            let response = try await repository.biomarkers()
            try sessionLease.requireCurrent()
            biomarkers = response.biomarkers
            // 14-03 — a successful catalog read ends the catalog's own
            // statement; the retry the screen offers has to be able to end it.
            // A call rather than an assignment, deliberately: this method's
            // publication census is frozen at one site, and clearing a caption
            // is not a second publication of lab data.
            clearBiomarkerCatalogStatement()
        } catch {
            guard sessionLease.isCurrent else { return }
            applyError(error)
        }
    }

    // MARK: - Lab-result writes

    /// Create a lab result, then reload so the new (server-resolved) row +
    /// range verdict appear. Returns `true` on success.
    ///
    /// `idempotencyKey` lets the lab-scan batch save pass one STABLE key per row
    /// so a retry after a partial failure is idempotent at the key level (BH
    /// M2). Omitting it mints a fresh key (the default single-create path).
    ///
    /// `reloadAfterCreate` exists for the same batch caller (item 3.4): a
    /// scanned panel writes 10–20 rows in one pass, and reloading the whole list
    /// after EACH of them would be 20 round-trips for one user action. The batch
    /// passes `false` and calls ``load()`` once when the batch finishes; every
    /// other caller keeps the reload-per-write behaviour.
    @discardableResult
    public func createLab(
        _ body: LabResultCreate,
        idempotencyKey: IdempotencyKey? = nil,
        reloadAfterCreate: Bool = true
    ) async -> Bool {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return false }
        lastError = nil
        do {
            let created = try await repository.createLab(body, idempotencyKey: idempotencyKey)
            try sessionLease.requireCurrent()
            if reloadAfterCreate { await load() }
            // W-THRESHOLD-NUDGE — evaluate the just-logged, server-resolved row
            // against its server / user-defined range. The coordinator owns every
            // MDR gate (opt-in, server-escalation deference, debounce, and the
            // hard "no app-invented threshold" rule — it acts ONLY on the
            // server's `rangeStatus`). Best-effort + after the reload, so it
            // never affects the write result.
            try sessionLease.requireCurrent()
            await thresholdNudge?.handleCreatedLab(created)
            try sessionLease.requireCurrent()
            return true
        } catch let err as HLError where err.shouldPersistToOutbox {
            // audit H-2 — an offline (durably-enqueued) create is SUCCESS, not
            // failure. The repository minted a STABLE idempotency key, enqueued
            // the create to the encrypted Outbox (it WILL replay + succeed at
            // reachability), and re-threw `shouldPersistToOutbox`. Reporting this
            // as a failure would make the user see a "save failed" state and
            // re-tap Save → the repo mints a SECOND key → a second enqueue → both
            // replay under different keys → TWO identical lab rows. Mirror
            // `AllergiesStore.create` / `FamilyHistoryStore.create`: insert an
            // optimistic row, keep NO error banner, return success. The outbox
            // replays the original write exactly once; the next online `load()`
            // reconciles the placeholder with the server row. The threshold nudge
            // is intentionally skipped — there is no server `rangeStatus` yet.
            guard sessionLease.isCurrent else { return false }
            let optimistic = Self.optimisticLab(from: body)
            labs.insert(optimistic, at: 0)
            total += 1
            lastError = nil
            return true
        } catch {
            guard sessionLease.isCurrent else { return false }
            applyError(error)
            return false
        }
    }

    /// Update a lab result, then reload. Returns `true` on success.
    @discardableResult
    public func updateLab(id: String, _ patch: LabResultPatch) async -> Bool {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return false }
        lastError = nil
        do {
            _ = try await repository.updateLab(id: id, patch)
            try sessionLease.requireCurrent()
            await load()
            try sessionLease.requireCurrent()
            return true
        } catch {
            guard sessionLease.isCurrent else { return false }
            applyError(error)
            return false
        }
    }

    /// Optimistically remove a lab result + surface a `HLUndoToast`. The row is
    /// dropped from the in-memory list immediately; the server soft-delete fires
    /// in the background. Tapping undo calls `restore` (`/api/labs/restore`);
    /// letting the window expire makes the deletion stand.
    ///
    /// `undoMessage` is the already-localized toast copy (resolved by the
    /// caller, mirroring the `HLUndoToast` adoption contract).
    public func deleteLab(id: String, undoMessage: String) async {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return }
        lastError = nil
        guard let index = labs.firstIndex(where: { $0.id == id }) else { return }
        let removed = labs.remove(at: index)
        // Keep the result count in step with the optimistic removal so the
        // header/empty-state don't read a stale total until the next reload
        // (QA C-M2). The restore/undo path calls load(), which resets total from
        // the server meta, so only the optimistic + rollback legs adjust it here.
        total = max(0, total - 1)
        pendingRestoreIDs.append(id)

        // Surface the undo affordance up-front; the restore closure re-inserts
        // + un-tombstones server-side.
        undo?.enqueue(message: undoMessage) { [weak self] in
            guard sessionLease.isCurrent else { return }
            _ = await self?.restore(ids: [id], sessionLease: sessionLease)
        }

        do {
            try await repository.deleteLab(id: id)
            try sessionLease.requireCurrent()
        } catch let err as HLError where err.shouldPersistToOutbox {
            // v0150 C-M3 — the repository durably enqueued the delete to the
            // Outbox (it WILL replay + succeed at reachability). Mirror the
            // optimistic-write + outbox doctrine MeasurementsStore /
            // MedicationsStore apply on a queued delete: KEEP the optimistic
            // removal (the row is gone, the count stays decremented) and KEEP
            // the undo affordance live so the user can still recover. Rolling
            // the row back IN here would make it reappear and then vanish again
            // on the next load() after replay — a visible flicker. We record the
            // error for diagnostics but do not surface a failed state.
            guard sessionLease.isCurrent else { return }
            applyError(err)
        } catch {
            guard sessionLease.isCurrent else { return }
            // Genuine non-retriable / permanent failure (NOT enqueued to the
            // Outbox — e.g. a 4xx the server will never accept). Roll the
            // optimistic removal back + drop the undo affordance so the user
            // sees an honest "couldn't delete" state rather than a silently
            // vanished row that never syncs.
            if labs.firstIndex(where: { $0.id == id }) == nil {
                labs.insert(removed, at: min(index, labs.count))
                labs.sort { $0.takenAt > $1.takenAt }
                total += 1 // undo the optimistic decrement (row is back)
            }
            pendingRestoreIDs.removeAll { $0 == id }
            undo?.dismiss(reason: .cancelled)
            applyError(error)
        }
    }

    /// Restore previously-deleted rows (`POST /api/labs/restore`), then reload.
    /// Driven by the undo toast. Returns `true` on success.
    @discardableResult
    public func restore(ids: [String]) async -> Bool {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return false }
        return await restore(ids: ids, sessionLease: sessionLease)
    }

    private func restore(ids: [String], sessionLease: AuthenticatedSessionLease) async -> Bool {
        guard !ids.isEmpty else { return true }
        guard sessionLease.isCurrent else { return false }
        lastError = nil
        do {
            _ = try await repository.restoreLabs(ids: ids)
            try sessionLease.requireCurrent()
            pendingRestoreIDs.removeAll { ids.contains($0) }
            await load()
            try sessionLease.requireCurrent()
            return true
        } catch {
            guard sessionLease.isCurrent else { return false }
            applyError(error)
            return false
        }
    }

    // MARK: - Biomarker writes

    @discardableResult
    public func createBiomarker(_ body: BiomarkerCreate) async -> Bool {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return false }
        lastError = nil
        do {
            _ = try await repository.createBiomarker(body)
            try sessionLease.requireCurrent()
            await reloadBiomarkers()
            try sessionLease.requireCurrent()
            return true
        } catch let err as HLError where err.shouldPersistToOutbox {
            // audit H-2 — same offline-create-is-SUCCESS doctrine as `createLab`:
            // the repository durably enqueued the catalog create under a stable
            // key. Surfacing a failure would invite a re-tap that mints a second
            // key → a duplicate biomarker on reconnect. Insert an optimistic
            // catalog row, no error banner, return success; the outbox replays
            // once and the next `reloadBiomarkers()`/`load()` reconciles it.
            guard sessionLease.isCurrent else { return false }
            let optimistic = Self.optimisticBiomarker(from: body)
            biomarkers.insert(optimistic, at: 0)
            lastError = nil
            return true
        } catch {
            guard sessionLease.isCurrent else { return false }
            applyError(error)
            return false
        }
    }

    @discardableResult
    public func updateBiomarker(id: String, _ patch: BiomarkerPatch) async -> Bool {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return false }
        lastError = nil
        do {
            _ = try await repository.updateBiomarker(id: id, patch)
            try sessionLease.requireCurrent()
            // AUD-6 High — refresh BOTH the catalog AND the lab rows. Editing a
            // biomarker's name / unit / reference range used to reload only the
            // catalog (`reloadBiomarkers()`), leaving the `labs` rows array frozen:
            // the Labs list + the new `BiomarkerDetailScreen` chart kept rendering
            // the stale per-row unit/range while the gear catalog showed the new
            // value. `load()` re-pulls the server-resolved rows so the list +
            // detail repaint with the edited definition.
            await load()
            try sessionLease.requireCurrent()
            return true
        } catch {
            guard sessionLease.isCurrent else { return false }
            applyError(error)
            return false
        }
    }

    /// Delete a catalog biomarker. The server unlinks (SetNull) every reading —
    /// lab history survives with its legacy fields — so this reloads BOTH the
    /// catalog and the lab list so unlinked rows repaint with their preserved
    /// analyte/unit.
    @discardableResult
    public func deleteBiomarker(id: String) async -> Bool {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return false }
        lastError = nil
        do {
            try await repository.deleteBiomarker(id: id)
            try sessionLease.requireCurrent()
            await load()
            try sessionLease.requireCurrent()
            return true
        } catch {
            guard sessionLease.isCurrent else { return false }
            applyError(error)
            return false
        }
    }

    /// True when the last error was a biomarker duplicate-name `409`. The editor
    /// reads this to show an inline `HLFormErrorText`.
    public private(set) var lastErrorWasDuplicateName = false

    // MARK: - Logout

    /// Drop every in-memory snapshot on logout so the next user never inherits
    /// the previous user's lab results / catalog.
    public func clearOnLogout() {
        rotateOwnedAuthenticatedSessionBoundary()
        labs = []
        biomarkers = []
        pendingRestoreIDs = []
        total = 0
        isLoading = false
        isReloading = false
        isDisabled = false
        lastError = nil
        lastErrorWasDuplicateName = false
        // 14-03 — the catalog's own failure slot is PHI-adjacent state like the
        // rest of this list and leaves with it.
        biomarkerCatalogError = nil
    }

    /// Test-only — populate the in-memory lab + biomarker snapshots without a
    /// network round-trip, so the logout-wipe suite can prove `clearOnLogout`
    /// purges the PHI. Production reaches this state only through ``load()``.
    func seedForTesting(labs: [LabResultDTO], biomarkers: [BiomarkerDTO] = [], total: Int? = nil) {
        self.labs = labs
        self.biomarkers = biomarkers
        self.total = total ?? labs.count
    }

    // MARK: - Private

    /// Build an optimistic in-memory lab row for an offline-queued create
    /// (audit H-2). Mirrors `AllergiesStore.optimisticAllergy`: carries a
    /// temporary `optimistic-…` id so it never collides with a server id, and a
    /// NEUTRAL `.unknown` range verdict because the server has not resolved one
    /// yet (the store never invents a range). The next online `load()` replaces
    /// the whole snapshot with the server rows (under the same idempotency key),
    /// so the placeholder is transient.
    private static func optimisticLab(from body: LabResultCreate) -> LabResultDTO {
        let now = ISO8601DateFormatter().string(from: Date.now)
        return LabResultDTO(
            id: "optimistic-\(UUID().uuidString)",
            biomarkerId: body.biomarkerId,
            panel: body.panel,
            analyte: body.analyte ?? "",
            value: body.value,
            // Item 1.5 — carry the qualitative result into the optimistic row so
            // an offline-queued "negativ" doesn't show as an empty measurement
            // until the next online load.
            valueText: body.valueText,
            unit: body.unit ?? "",
            referenceLow: body.referenceLow,
            referenceHigh: body.referenceHigh,
            takenAt: body.takenAt,
            source: body.source ?? "MANUAL",
            hasNote: !(body.note ?? "").isEmpty,
            rangeStatus: .unknown,
            createdAt: now,
            updatedAt: now
        )
    }

    /// Build an optimistic in-memory catalog row for an offline-queued biomarker
    /// create (audit H-2). Same transient-placeholder contract as
    /// ``optimisticLab(from:)``.
    private static func optimisticBiomarker(from body: BiomarkerCreate) -> BiomarkerDTO {
        let now = ISO8601DateFormatter().string(from: Date.now)
        return BiomarkerDTO(
            id: "optimistic-\(UUID().uuidString)",
            name: body.name,
            unit: body.unit,
            lowerBound: body.lowerBound,
            upperBound: body.upperBound,
            panel: body.panel,
            hasContext: !(body.context ?? "").isEmpty,
            context: body.context,
            createdAt: now,
            updatedAt: now
        )
    }

    /// 14-03 — end the biomarker catalogue's own statement. A named call so
    /// the two places that must end it (a successful catalogue re-read, and the
    /// module gate closing over the whole surface) say the same thing once.
    private func clearBiomarkerCatalogStatement() {
        biomarkerCatalogError = nil
    }

    private func applyError(_ error: Error) {
        if LabsRepository.isLabsDisabled(error) {
            isDisabled = true
            labs = []
            biomarkers = []
            lastError = nil
            lastErrorWasDuplicateName = false
            // 14-03 — a switched-off module is not a catalogue failure; the
            // caption goes with the data it was standing beside.
            clearBiomarkerCatalogStatement()
            return
        }
        lastErrorWasDuplicateName = LabsRepository.isDuplicateName(error)
        lastError = LogSanitizer.redact(String(describing: error))
    }
}
