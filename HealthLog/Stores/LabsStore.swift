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
    /// The person's own panel names from the catalog read (server v1.47.1),
    /// offered as suggestions in the marker form. Empty on an older server.
    public private(set) var customPanels: [String] = []
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
    /// The per-marker overview (`GET /api/labs/overview`, server
    /// v1.42.4+), the source of the "by type" list. `nil` on a server without
    /// the route, before the first load, or offline before it ever loaded; the
    /// list then falls back to grouping ``labs`` (see ``markerIndex``).
    public private(set) var markerOverview: LabOverviewResponse?
    /// The person's labs list presentation (`groupBy`, `groupsOpen`, server
    /// v1.47.1). `nil` before the first load and on an older server.
    public private(set) var listLayout: LabsListLayout?

    /// Ids removed optimistically and pending a possible restore (undo window).
    /// Cleared when the undo window expires or the restore lands.
    public private(set) var pendingRestoreIDs: [String] = []

    let repository: LabsRepository
    /// Merged marker id to the marker it went into (``resolvedBiomarker(_:)``).
    public internal(set) var mergedMarkerRedirects: [String: String] = [:]
    private let undo: UndoCoordinator?
    /// D5 #11: the derived marker list, kept for the inputs it was built from.
    @ObservationIgnored var markerMemo = LabsMarkerMemo()
    @ObservationIgnored private var authenticatedSessionRegistry = AuthenticatedSessionLeaseRegistry()
    @ObservationIgnored private var authenticatedSessionOwnerProvider: @Sendable () -> String? = { "_anonymous" }
    @ObservationIgnored private var ownsAuthenticatedSessionRegistry = true
    /// In-flight guard so overlapping `load()` calls coalesce.
    private var isReloading = false

    /// Labs-list page size. Matches the web's `limit=500` so a
    /// full biomarker history backs the client-side per-biomarker series filter
    /// + chart. The server caps the page server-side; this is the requested size.
    static let historyLimit = 500

    /// Optional, MDR-safe out-of-range nudge coordinator.
    /// `nil` in tests that don't exercise the nudge; when wired it
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

    func captureAuthenticatedSessionLease() -> AuthenticatedSessionLease? {
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
        // Unconditional. The condition used to be the very lease that
        // had just been retired, so on the one exit that needed it the defer
        // did not fire — and it stranded TWO flags, not one: `isReloading`
        // guards this method's own re-entry, so every later `load()` became a
        // permanent no-op as well. Lowering the flags publishes nothing; the
        // data fence below still refuses to write labs, biomarkers or an error
        // for a retired lease.
        //
        // Guarded on `ownsRegistryGeneration`, which is
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
        // Pull a full biomarker history (web uses limit=500)
        // so the per-biomarker detail page can back its chart + "Alle
        // Messungen" list from the loaded list (the series is a client-side
        // filter of `labs`, no per-biomarker endpoint). The default 100 cap
        // truncated long histories under the by-type index.
        async let labsResult = repository.labs(limit: Self.historyLimit)
        async let catalog = repository.biomarkers()
        // The marker list comes from the overview: one entry per marker
        // over the whole history, so a long history is no longer cut at
        // `historyLimit`. A third, independent half: a failed overview keeps the
        // previous one (or the `labs` fallback) and states nothing of its own.
        async let overviewResult = repository.labsOverview()
        // The fourth half: the person's list presentation. Its failure is
        // silent and keeps the previous one; the list never waits on it.
        async let layoutResult = repository.labsListLayout()
        // Two requests, two independently settled halves. Awaited as one
        // tuple, a failed biomarker CATALOG would discard a good labs result
        // and drop the screen into its error phase with no rows. Each half
        // settles into its own slot and states its own failure; there is no
        // retry policy and no third request.
        var page: ListLabResultsResponse?
        var markers: ListBiomarkersResponse?
        var labsFailure: Error?
        var catalogFailure: Error?
        do { page = try await labsResult } catch { labsFailure = error }
        do { markers = try await catalog } catch { catalogFailure = error }
        // Outer `nil` = the read failed (keep what we had); `.some(nil)` = the
        // server has no overview route (fall back to grouping `labs`).
        var overview: LabOverviewResponse??
        do { overview = try await overviewResult } catch {}
        var layout: LabsListLayout??
        do { layout = try await layoutResult } catch {}
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
        customPanels = markers?.customPanels ?? customPanels
        if let overview { markerOverview = overview }
        if let layout { listLayout = layout }
        publishHalfStatements(
            anyHalfSucceeded: page != nil || markers != nil,
            labsFailure: labsFailure,
            catalogFailure: catalogFailure
        )
    }

    /// Is the `labs` module simply off?
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

    /// What each half says about ITSELF once both have settled.
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
            customPanels = response.customPanels
            // A successful catalog read ends the catalog's own
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
            // Evaluate the just-logged, server-resolved row
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
            // The repository durably enqueued the delete to the
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
            noteMergedMarker(error, oldId: id)
            applyError(error)
            return false
        }
    }

    /// Delete a catalog biomarker. The server hard-deletes the marker together
    /// with every reading of it in one transaction (`DELETE /api/biomarkers/{id}`),
    /// so this reloads BOTH the catalog and the lab list, which drops those rows.
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
            noteMergedMarker(error, oldId: id)
            applyError(error)
            return false
        }
    }

    /// True when the last error was a biomarker duplicate-name `409`. The editor
    /// reads this to show an inline `HLFormErrorText`.
    public private(set) var lastErrorWasDuplicateName = false

    /// Dry run or real merge into `target`; redirects recorded only behind the lease.
    func runBiomarkerMerge(into target: String, sources: [String], dryRun: Bool) async -> BiomarkerMergeResult? {
        let picked = Array(sources.filter { $0 != target }.prefix(BiomarkerMergeRequest.maxSources))
        guard !picked.isEmpty, let sessionLease = captureAuthenticatedSessionLease() else { return nil }
        do {
            let result = try await repository.mergeBiomarkers(into: target, sourceIds: picked, dryRun: dryRun)
            try sessionLease.requireCurrent()
            if !dryRun { recordMerge(into: target, sources: picked) }
            return result
        } catch {
            guard sessionLease.isCurrent else { return nil }
            applyError(error)
            return nil
        }
    }

    /// One marker's whole history, returned (never published) behind the lease.
    public func fetchHistory(biomarkerId: String?, analyte: String) async -> [LabResultDTO]? {
        guard let lease = captureAuthenticatedSessionLease() else { return nil }
        let rows = try? await repository.markerHistory(biomarkerId: biomarkerId, analyte: analyte)
        return lease.isCurrent ? rows : nil
    }

    // MARK: - Logout

    /// Drop every in-memory snapshot on logout so the next user never inherits
    /// the previous user's lab results / catalog.
    public func clearOnLogout() {
        rotateOwnedAuthenticatedSessionBoundary()
        labs = []
        biomarkers = []
        customPanels = []
        markerOverview = nil
        listLayout = nil
        pendingRestoreIDs = []
        total = 0
        isLoading = false
        isReloading = false
        isDisabled = false
        lastError = nil
        lastErrorWasDuplicateName = false
        // The catalog's own failure slot is PHI-adjacent state like the
        // rest of this list and leaves with it.
        biomarkerCatalogError = nil
        mergedMarkerRedirects = [:]
    }

    // MARK: - Private

    /// End the biomarker catalogue's own statement. A named call so
    /// the two places that must end it (a successful catalogue re-read, and the
    /// module gate closing over the whole surface) say the same thing once.
    private func clearBiomarkerCatalogStatement() {
        biomarkerCatalogError = nil
    }

    /// The visible error is localized copy, not a Swift description.
    /// `String(describing:)` printed the enum case (`notPersisted("…")`) onto a
    /// user-facing surface; the sanitized description belongs in the log line,
    /// where triage reads it. `HLError.userFacingText(for:)` resolves the
    /// sentence the user is owed.
    private func applyError(_ error: Error) {
        if LabsRepository.isLabsDisabled(error) {
            isDisabled = true
            labs = []
            biomarkers = []
            customPanels = []
            markerOverview = nil
            lastError = nil
            lastErrorWasDuplicateName = false
            // A switched-off module is not a catalogue failure; the
            // caption goes with the data it was standing beside.
            clearBiomarkerCatalogStatement()
            return
        }
        lastErrorWasDuplicateName = LabsRepository.isDuplicateName(error)
        HLLog.ui.error("Labs write failed: \(LogSanitizer.redact(String(describing: error)))")
        lastError = LabsRefusal.sentence(for: error) ?? HLError.userFacingText(for: error)
    }
}

/// Test seeding, outside the class body (pure move, D5 #11 kept the type
/// under its length budget). Same file, so it may still set the
/// `private(set)` state.
extension LabsStore {
    /// Test-only — populate the in-memory lab + biomarker snapshots without a
    /// network round-trip, so the logout-wipe suite can prove `clearOnLogout`
    /// purges the PHI. Production reaches this state only through ``load()``.
    func seedForTesting(
        labs: [LabResultDTO],
        biomarkers: [BiomarkerDTO] = [],
        total: Int? = nil,
        overview: LabOverviewResponse? = nil,
        customPanels: [String] = [],
        listLayout: LabsListLayout? = nil
    ) {
        self.labs = labs
        self.biomarkers = biomarkers
        self.customPanels = customPanels
        self.listLayout = listLayout
        self.total = total ?? labs.count
        markerOverview = overview
    }
}
